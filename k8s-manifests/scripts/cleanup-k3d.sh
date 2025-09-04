#!/bin/bash

set -e

echo "🧹 Cleaning up k3d cluster..."

# Delete k3d cluster
if k3d cluster list | grep -q "k3d-services"; then
    echo "🗑️  Deleting k3d-services cluster..."
    k3d cluster delete k3d-services
    echo "✅ k3d-services cluster deleted"
else
    echo "⚠️  k3d-services cluster not found"
fi

# Clean up any dangling docker containers
echo "🧽 Cleaning up Docker resources..."
docker system prune -f > /dev/null 2>&1 || true

echo "✨ Cleanup completed!"