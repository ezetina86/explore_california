# makefiles/aws.mk

# AWS Configuration
AWS_REGION ?= us-east-2
TERRAFORM_S3_BUCKET ?= explore-california-ez-terraform-state-bucket
TERRAFORM_S3_KEY ?= explore-california/terraform.tfstate
EKS_CLUSTER_NAME := explore-california-cluster
ECR_REPOSITORY_NAME := explore-california
TERRAFORM_S3_REGION ?= us-east-2
TERRAFORM_STATE_LOCK_TABLE ?= terraform-state-lock

# Phony targets for AWS
.PHONY: aws-check-prerequisites aws-install-prerequisites aws-all aws-clean aws-deploy aws-destroy aws-init \
        aws-check-credentials aws-create-state-resources aws-cleanup-state \
        aws-push-image aws-deploy-app aws-check-deployment aws-setup-lb-controller \
        aws-deploy-application aws-verify-deployment

# Check for required tools
aws-check-prerequisites:
	@echo "$(BLUE)Checking required tools...$(NC)"
	@which aws >/dev/null || { echo "$(RED)aws CLI not found. Installing...$(NC)"; brew install awscli; }
	@which kubectl >/dev/null || { echo "$(RED)kubectl not found. Installing...$(NC)"; brew install kubernetes-cli; }
	@which helm >/dev/null || { echo "$(RED)helm not found. Installing...$(NC)"; brew install helm; }
	@which eksctl >/dev/null || { echo "$(RED)eksctl not found. Installing...$(NC)"; brew install eksctl; }
	@which terraform >/dev/null || { echo "$(RED)terraform not found. Installing...$(NC)"; brew install terraform; }

# Install prerequisites if needed
aws-install-prerequisites:
	@echo "$(BLUE)Installing required tools...$(NC)"
	@brew install awscli kubernetes-cli helm eksctl terraform || true

# Main AWS targets
aws-all: aws-deploy-app aws-verify-deployment
	@echo "$(GREEN)AWS deployment complete!$(NC)"

# Credential checking
aws-check-credentials:
	@echo "$(BLUE)Checking AWS credentials...$(NC)"
	@aws sts get-caller-identity >/dev/null 2>&1 || \
		{ echo "$(RED)AWS credentials not configured. Please run 'aws configure' first$(NC)"; exit 1; }

# Terraform state management
aws-create-state-resources: aws-check-credentials
	@echo "$(BLUE)Creating Terraform state resources...$(NC)"
	@aws s3api create-bucket \
		--bucket $(TERRAFORM_S3_BUCKET) \
		--region $(TERRAFORM_S3_REGION) \
		--create-bucket-configuration LocationConstraint=$(TERRAFORM_S3_REGION) 2>/dev/null || true
	@aws dynamodb create-table \
		--table-name $(TERRAFORM_STATE_LOCK_TABLE) \
		--attribute-definitions AttributeName=LockID,AttributeType=S \
		--key-schema AttributeName=LockID,KeyType=HASH \
		--provisioned-throughput ReadCapacityUnits=1,WriteCapacityUnits=1 \
		--region $(TERRAFORM_S3_REGION) 2>/dev/null || true
	@aws s3api put-bucket-versioning \
		--bucket $(TERRAFORM_S3_BUCKET) \
		--versioning-configuration Status=Enabled
	@aws s3api put-bucket-encryption \
		--bucket $(TERRAFORM_S3_BUCKET) \
		--server-side-encryption-configuration \
		'{"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]}'
	@echo "$(GREEN)Terraform state resources created!$(NC)"

# Infrastructure management
aws-init: aws-check-credentials aws-create-state-resources
	@echo "$(BLUE)Initializing Terraform...$(NC)"
	@cd infra && \
	terraform init \
		-upgrade \
		-backend-config="bucket=$(TERRAFORM_S3_BUCKET)" \
		-backend-config="key=$(TERRAFORM_S3_KEY)" \
		-backend-config="region=$(TERRAFORM_S3_REGION)" \
		-backend-config="encrypt=true" \
		-backend-config="dynamodb_table=$(TERRAFORM_STATE_LOCK_TABLE)" || \
		{ echo "$(RED)Terraform init failed$(NC)"; exit 1; }

aws-deploy: aws-init
	@echo "$(BLUE)Deploying AWS infrastructure...$(NC)"
	@cd infra && terraform apply -var-file="terraform.tfvars" -auto-approve || \
		{ echo "$(RED)Terraform apply failed$(NC)"; exit 1; }
	@aws eks update-kubeconfig --name $(EKS_CLUSTER_NAME) --region $(AWS_REGION)

# Image management
aws-push-image: aws-check-credentials
	@echo "$(BLUE)Pushing image to ECR...$(NC)"
	@aws ecr get-login-password --region $(AWS_REGION) | podman login --username AWS --password-stdin \
		$(shell aws sts get-caller-identity --query Account --output text).dkr.ecr.$(AWS_REGION).amazonaws.com
	@podman tag $(IMAGE_NAME) $(shell aws sts get-caller-identity --query Account --output text).dkr.ecr.$(AWS_REGION).amazonaws.com/$(ECR_REPOSITORY_NAME):latest
	@podman push $(shell aws sts get-caller-identity --query Account --output text).dkr.ecr.$(AWS_REGION).amazonaws.com/$(ECR_REPOSITORY_NAME):latest

