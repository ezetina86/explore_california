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
        aws-create-image aws-push-image aws-deploy-app aws-check-deployment aws-setup-lb-controller \
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

# Image building
aws-create-image: aws-check-credentials
	@echo "$(BLUE)Building image for AWS ($(PLATFORM_AWS))...$(NC)"
	@podman build --platform $(PLATFORM_AWS) \
		-t $(IMAGE_NAME) \
		-f $(DOCKERFILE_PATH) \
		$(CONTEXT_PATH) || \
		{ echo "$(RED)Failed to build image$(NC)"; exit 1; }
	@echo "$(GREEN)Successfully built image for AWS$(NC)"

# Push to ECR
aws-push-image: aws-check-credentials aws-create-image
	@echo "$(BLUE)Pushing image to ECR...$(NC)"
	$(eval ECR_URL := $(shell aws sts get-caller-identity --query Account --output text).dkr.ecr.$(AWS_REGION).amazonaws.com/$(ECR_REPOSITORY_NAME))

	@aws ecr get-login-password --region $(AWS_REGION) | podman login --username AWS --password-stdin \
		$(shell aws sts get-caller-identity --query Account --output text).dkr.ecr.$(AWS_REGION).amazonaws.com

	@podman tag $(IMAGE_NAME) $(ECR_URL):latest
	@podman push $(ECR_URL):latest || \
		{ echo "$(RED)Failed to push image to ECR$(NC)"; exit 1; }

	@echo "$(GREEN)Successfully pushed image to ECR$(NC)"

# Application deployment with enhanced Load Balancer Controller setup
aws-deploy-app: aws-deploy aws-create-image aws-push-image aws-setup-lb-controller aws-deploy-application

# Setup Load Balancer Controller
aws-setup-lb-controller:
	@echo "$(BLUE)Setting up AWS Load Balancer Controller...$(NC)"

	# Create IAM policy
	@echo "$(BLUE)Creating IAM policy for AWS Load Balancer Controller...$(NC)"
	@curl -o aws-load-balancer-controller-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
	@aws iam create-policy \
		--policy-name AWSLoadBalancerControllerIAMPolicy \
		--policy-document file://aws-load-balancer-controller-policy.json 2>/dev/null || true
	@rm aws-load-balancer-controller-policy.json

	# Add the EKS chart repository
	@echo "$(BLUE)Adding EKS Helm repository...$(NC)"
	@helm repo add eks https://aws.github.io/eks-charts
	@helm repo update

	# Install CRDs
	@echo "$(BLUE)Installing AWS Load Balancer Controller CRDs...$(NC)"
	@kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller/crds?ref=master" || true

	# Create service account and IAM role
	@echo "$(BLUE)Creating service account with IAM role...$(NC)"
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
	@helm upgrade -i aws-load-balancer-controller eks/aws-load-balancer-controller \
		--namespace kube-system \
		--set clusterName=$(EKS_CLUSTER_NAME) \
		--set serviceAccount.create=false \
		--set serviceAccount.name=aws-load-balancer-controller \
		--set region=$(AWS_REGION) \
		--set vpcId=$(shell aws eks describe-cluster --name $(EKS_CLUSTER_NAME) --query "cluster.resourcesVpcConfig.vpcId" --output text) \
		--wait

	# Verify installation
	@echo "$(BLUE)Verifying AWS Load Balancer Controller installation...$(NC)"
	@kubectl wait --namespace kube-system \
		--for=condition=ready pod \
		--selector=app.kubernetes.io/name=aws-load-balancer-controller \
		--timeout=300s



aws-cleanup-lb-controller:
	@echo "$(BLUE)Cleaning up AWS Load Balancer Controller...$(NC)"

	# Remove Helm release
	@echo "$(BLUE)Removing Helm release...$(NC)"
	@helm uninstall -n kube-system aws-load-balancer-controller || true

	# Remove Kubernetes resources
	@echo "$(BLUE)Removing Kubernetes resources...$(NC)"
	@kubectl delete deployment -n kube-system aws-load-balancer-controller || true
	@kubectl delete serviceaccount -n kube-system aws-load-balancer-controller || true
	@kubectl delete clusterrolebinding aws-load-balancer-controller || true

	# Get the policy ARN
	$(eval POLICY_ARN := $(shell aws iam list-policies --query 'Policies[?PolicyName==`AWSLoadBalancerControllerIAMPolicy`].Arn' --output text))

	# Detach and remove IAM roles/policies
	@echo "$(BLUE)Cleaning up IAM resources...$(NC)"
	@if [ ! -z "$(POLICY_ARN)" ]; then \
		echo "$(BLUE)Detaching and removing IAM policy...$(NC)"; \
		ROLE_NAME=$$(aws iam list-roles --query 'Roles[?contains(RoleName,`aws-load-balancer-controller`)].RoleName' --output text); \
		if [ ! -z "$$ROLE_NAME" ]; then \
			aws iam detach-role-policy --role-name $$ROLE_NAME --policy-arn $(POLICY_ARN) || true; \
			aws iam delete-role --role-name $$ROLE_NAME || true; \
		fi; \
		aws iam delete-policy --policy-arn $(POLICY_ARN) || true; \
	fi

	# Remove service account from EKS
	@echo "$(BLUE)Removing service account from EKS...$(NC)"
	@eksctl delete iamserviceaccount \
		--cluster=$(EKS_CLUSTER_NAME) \
		--namespace=kube-system \
		--name=aws-load-balancer-controller \
		--region $(AWS_REGION) || true

	# Clean up CRDs
	@echo "$(BLUE)Removing Custom Resource Definitions...$(NC)"
	@kubectl delete crd ingressclassparams.elbv2.k8s.aws || true
	@kubectl delete crd targetgroupbindings.elbv2.k8s.aws || true

	@echo "$(GREEN)Cleanup completed!$(NC)"

