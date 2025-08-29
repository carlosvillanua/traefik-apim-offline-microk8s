#!/bin/bash

set -e

echo "🚀 Deploying Redis with generated password..."

# Generate random Redis password
REDIS_PASSWORD=$(openssl rand -base64 32)
REDIS_PASSWORD_BASE64=$(echo -n "$REDIS_PASSWORD" | base64)

echo "Generated Redis password: ${REDIS_PASSWORD:0:8}..."

# Export for use in YAML templates
export REDIS_PASSWORD
export REDIS_PASSWORD_BASE64

# Create namespace
microk8s kubectl create namespace traefik --dry-run=client -o yaml | kubectl apply -f -

# Deploy Redis secret with generated password
envsubst < redis-secret.yaml | microk8s kubectl apply -f -

# Update deployment template with generated password
envsubst < redis-deployment.yaml | microk8s kubectl apply -f -

# Deploy service
microk8s kubectl apply -f redis-service.yaml

echo "⏳ Waiting for Redis to be ready..."
microk8s kubectl wait --for=condition=ready pod -l app=redis -n traefik --timeout=300s

echo "✅ Redis deployed successfully!"
echo "Password: $REDIS_PASSWORD"
echo ""
echo "To use with Traefik Hub:"
echo "export REDIS_PASSWORD=\"$REDIS_PASSWORD\""