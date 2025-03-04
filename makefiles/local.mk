# makefiles/local.mk

# Local development variables
REGISTRY_NAME := local-registry
REGISTRY_PORT := 5001
CLUSTER_NAME := explorecalifornia.com

# Phony targets for local development
.PHONY: local-all local-clean local-deploy local-test \
        local-create-registry local-create-image local-create-cluster \
        local-connect-registry local-install local-deploy-helm \
        local-check-deployment local-update-hosts

# Main local targets
local-all: local-deploy local-test
	@echo "$(GREEN)Local setup complete!$(NC)"

local-deploy: local-create-cluster-with-registry
	@echo "$(BLUE)Deploying application using Helm...$(NC)"
	@kubectl get nodes
	@echo "$(BLUE)Deploying ingress controller...$(NC)"
	@kubectl apply -f https://kind.sigs.k8s.io/examples/ingress/deploy-ingress-nginx.yaml || \
		{ echo "$(RED)Failed to apply ingress controller$(NC)"; exit 1; }
	@echo "$(BLUE)Waiting for ingress controller to be ready...$(NC)"
	@kubectl wait --namespace ingress-nginx \
		--for=condition=ready pod \
		--selector=app.kubernetes.io/component=controller \
		--timeout=90s || { echo "$(RED)Ingress controller failed to start$(NC)"; exit 1; }
	@$(MAKE) local-deploy-helm
	@$(MAKE) local-update-hosts

# Installation targets
local-install:
	@echo "$(BLUE)Installing required tools...$(NC)"
	@brew install kind kubectl helm || { echo "$(RED)Failed to install tools$(NC)"; exit 1; }

# Registry management
local-create-registry:
	@echo "$(BLUE)Setting up local registry...$(NC)"
	@if [ -z "$$(podman ps -aq --filter "name=$(REGISTRY_NAME)")" ]; then \
		echo "$(YELLOW)Creating new registry...$(NC)"; \
		podman run --name $(REGISTRY_NAME) -d --network kind \
			--restart=always -p $(REGISTRY_PORT):5000 registry:2 || \
			{ echo "$(RED)Failed to create registry$(NC)"; exit 1; }; \
	else \
		echo "$(YELLOW)Registry container exists$(NC)"; \
		if [ -z "$$(podman ps -q --filter "name=$(REGISTRY_NAME)")" ]; then \
			echo "$(YELLOW)Starting existing registry...$(NC)"; \
			podman start $(REGISTRY_NAME) || \
				{ echo "$(RED)Failed to start registry$(NC)"; exit 1; }; \
		else \
			echo "$(GREEN)Registry is already running$(NC)"; \
		fi \
	fi

# Image building
local-create-image: local-create-registry
	@echo "$(BLUE)Building and pushing image...$(NC)"
	@podman build --platform $(PLATFORM_LOCAL) -t $(IMAGE_NAME) . && \
		podman tag $(IMAGE_NAME) localhost:$(REGISTRY_PORT)/$(IMAGE_NAME) && \
		podman push --tls-verify=false localhost:$(REGISTRY_PORT)/$(IMAGE_NAME) || \
		{ echo "$(RED)Failed to build/push image$(NC)"; exit 1; }

# Cluster management
local-create-cluster: local-install
	@echo "$(BLUE)Creating Kind cluster...$(NC)"
	@kind create cluster --config ./kind_config.yaml --name $(CLUSTER_NAME) || \
		{ echo "$(RED)Failed to create cluster$(NC)"; exit 1; }
	@kubectl get nodes

local-wait-for-cluster:
	@echo "$(BLUE)Waiting for cluster to be ready...$(NC)"
	@for i in {1..30}; do \
		if kubectl wait --for=condition=Ready nodes --all --timeout=60s >/dev/null 2>&1; then \
			echo "$(GREEN)Cluster is ready!$(NC)"; \
			exit 0; \
		fi; \
		echo "$(YELLOW)Waiting for cluster to be ready... ($$i/30)$(NC)"; \
		sleep 10; \
	done; \
	echo "$(RED)Cluster failed to become ready$(NC)"; \
	exit 1

local-connect-registry:
	@echo "$(BLUE)Connecting registry to Kind network...$(NC)"
	@podman network connect kind $(REGISTRY_NAME) || true
	@kubectl apply -f ./kind_configmap.yaml || \
		{ echo "$(RED)Failed to apply registry config$(NC)"; exit 1; }

local-create-cluster-with-registry: local-create-image local-create-cluster local-wait-for-cluster local-connect-registry
	@echo "$(GREEN)Cluster setup complete!$(NC)"

