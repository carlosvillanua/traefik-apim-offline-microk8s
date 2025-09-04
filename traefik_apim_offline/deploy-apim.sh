#!/bin/bash

set -e

echo "🚀 Deploying Traefik API Management..."

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load Keycloak variables if available
if [ -f "${SCRIPT_DIR}/.keycloak_vars" ]; then
    echo "🔑 Loading Keycloak variables..."
    source "${SCRIPT_DIR}/.keycloak_vars"
    echo "✅ Loaded TRAEFIK_USER_ID: ${TRAEFIK_USER_ID}"
else
    echo "⚠️  No Keycloak variables found. Run deploy-keycloak.sh first or set TRAEFIK_USER_ID manually"
    if [ -z "$TRAEFIK_USER_ID" ]; then
        echo "❌ TRAEFIK_USER_ID is required for ManagedApplication"
        exit 1
    fi
fi

# Detect Kubernetes platform - simplified approach
KUBECTL_CMD="microk8s kubectl"
PLATFORM="microk8s"

if microk8s kubectl get nodes &>/dev/null; then
    KUBECTL_CMD="microk8s kubectl"
    PLATFORM="microk8s"
elif kubectl cluster-info 2>/dev/null | grep -q "k3d"; then
    KUBECTL_CMD="kubectl"
    PLATFORM="k3d" 
else
    echo "❌ Could not detect MicroK8s or k3d platform"
    exit 1
fi

# Setup environment variables based on platform
export HOST_IP=$(ifconfig | grep "inet " | grep -v 127.0.0.1 | head -1 | awk '{print $2}')

if [[ "$PLATFORM" == "microk8s" ]]; then
    # MicroK8s configuration
    export VM_IP=$(microk8s kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed 's|https://||' | sed 's|:.*||')
    export TRAEFIK_PORT=$(microk8s kubectl get svc -n traefik traefik -o jsonpath='{.spec.ports[0].nodePort}')
    export BASE_URL="http://${VM_IP}:${TRAEFIK_PORT}"
    
    # For MicroK8s, services are external and accessed via HOST_IP
    export KEYCLOAK_IP="${HOST_IP}"
    export KEYCLOAK_PORT="8090"
    export REDIS_IP="${HOST_IP}"
    export REDIS_PORT="6380"
    
elif [[ "$PLATFORM" == "k3d" ]]; then
    # k3d configuration
    export TRAEFIK_IP="${HOST_IP}"
    export TRAEFIK_PORT="80"
    export BASE_URL="http://${TRAEFIK_IP}:${TRAEFIK_PORT}"
    
    # Get k3d service IPs dynamically from LoadBalancer
    echo "🔍 Getting k3d service IPs..."
    export KEYCLOAK_IP=$(kubectl get svc keycloak -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    export REDIS_IP=$(kubectl get svc redis -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    
    # Wait for LoadBalancer IPs to be assigned
    if [[ -z "$KEYCLOAK_IP" || "$KEYCLOAK_IP" == "null" ]]; then
        echo "⏳ Waiting for Keycloak LoadBalancer IP..."
        kubectl wait --for=jsonpath='{.status.loadBalancer.ingress[0].ip}' svc/keycloak --timeout=300s
        export KEYCLOAK_IP=$(kubectl get svc keycloak -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    fi
    
    if [[ -z "$REDIS_IP" || "$REDIS_IP" == "null" ]]; then
        echo "⏳ Waiting for Redis LoadBalancer IP..."
        kubectl wait --for=jsonpath='{.status.loadBalancer.ingress[0].ip}' svc/redis --timeout=300s
        export REDIS_IP=$(kubectl get svc redis -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    fi
    
    export KEYCLOAK_PORT="8080"
    export REDIS_PORT="6379"
fi

# Set OIDC URLs
export EXTERNAL_OIDC_ISSUER="http://${KEYCLOAK_IP}:${KEYCLOAK_PORT}/realms/master"
export INTERNAL_OIDC_ISSUER="http://${KEYCLOAK_IP}:${KEYCLOAK_PORT}/realms/master"
export API_SERVER_URL="${BASE_URL}"
export TRUSTED_URL="${BASE_URL}"

if [[ "$PLATFORM" == "microk8s" ]]; then
    export PORTAL_HOST="${VM_IP}"
else
    export PORTAL_HOST="${TRAEFIK_IP}"
fi

echo "Using HOST_IP: ${HOST_IP}"
if [[ "$PLATFORM" == "microk8s" ]]; then
    echo "Using VM_IP: ${VM_IP}"
fi
echo "Using TRAEFIK_PORT: ${TRAEFIK_PORT}"
echo "Using KEYCLOAK_IP: ${KEYCLOAK_IP}:${KEYCLOAK_PORT}"
echo "Using REDIS_IP: ${REDIS_IP}:${REDIS_PORT}"
echo "Base URL: ${BASE_URL}"
echo "Keycloak URL: ${INTERNAL_OIDC_ISSUER}"

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
envsubst < "${SCRIPT_DIR}/apim.yaml" | microk8s kubectl apply -f -

# Deploy API definition
echo "🔗 Deploying API definition..."
envsubst < "${SCRIPT_DIR}/api.yaml" | microk8s kubectl apply -f -

# Deploy API portal  
echo "🌐 Deploying API portal..."
envsubst < "${SCRIPT_DIR}/portal.yaml" | microk8s kubectl apply -f -

echo "✅ API Management deployed successfully!"

# Fix Keycloak redirect URIs for portal authentication
if [[ "$PLATFORM" == "microk8s" ]]; then
    echo "🔧 Configuring Keycloak redirect URIs for API Portal..."
    
    # Switch to k3d context to access Keycloak
    current_context=$(kubectl config current-context)
    kubectl config use-context k3d-k3d-services > /dev/null 2>&1
    
    # Configure kcadm and update redirect URIs
    if kubectl exec deployment/keycloak -- /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --user admin --password admin123 > /dev/null 2>&1; then
        # Get traefik client ID
        client_id=$(kubectl exec deployment/keycloak -- /opt/keycloak/bin/kcadm.sh get clients -r master -q clientId=traefik --fields id 2>/dev/null | grep '"id"' | cut -d'"' -f4)
        
        if [[ -n "$client_id" ]]; then
            # Update redirect URIs
            kubectl exec deployment/keycloak -- /opt/keycloak/bin/kcadm.sh update clients/$client_id -r master -s "redirectUris=[\"${BASE_URL}/portal/*\",\"${BASE_URL}/callback\",\"${BASE_URL}/*\"]" > /dev/null 2>&1
            echo "   ✅ Updated Keycloak redirect URIs for ${BASE_URL}"
        fi
    fi
    
    # Switch back to original context
    kubectl config use-context $current_context > /dev/null 2>&1 || true
fi

# Get access information
echo "📱 Access your services at:"
echo "  - API Portal: ${BASE_URL}/portal"
echo "  - Weather API: ${BASE_URL}/weather"
echo "  - Keycloak Admin: http://${KEYCLOAK_IP}:${KEYCLOAK_PORT}/admin/"
echo "  - Redis: ${REDIS_IP}:${REDIS_PORT}"

if [[ "$PLATFORM" == "microk8s" ]]; then
    echo ""
    echo "🔧 Platform: MicroK8s"
    echo "   Traefik Dashboard: ${BASE_URL}/dashboard/"
elif [[ "$PLATFORM" == "k3d" ]]; then
    echo ""
    echo "🔧 Platform: k3d"
    echo "   Services accessible via LoadBalancer IPs"
fi