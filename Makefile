#!/usr/bin/env make

# Variables
REGISTRY_NAME := local-registry
REGISTRY_PORT := 5001
IMAGE_NAME := explorecalifornia.com
CLUSTER_NAME := explorecalifornia.com
PLATFORM := linux/arm64
HOST_FILE := /etc/hosts
WEBSITE_URL := explorecalifornia.com
OLD_URL := eapi.opswatgears.com
SUDO := sudo


# Colors for output
BLUE := \033[1;34m
GREEN := \033[1;32m
RED := \033[1;31m
YELLOW := \033[1;33m
NC := \033[0m # No Color

# Phony targets
.PHONY: all clean install build deploy help \
        create_image stop_website install_kind install_kubectl \
        create_docker_registry create_kind_cluster connect_registry_to_kind \
        create_kind_cluster_with_registry delete_kind_cluster delete_docker_registry \
		deploy test_website update_hosts restore_hosts check_hosts check_deployment

# Default target
all: deploy test_website
	@echo "$(GREEN)Setup complete and website is running!$(NC)"

# Help target
help:
	@echo "$(BLUE)Available targets:$(NC)"
	@echo "  $(GREEN)all$(NC)                      - Set up everything (default)"
connect_registry_to_kind_network:
	podman network connect kind local-registry || true;

connect_registry_to_kind: connect_registry_to_kind_network
	kubectl apply -f ./kind_configmap.yaml

create_kind_cluster_with_registry:
	$(MAKE) create_kind_cluster && \
		$(MAKE) connect_registry_to_kind
install: install_kind install_kubectl

install_kind:
	@echo "$(BLUE)Installing Kind...$(NC)"
	@brew install kind || { echo "$(RED)Failed to install Kind$(NC)"; exit 1; }

install_kubectl:
	@echo "$(BLUE)Installing kubectl...$(NC)"
	@brew install kubectl || { echo "$(RED)Failed to install kubectl$(NC)"; exit 1; }

# Registry management
create_docker_registry:
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
create_image: create_docker_registry
	@echo "$(BLUE)Building and pushing image...$(NC)"
	@podman build --platform $(PLATFORM) -t $(IMAGE_NAME) . && \
		podman tag $(IMAGE_NAME) localhost:$(REGISTRY_PORT)/$(IMAGE_NAME) && \
		podman push --tls-verify=false localhost:$(REGISTRY_PORT)/$(IMAGE_NAME) || \
		{ echo "$(RED)Failed to build/push image$(NC)"; exit 1; }

# Cluster management
create_kind_cluster: install
	@echo "$(BLUE)Creating Kind cluster...$(NC)"
	@kind create cluster --config ./kind_config.yaml --name $(CLUSTER_NAME) || \
		{ echo "$(RED)Failed to create cluster$(NC)"; exit 1; }
	@kubectl get nodes

wait_for_cluster:
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

connect_registry_to_kind:
	@echo "$(BLUE)Connecting registry to Kind network...$(NC)"
	@podman network connect kind $(REGISTRY_NAME) || true
	@kubectl apply -f ./kind_configmap.yaml || \
		{ echo "$(RED)Failed to apply registry config$(NC)"; exit 1; }

create_kind_cluster_with_registry: create_image create_kind_cluster wait_for_cluster connect_registry_to_kind
	@echo "$(GREEN)Cluster setup complete!$(NC)"


# Deployment targets
deploy: create_kind_cluster_with_registry
	@echo "$(BLUE)Deploying application...$(NC)"
	@kubectl get nodes
	@echo "$(BLUE)Applying deployment...$(NC)"
	@kubectl apply -f deployment.yaml || { echo "$(RED)Failed to apply deployment$(NC)"; exit 1; }
	@echo "$(BLUE)Checking deployment status...$(NC)"
	@kubectl get deployments
	@echo "$(BLUE)Checking pods...$(NC)"
	@kubectl get pods
	@echo "$(BLUE)Applying service...$(NC)"
	@kubectl apply -f service.yaml || { echo "$(RED)Failed to apply service$(NC)"; exit 1; }
	@echo "$(BLUE)Deploying ingress controller...$(NC)"
	@kubectl apply -f https://kind.sigs.k8s.io/examples/ingress/deploy-ingress-nginx.yaml || \
		{ echo "$(RED)Failed to apply ingress controller$(NC)"; exit 1; }
	@echo "$(BLUE)Waiting for ingress controller to be ready...$(NC)"
	@kubectl wait --namespace ingress-nginx \
		--for=condition=ready pod \
		--selector=app.kubernetes.io/component=controller \
		--timeout=90s || { echo "$(RED)Ingress controller failed to start$(NC)"; exit 1; }
	@kubectl apply -f ingress.yaml || { echo "$(RED)Failed to apply ingress$(NC)"; exit 1; }
	@$(MAKE) update_hosts

check_deployment:
	@echo "$(BLUE)Checking deployment status...$(NC)"
	@kubectl get nodes
	@kubectl get deployments
	@kubectl get pods
	@kubectl get services
	@kubectl get ingress
	@echo "$(BLUE)Checking pod logs...$(NC)"
	@kubectl get pods -l app=$(IMAGE_NAME) -o name | xargs -I {} kubectl logs {}

update_hosts:
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

restore_hosts:
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

check_hosts:
	@echo "$(BLUE)Current hosts file entries:$(NC)"
	@$(SUDO) grep -E "$(WEBSITE_URL)|$(OLD_URL)" $(HOST_FILE) || true

test_website:
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
clean: restore_hosts delete_kind_cluster
	@echo "$(GREEN)Cleanup complete!$(NC)"

delete_docker_registry:
	@echo "$(BLUE)Removing registry...$(NC)"
	@podman stop $(REGISTRY_NAME) 2>/dev/null || true
	@podman rm $(REGISTRY_NAME) 2>/dev/null || true

delete_kind_cluster: delete_docker_registry
	@echo "$(BLUE)Deleting Kind cluster...$(NC)"
	@kind delete cluster --name $(CLUSTER_NAME) 2>/dev/null || true
	@echo "$(GREEN)Cleanup complete!$(NC)"

# Website management
stop_website:
	@echo "$(BLUE)Stopping website...$(NC)"
	@podman stop $(IMAGE_NAME) 2>/dev/null || true
