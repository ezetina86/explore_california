# Explore California

## Overview

This project automates the deployment of the Explore California website using Kind (Kubernetes in Docker), Podman, and Nginx Ingress Controller.

## Prerequisites

### Required Software

| Software | Version | Installation Command |
|----------|---------|---------------------|
| Podman   | 4.x+    | `brew install podman` |
| Kind     | 0.20+   | `brew install kind` |
| kubectl  | 1.28+   | `brew install kubectl` |

### System Requirements

- MacOS or Linux
- 4GB RAM minimum
- 10GB free disk space
- sudo privileges (for hosts file modification)

## Available Make Commands

### Core Commands

| Command | Description |
|---------|-------------|
| make    | Deploys everything and tests website accessibility |
| make clean | Cleans up all resources and restores original configuration |
| make help | Shows available commands |

### Individual Commands

| Command | Description |
|---------|-------------|
| make create_image | Builds and pushes the container image |
| make create_kind_cluster | Creates a new Kind cluster |
| make deploy | Deploys the application with all components |
| make test_website | Tests website accessibility |
| make check_hosts | Displays current hosts file entries |
| make check_deployment | Shows status of all deployed components |

## Deployment Process

### Initial Setup

```bash
# Initialize podman machine (if not already done)
podman machine init
podman machine start
```

### Full Deployment

```bash
# Deploy everything
make

# Verify deployment
make check_deployment
```

### Cleanup

```bash
# Remove all resources
make clean
```

### Configuration Files

- kind_config.yaml
Controls Kind cluster configuration including port mappings and registry settings.
- deployment.yaml
Defines the Kubernetes deployment configuration including:
- Container image
- Resource limits
- Replica count
- service.yaml
Configures the Kubernetes service for the application.

ingress.yaml
Sets up Nginx ingress rules for routing traffic.

### Security Notes

- Local registry runs without TLS (development only)
- Requires sudo access for hosts file modifications
- Uses default Kind security settings
<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 5.0 |

## Providers

No providers.

## Modules

No modules.

## Resources

No resources.

## Inputs

No inputs.

## Outputs

No outputs.
<!-- END_TF_DOCS -->
