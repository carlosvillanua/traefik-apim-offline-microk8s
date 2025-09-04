#!/bin/bash

set -e

echo "🚀 Setting up complete k3d cluster with Keycloak and Redis..."

# Get host IP for external access
HOST_IP=${HOST_IP:-$(ifconfig | grep "inet " | grep -v 127.0.0.1 | head -1 | awk '{print $2}')}

echo "📡 Host IP: $HOST_IP"

# Create k3d cluster if it doesn't exist
if ! k3d cluster list | grep -q "k3d-services"; then
    echo "🔧 Creating k3d cluster with port mappings..."
    k3d cluster create k3d-services \
        --port "80:80@loadbalancer" \
        --port "443:443@loadbalancer" \
        --port "8090:8080@loadbalancer" \
        --port "8091:8443@loadbalancer" \
        --port "6380:6379@loadbalancer" \
        --port "8092:8080@loadbalancer"
else
    echo "✅ k3d cluster already exists"
fi

# Switch to k3d context
kubectl config use-context k3d-k3d-services

# Get the script directory to ensure proper paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_MANIFESTS_DIR="$(dirname "$SCRIPT_DIR")"

# Deploy Redis
echo "🔴 Deploying Redis..."
cd "${K8S_MANIFESTS_DIR}/redis"
HOST_IP=$HOST_IP ./deploy-redis.sh

# Deploy Keycloak
echo "🔐 Deploying Keycloak..."
cd "${K8S_MANIFESTS_DIR}/keycloak"
HOST_IP=$HOST_IP ./deploy-keycloak.sh