# Deployment helpers
local-deploy-helm:
	@echo "$(BLUE)Deploying application with Helm...$(NC)"
	@helm upgrade --atomic --install $(HELM_RELEASE_NAME) $(HELM_CHART_PATH) \
		-f $(HELM_VALUES_LOCAL) \
		--wait || { echo "$(RED)Failed to deploy with Helm$(NC)"; exit 1; }
	@echo "$(GREEN)Helm deployment successful!$(NC)"

local-check-deployment:
	@echo "$(BLUE)Checking deployment status...$(NC)"
	@echo "$(BLUE)Helm release status:$(NC)"
	@helm list | grep $(HELM_RELEASE_NAME) || echo "$(YELLOW)No Helm release found$(NC)"
	@echo "$(BLUE)Kubernetes resources:$(NC)"
	@kubectl get nodes
	@kubectl get deployments
	@kubectl get pods
	@kubectl get services
	@kubectl get ingress
	@echo "$(BLUE)Checking pod logs...$(NC)"
	@kubectl get pods -l app=$(IMAGE_NAME) -o name | xargs -I {} kubectl logs {}

local-update-hosts:
	@echo "$(BLUE)Updating hosts file...$(NC)"
	@if [ -w $(HOST_FILE) ]; then \
		sed -i.bak \
			-e 's/^127.0.0.1.*$(OLD_URL)/# &/' \
			-e 's/# *127.0.0.1.*$(WEBSITE_URL)/127.0.0.1    $(WEBSITE_URL)/' \
			$(HOST_FILE) || { echo "$(RED)Failed to update hosts file$(NC)"; exit 1; }; \
	else \
		echo "$(YELLOW)Requesting sudo privileges to modify hosts file...$(NC)"; \
		$(SUDO) sed -i.bak \
			-e 's/^127.0.0.1.*$(OLD_URL)/# &/' \
			-e 's/# *127.0.0.1.*$(WEBSITE_URL)/127.0.0.1    $(WEBSITE_URL)/' \
			$(HOST_FILE) || { echo "$(RED)Failed to update hosts file$(NC)"; exit 1; }; \
	fi
	@echo "$(GREEN)Hosts file updated$(NC)"

# Testing
local-test:
	@echo "$(BLUE)Testing website accessibility...$(NC)"
	@for i in {1..12}; do \
		if curl -s -o /dev/null -w "%{http_code}" http://$(WEBSITE_URL) | grep -q "200"; then \
			echo "$(GREEN)Website is accessible!$(NC)"; \
			exit 0; \
		fi; \
		echo "$(YELLOW)Waiting for website to become accessible... ($$i/12)$(NC)"; \
		sleep 10; \
	done; \
	echo "$(RED)Website failed to become accessible$(NC)"; \
	exit 1

# Cleanup
local-clean: local-clean-helm local-restore-hosts local-delete-cluster
	@echo "$(GREEN)Local cleanup complete!$(NC)"

local-clean-helm:
	@echo "$(BLUE)Cleaning up Helm release...$(NC)"
	@helm list | grep -q $(HELM_RELEASE_NAME) && \
		helm uninstall $(HELM_RELEASE_NAME) || \
		echo "$(YELLOW)No Helm release found to clean up$(NC)"

local-delete-registry:
	@echo "$(BLUE)Removing registry...$(NC)"
	@podman stop $(REGISTRY_NAME) 2>/dev/null || true
	@podman rm $(REGISTRY_NAME) 2>/dev/null || true

local-delete-cluster: local-delete-registry
	@echo "$(BLUE)Deleting Kind cluster...$(NC)"
	@kind delete cluster --name $(CLUSTER_NAME) 2>/dev/null || true

local-restore-hosts:
	@echo "$(BLUE)Restoring hosts file...$(NC)"
	@if [ -w $(HOST_FILE) ]; then \
		sed -i.bak \
			-e 's/^127.0.0.1.*$(WEBSITE_URL)/# &/' \
			-e 's/# *127.0.0.1.*$(OLD_URL)/127.0.0.1    $(OLD_URL)/' \
			$(HOST_FILE) || { echo "$(RED)Failed to restore hosts file$(NC)"; exit 1; }; \
	else \
		echo "$(YELLOW)Requesting sudo privileges to modify hosts file...$(NC)"; \
		$(SUDO) sed -i.bak \
			-e 's/^127.0.0.1.*$(WEBSITE_URL)/# &/' \
			-e 's/# *127.0.0.1.*$(OLD_URL)/127.0.0.1    $(OLD_URL)/' \
			$(HOST_FILE) || { echo "$(RED)Failed to restore hosts file$(NC)"; exit 1; }; \
	fi
	@echo "$(GREEN)Hosts file restored$(NC)"