# Add a verification target
aws-verify-cleanup:
	@echo "$(BLUE)Verifying cleanup...$(NC)"
	@echo "$(BLUE)Checking for Helm release...$(NC)"
	@helm list -n kube-system | grep aws-load-balancer-controller || echo "Helm release not found"
	@echo "$(BLUE)Checking for deployment...$(NC)"
	@kubectl get deployment -n kube-system aws-load-balancer-controller || echo "Deployment not found"
	@echo "$(BLUE)Checking for service account...$(NC)"
	@kubectl get serviceaccount -n kube-system aws-load-balancer-controller || echo "Service account not found"
	@echo "$(BLUE)Checking for IAM policy...$(NC)"
	@aws iam list-policies --query 'Policies[?PolicyName==`AWSLoadBalancerControllerIAMPolicy`].Arn' --output text || echo "Policy not found"

# Add a new target to create cluster role binding
aws-create-cluster-role-binding:
	@echo "$(BLUE)Creating cluster role binding...$(NC)"
	@kubectl create clusterrolebinding aws-load-balancer-controller \
		--clusterrole=aws-load-balancer-controller \
		--serviceaccount=kube-system:aws-load-balancer-controller || true

# Add this to your aws-deploy-app target
aws-deploy-app: aws-check-prerequisites aws-deploy aws-create-image aws-push-image aws-create-cluster-role-binding aws-setup-lb-controller aws-deploy-application

# Add a new target for debugging the Load Balancer Controller
aws-debug-lb-controller:
	@echo "$(BLUE)Debugging AWS Load Balancer Controller...$(NC)"
	@echo "$(BLUE)Helm version:$(NC)"
	@helm version
	@echo "$(BLUE)Helm repositories:$(NC)"
	@helm repo list
	@echo "$(BLUE)Helm releases:$(NC)"
	@helm list -A
	@echo "$(BLUE)Kubernetes version:$(NC)"
	@kubectl version
	@echo "$(BLUE)Kubernetes nodes:$(NC)"
	@kubectl get nodes
	@echo "$(BLUE)Load Balancer Controller deployment:$(NC)"
	@kubectl get deployment -n kube-system aws-load-balancer-controller -o yaml
	@echo "$(BLUE)Load Balancer Controller pods:$(NC)"
	@kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
	@echo "$(BLUE)Load Balancer Controller logs:$(NC)"
	@kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=100
	@echo "$(BLUE)Service account:$(NC)"
	@kubectl get serviceaccount -n kube-system aws-load-balancer-controller -o yaml
	@echo "$(BLUE)Cluster info:$(NC)"
	@kubectl cluster-info

# Deploy application
aws-deploy-application:
	@echo "$(BLUE)Deploying application to EKS...$(NC)"
	# Get ECR repository URL
	$(eval ECR_URL := $(shell aws sts get-caller-identity --query Account --output text).dkr.ecr.$(AWS_REGION).amazonaws.com/$(ECR_REPOSITORY_NAME))

	@echo "$(BLUE)Using ECR repository: $(ECR_URL)$(NC)"

	# Check if image exists in ECR
	@echo "$(BLUE)Verifying image in ECR...$(NC)"
	@aws ecr describe-images --repository-name $(ECR_REPOSITORY_NAME) --image-ids imageTag=latest || \
		{ echo "$(RED)Image not found in ECR. Make sure to push the image first.$(NC)"; exit 1; }

	# Debug current state
	@echo "$(BLUE)Current Helm releases:$(NC)"
	@helm list

	@echo "$(BLUE)Current Kubernetes resources:$(NC)"
	@kubectl get all

	# Delete existing release if it exists
	@echo "$(BLUE)Cleaning up existing release...$(NC)"
	@helm uninstall $(HELM_RELEASE_NAME) || true
	@kubectl delete deployment $(HELM_RELEASE_NAME) || true
	@kubectl delete service $(HELM_RELEASE_NAME)-svc || true
	@kubectl delete ingress $(HELM_RELEASE_NAME) || true

	# Wait for resources to be deleted
	@echo "$(BLUE)Waiting for resources to be cleaned up...$(NC)"
	@sleep 10

	# Install with increased timeout and debugging
	@echo "$(BLUE)Installing Helm chart...$(NC)"
	@helm upgrade --install $(HELM_RELEASE_NAME) $(HELM_CHART_PATH) \
		-f $(HELM_CHART_PATH)/values-aws.yaml \
		--set imageName=$(ECR_URL):latest \
		--timeout 10m \
		--debug \
		--wait || \
		{ echo "$(RED)Helm deployment failed. Checking resources:$(NC)"; \
		  echo "$(BLUE)Pods:$(NC)"; \
		  kubectl get pods; \
		  echo "$(BLUE)Pod logs:$(NC)"; \
		  kubectl logs -l app=$(HELM_RELEASE_NAME) --all-containers --tail=50; \
		  echo "$(BLUE)Events:$(NC)"; \
		  kubectl get events --sort-by='.lastTimestamp' | tail -n 20; \
		  exit 1; }


# Add a target to get the application URL
aws-get-url:
	@echo "$(BLUE)Getting application URL...$(NC)"
	@echo "Application should be available at:"
	@echo "http://$$(kubectl get ingress $(HELM_RELEASE_NAME) -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"

# Full deployment process
aws-deploy-app: aws-deploy aws-create-image aws-push-image aws-setup-lb-controller aws-deploy-application aws-get-url

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