# Application deployment with enhanced Load Balancer Controller setup
aws-deploy-app: aws-check-prerequisites aws-deploy aws-push-image aws-setup-lb-controller aws-deploy-application

# Setup Load Balancer Controller
aws-setup-lb-controller:
	@echo "$(BLUE)Setting up AWS Load Balancer Controller...$(NC)"
	# Create IAM policy for AWS Load Balancer Controller
	@echo "$(BLUE)Creating IAM policy for AWS Load Balancer Controller...$(NC)"
	@curl -o aws-load-balancer-controller-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
	@aws iam create-policy \
		--policy-name AWSLoadBalancerControllerIAMPolicy \
		--policy-document file://aws-load-balancer-controller-policy.json 2>/dev/null || true
	@rm aws-load-balancer-controller-policy.json

	@echo "$(BLUE)Creating service account for AWS Load Balancer Controller...$(NC)"
	@eksctl create iamserviceaccount \
		--cluster=$(EKS_CLUSTER_NAME) \
		--namespace=kube-system \
		--name=aws-load-balancer-controller \
		--attach-policy-arn=arn:aws:iam::$(shell aws sts get-caller-identity --query Account --output text):policy/AWSLoadBalancerControllerIAMPolicy \
		--override-existing-serviceaccounts \
		--region $(AWS_REGION) \
		--approve

	# Install AWS Load Balancer Controller
	@echo "$(BLUE)Installing AWS Load Balancer Controller...$(NC)"
	@helm repo add eks https://aws.github.io/eks-charts
	@helm repo update
	@kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller/crds?ref=master"
	@helm upgrade -i aws-load-balancer-controller eks/aws-load-balancer-controller \
		--set clusterName=$(EKS_CLUSTER_NAME) \
		--set serviceAccount.create=false \
		--set serviceAccount.name=aws-load-balancer-controller \
		--set region=$(AWS_REGION) \
		--set vpcId=$(shell aws eks describe-cluster --name $(EKS_CLUSTER_NAME) --query "cluster.resourcesVpcConfig.vpcId" --output text) \
		-n kube-system \
		--wait

	# Wait for controller to be ready
	@echo "$(BLUE)Waiting for AWS Load Balancer Controller to be ready...$(NC)"
	@kubectl wait --namespace kube-system \
		--for=condition=ready pod \
		--selector=app.kubernetes.io/name=aws-load-balancer-controller \
		--timeout=300s

# Deploy application
aws-deploy-application:
	@echo "$(BLUE)Deploying application to EKS...$(NC)"
	@helm upgrade --atomic --install $(HELM_RELEASE_NAME) $(HELM_CHART_PATH) \
		--set image.repository=$(shell aws sts get-caller-identity --query Account --output text).dkr.ecr.$(AWS_REGION).amazonaws.com/$(ECR_REPOSITORY_NAME) \
		--set image.tag=latest \
		--wait
	@echo "$(BLUE)Checking initial deployment status...$(NC)"
	@kubectl get pods
	@kubectl get services
	@kubectl get ingress

# Verify deployment
aws-verify-deployment:
	@echo "$(BLUE)Verifying AWS Load Balancer Controller...$(NC)"
	@kubectl get deployment -n kube-system aws-load-balancer-controller
	@kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
	@echo "$(BLUE)Verifying application deployment...$(NC)"
	@kubectl get deployment $(HELM_RELEASE_NAME)
	@kubectl get pods -l app.kubernetes.io/name=$(HELM_RELEASE_NAME)
	@kubectl get services -l app.kubernetes.io/name=$(HELM_RELEASE_NAME)
	@kubectl get ingress -l app.kubernetes.io/name=$(HELM_RELEASE_NAME)
	@echo "$(BLUE)Checking all resources in application namespace:$(NC)"
	@kubectl get all

# Check deployment status
aws-check-deployment:
	@echo "$(BLUE)Checking EKS deployment status...$(NC)"
	@kubectl get nodes
	@kubectl get pods -A
	@kubectl get services -A
	@kubectl get ingress -A

# Cleanup
aws-clean: aws-destroy aws-cleanup-state
	@echo "$(GREEN)AWS cleanup complete!$(NC)"

aws-destroy: aws-check-credentials
	@echo "$(RED)Destroying AWS infrastructure...$(NC)"
	@cd infra && terraform destroy -auto-approve || \
		{ echo "$(RED)Terraform destroy failed$(NC)"; exit 1; }

aws-cleanup-state: aws-check-credentials
	@echo "$(RED)Cleaning up Terraform state resources...$(NC)"
	@aws dynamodb delete-table --table-name $(TERRAFORM_STATE_LOCK_TABLE) \
		--region $(TERRAFORM_S3_REGION) 2>/dev/null || true
	@aws s3 rb s3://$(TERRAFORM_S3_BUCKET) --force 2>/dev/null || true
	@echo "$(GREEN)Terraform state resources cleaned up!$(NC)"
