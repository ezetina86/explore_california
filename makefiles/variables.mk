# Shared variables
BLUE := \033[1;34m
GREEN := \033[1;32m
RED := \033[1;31m
YELLOW := \033[1;33m
NC := \033[0m

# Common variables
HELM_RELEASE_NAME := explore-california-website
HELM_CHART_PATH := chart
IMAGE_NAME := explorecalifornia.com
WEBSITE_URL := explorecalifornia.com
OLD_URL := eapi.opswatgears.com
HOST_FILE := /etc/hosts
SUDO := sudo
PLATFORM_AWS := linux/amd64
PLATFORM_LOCAL := linux/arm64
HELM_VALUES_LOCAL := $(HELM_CHART_PATH)/values.yaml
HELM_VALUES_AWS := $(HELM_CHART_PATH)/values-aws.yaml
CURRENT_DIR := $(shell pwd)
DOCKERFILE_PATH := $(CURRENT_DIR)/Dockerfile  # Dockerfile is in current directory
CONTEXT_PATH := $(CURRENT_DIR)
