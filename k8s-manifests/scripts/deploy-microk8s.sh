#!/bin/bash

# Install MicroK8s
brew install ubuntu/microk8s/microk8s

# Install MicroK8s (this creates a VM)
microk8s install

# Start MicroK8s
microk8s start

# Wait for cluster to be ready
microk8s status --wait-ready

# Enable required addons
microk8s enable dns hostpath-storage helm3