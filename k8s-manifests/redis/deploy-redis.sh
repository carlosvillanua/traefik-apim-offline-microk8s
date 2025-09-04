#!/bin/bash

set -e

echo "🚀 Deploying Redis to k3d cluster (no authentication)..."

# Get host IP for external access
HOST_IP=${HOST_IP:-$(ifconfig | grep "inet " | grep -v 127.0.0.1 | head -1 | awk '{print $2}')}

kubectl apply -f redis-k3d-deployment.yaml

echo "⏳ Waiting for Redis to be ready..."
kubectl wait --for=condition=ready pod -l app=redis --timeout=300s

echo "✅ Redis deployed successfully!"

echo "🌐 Access Redis: ${HOST_IP}:6380"
echo "Redis is configured with password authentication."
echo ""
echo "📋 For MicroK8s integration, use these values:"
echo "export REDIS_ENDPOINT=${HOST_IP}:6380"
echo "export REDIS_PASSWORD=\"redis_password123\""
echo ""
echo "To test connection:"
echo "redis-cli -h ${HOST_IP} -p 6380 -a redis_password123 ping"
REDIS_ENDPOINT=${HOST_IP}:6380
REDIS_PASSWORD=redis_password123