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
.PHONY: aws-all aws-clean aws-deploy aws-destroy aws-init \
        aws-check-credentials aws-create-state-resources aws-cleanup-state \
        aws-push-image aws-deploy-app aws-check-deployment

# Main AWS targets
aws-all: aws-deploy-app
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

# Application deployment
aws-deploy-app: aws-deploy aws-push-image
	@echo "$(BLUE)Installing AWS Load Balancer Controller...$(NC)"
	@helm repo add eks https://aws.github.io/eks-charts
	@helm repo update
	@kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller/crds?ref=master"
	@helm upgrade -i aws-load-balancer-controller eks/aws-load-balancer-controller \
		--set clusterName=$(EKS_CLUSTER_NAME) \
		--set serviceAccount.create=true \
		-n kube-system
	@echo "$(BLUE)Deploying application to EKS...$(NC)"
	@helm upgrade --atomic --install $(HELM_RELEASE_NAME) $(HELM_CHART_PATH) \
		--set image.repository=$(shell aws sts get-caller-identity --query Account --output text).dkr.ecr.$(AWS_REGION).amazonaws.com/$(ECR_REPOSITORY_NAME) \
		--set image.tag=latest \
		--wait

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
