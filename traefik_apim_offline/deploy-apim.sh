#!/bin/bash

set -e

echo "🚀 Deploying Traefik API Management..."

# Setup environment variables
export VM_IP=$(microk8s kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed 's|https://||' | sed 's|:.*||')
export TRAEFIK_PORT=$(microk8s kubectl get svc -n traefik traefik -o jsonpath='{.spec.ports[0].nodePort}')
export BASE_URL="http://${VM_IP}:${TRAEFIK_PORT}"
export EXTERNAL_OIDC_ISSUER="http://${VM_IP}:${TRAEFIK_PORT}/keycloak/realms/master"
export INTERNAL_OIDC_ISSUER="http://keycloak-service.keycloak.svc.cluster.local:8080/keycloak/realms/master"
export API_SERVER_URL="${BASE_URL}"
export TRUSTED_URL="${BASE_URL}"
export PORTAL_HOST="${VM_IP}"

echo "Using VM_IP: ${VM_IP}"
echo "Using TRAEFIK_PORT: ${TRAEFIK_PORT}"
echo "Base URL: ${BASE_URL}"

# Create namespace
echo "📦 Creating namespace..."
microk8s kubectl create namespace apps --dry-run=client -o yaml | microk8s kubectl apply -f -

# Deploy weather app
echo "🌤️  Deploying weather application..."
microk8s kubectl apply -f https://raw.githubusercontent.com/traefik/hub/main/src/manifests/weather-app.yaml

# Wait for weather app to be ready
microk8s kubectl wait --for=condition=ready pod -l app=weather-app -n apps --timeout=300s

# Deploy API plans
echo "📊 Deploying API plans..."
microk8s kubectl apply -f apim.yaml

# Deploy API definition
echo "🔗 Deploying API definition..."
envsubst < api.yaml | microk8s kubectl apply -f -

# Deploy API portal  
echo "🌐 Deploying API portal..."
envsubst < portal.yaml | microk8s kubectl apply -f -

echo "✅ API Management deployed successfully!"

# Get access information
echo "📱 Access your services at:"
echo "  - API Portal: ${BASE_URL}/portal"
echo "  - Weather API: ${BASE_URL}/weather"
echo "  - Keycloak Admin: ${BASE_URL}/keycloak/admin/"