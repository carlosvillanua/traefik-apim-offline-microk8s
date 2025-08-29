#!/bin/bash

set -e

echo "🎯 Deploying Traefik Dashboard..."

# Deploy dashboard middleware and IngressRoute
microk8s kubectl apply -f dashboard-middleware.yaml
microk8s kubectl apply -f dashboard-ingressroute.yaml

echo "✅ Dashboard deployed successfully!"

# Get access information
VM_IP=$(microk8s kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed 's|https://||' | sed 's|:.*||')
TRAEFIK_PORT=$(microk8s kubectl get svc -n traefik traefik -o jsonpath='{.spec.ports[0].nodePort}')
BASE_URL="http://${VM_IP}:${TRAEFIK_PORT}"

echo "📱 Access your Traefik Dashboard at: ${BASE_URL}/dashboard/"