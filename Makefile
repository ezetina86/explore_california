# Makefile
include makefiles/variables.mk

# Default to local development
.DEFAULT_GOAL := local-all

# Determine deployment target
ifeq ($(DEPLOY_TARGET),aws)
    include makefiles/aws.mk
else
    include makefiles/local.mk
endif

.PHONY: all clean help

help:
	@echo "$(BLUE)Available targets:$(NC)"
	@echo "$(GREEN)Local Development:$(NC)"
	@echo "  make local-all         - Deploy to local Kind cluster"
	@echo "  make local-clean       - Clean up local resources"
	@echo ""
	@echo "$(GREEN)AWS Deployment:$(NC)"
	@echo "  make aws-all           - Deploy to AWS EKS"
	@echo "  make aws-clean         - Clean up AWS resources"
	@echo ""
	@echo "Use DEPLOY_TARGET=aws to switch to AWS deployment"
