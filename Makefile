#!/usr/bin/env make
.PHONY: run_website stop_website install_kind install_kubectl create_docker_registry create_kind_cluster

run_website:
	podman build --platform linux/arm64 -t explorecalifornia.com . && \
		podman run --rm --name explorecalifornia.com -p 5001:80 -d explorecalifornia.com

stop_website:
	podman stop explorecalifornia.com

install_kind:
	curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.11.1/kind-linux-arm64 && \
		chmod +x ./kind && \
		mv ./kind /usr/local/bin/kind && \
		kind --version

install_kubectl:
	curl -Lo ./kubectl https://dl.k8s.io/release/v1.21.0/bin/linux/arm64/kubectl && \
		chmod +x ./kubectl && \
		mv ./kubectl /usr/local/bin/kubectl && \
		kubectl version --client

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
	kind create cluster --name explorecalifornia.com && \
		kubectl get nodes
