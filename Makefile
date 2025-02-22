#!/usr/bin/env make
.PHONY: run_website stop_website install_kind install_kubectl create_docker_registry create_kind_cluster \
	connect_resgistry_to_kind_network connect_resgistry_to_kind create_kind_cluster_with_registry delete_kind_cluster \
	delete_docker_registry

run_website:
	podman build --platform linux/arm64 -t explorecalifornia.com . && \
		podman run --rm --name explorecalifornia.com -p 5001:80 -d explorecalifornia.com

stop_website:
	podman stop explorecalifornia.com

install_kind:
	brew install kind || true;

install_kubectl:
	brew install kubectl || true;

create_docker_registry:
	@if [ -z "$$(podman ps -aq --filter "name=local-registry")" ]; then \
		podman run --name local-registry -d --restart=always -p 5001:5001 registry:2; \
	else \
		echo "Registry container exists"; \
		if [ -z "$$(podman ps -q --filter "name=local-registry")" ]; then \
			echo "Starting existing registry container..."; \
			podman start local-registry; \
		else \
			echo "Registry is already running"; \
		fi \
	fi

create_kind_cluster: install_kind install_kubectl create_docker_registry
	kind create cluster --config ./kind_config.yaml --name explorecalifornia.com || true \
		kubectl get nodes

connect_resgistry_to_kind_network:
	podman network connect kind local-registry || true;

connect_resgistry_to_kind: connect_resgistry_to_kind_network
	kubectl apply -f ./kind_configmap.yaml

create_kind_cluster_with_registry:
	$(MAKE) create_kind_cluster && \
		$(MAKE) connect_resgistry_to_kind

delete_docker_registry:
	podman stop local-registry && \
		podman rm local-registry

delete_kind_cluster: delete_docker_registry
	kind delete cluster --name explorecalifornia.com
