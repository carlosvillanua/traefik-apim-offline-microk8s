# Complete MicroK8s Traefik Hub API Management Deployment Guide

This comprehensive guide provides end-to-end instructions for deploying a complete API Management solution using MicroK8s, Traefik Hub, and Keycloak for authentication.

## 🎯 What You'll Deploy

- **MicroK8s** - Lightweight Kubernetes cluster
- **Traefik Hub** - API Gateway with management features (offline mode)
- **Keycloak** - Identity and Access Management with OAuth2/JWT
- **Redis** - For API rate limiting and caching
- **Weather API** - Sample application for testing
- **API Portal** - Developer portal for API documentation
- **JWT Authentication** - Working authentication flow with Keycloak

## 📋 Prerequisites

- macOS with Homebrew (for MicroK8s installation)
- 8GB+ RAM available for VM
- Internet connection for initial setup
- `curl`, `python3`, and `jq` installed

## 🚀 Step 1: Install and Setup MicroK8s

### Install MicroK8s via Homebrew

```bash
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
```

### Get Cluster Information

```bash
# Get VM IP (important for later steps)
export VM_IP=$(microk8s kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed 's|https://||' | sed 's|:.*||')
echo "VM IP: ${VM_IP}"

# Verify cluster is working
microk8s kubectl get nodes
```

## 🔧 Step 2: Install Redis for Rate Limiting

```bash
# Deploy Redis with dynamic password generation
cd k8s-manifests/redis
./deploy-redis.sh

# The script will output the generated password
```

## 🌐 Step 3: Install Traefik Hub

### Get Traefik Hub License

1. Visit [https://traefik.io/traefik-hub/](https://traefik.io/traefik-hub/)
2. Sign up for a free trial
3. Get your license token

### Deploy Traefik Hub

```bash
# Create Traefik Hub license secret (replace YOUR_LICENSE_TOKEN with your actual token)
# You can get a free license from: https://traefik.io/traefik-hub/
export TRAEFIK_HUB_TOKEN=<TRAEFIK_HUB_TOKEN>

microk8s kubectl create namespace traefik --dry-run=client -o yaml | microk8s kubectl apply -f -
microk8s kubectl create secret generic traefik-hub-license \
  --namespace traefik \
  --from-literal=token="${TRAEFIK_HUB_TOKEN}"

# Add Traefik Helm repository
microk8s helm3 repo add traefik https://traefik.github.io/charts
microk8s helm3 repo update

# Install Traefik Hub
microk8s helm3 upgrade --install --namespace traefik traefik traefik/traefik \
  --set hub.token=traefik-hub-license \
  --set hub.apimanagement.enabled=true \
  --set hub.offline=true \
  --set "providers.kubernetesCRD.allowExternalNameServices=true" \
  --set "providers.kubernetesCRD.allowCrossNamespace=true" \
  --set hub.redis.endpoints=redis-master.traefik.svc.cluster.local:6379 \
  --set hub.redis.password="${REDIS_PASSWORD}" \
  --set image.registry=ghcr.io \
  --set image.repository=traefik/traefik-hub \
  --set image.tag=v3.18.0-beta3

# Wait for Traefik to be ready
microk8s kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=traefik -n traefik --timeout=300s
```

### Get Traefik Access Information

```bash
# Get Traefik service port
export TRAEFIK_PORT=$(microk8s kubectl get svc -n traefik traefik -o jsonpath='{.spec.ports[0].nodePort}')
echo "Traefik Port: ${TRAEFIK_PORT}"

# Set base URL for API access
export BASE_URL="http://${VM_IP}:${TRAEFIK_PORT}"
echo "Base URL: ${BASE_URL}"

```

### Configure Traefik Dashboard Access

```bash
# Deploy dashboard configuration
cd ../k8s-manifests/traefik
./deploy-dashboard.sh

# Test dashboard access
curl -s -o /dev/null -w "Dashboard Status: %{http_code}\n" "${BASE_URL}/dashboard/"
```

## 🔐 Step 4: Deploy Keycloak for Authentication

### Run Keycloak Deployment Script

```bash
# Navigate to keycloak manifests directory
cd ../k8s-manifests/keycloak

# Deploy Keycloak with PostgreSQL
./deploy-keycloak.sh
```

This script will:
- Create keycloak namespace
- Deploy PostgreSQL database
- Deploy Keycloak with proper configuration
- Create Traefik IngressRoute for external access

### Verify Keycloak Deployment

```bash
# Check Keycloak pods
microk8s kubectl get pods -n keycloak

# Access Keycloak Admin Console
echo "Keycloak Admin Console: ${BASE_URL}/keycloak/admin/"
echo "Username: admin"
echo "Password: admin"
```

## 🔌 Step 5: Deploy API Management with Weather Application

```bash
# Navigate to traefik_apim_offline directory
cd traefik_apim_offline

# Deploy complete API Management setup
./deploy-apim.sh
```

This script will:
- Set up all required environment variables
- Create the apps namespace  
- Deploy the weather application
- Deploy required middlewares for path handling
- Deploy API plans and catalog
- Deploy API authentication configuration with JWT validation
- Deploy the API portal with OIDC authentication

### Verify Deployment

```bash
# Check all API Management resources
microk8s kubectl get api,apiauth,apiportal,apiportalauth,apiplan -n apps

# Test endpoints
export VM_IP=$(microk8s kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed 's|https://||' | sed 's|:.*||')
export TRAEFIK_PORT=$(microk8s kubectl get svc -n traefik traefik -o jsonpath='{.spec.ports[0].nodePort}')
export BASE_URL="http://${VM_IP}:${TRAEFIK_PORT}"

echo "API Portal: ${BASE_URL}/portal"
echo "Weather API: ${BASE_URL}/weather"
```

## 🧪 Step 6: Test JWT Authentication

### Generate JWT Token

```bash
# Get JWT token from Keycloak
JWT_TOKEN=$(curl -s "${BASE_URL}/keycloak/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&client_id=admin-cli&username=admin&password=admin" | \
  python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])")

echo "JWT Token obtained: ${#JWT_TOKEN} characters"
```

### Test API Authentication

```bash
# Test API without authentication (should return 401)
echo "Testing without authentication:"
curl -s -w "Status: %{http_code}\n" -o /dev/null "${BASE_URL}/weather/"

# Test API with JWT token (should return 403 - authenticated but may need permissions)
echo "Testing with JWT token:"
curl -s -w "Status: %{http_code}\n" -H "Authorization: Bearer $JWT_TOKEN" "${BASE_URL}/weather/" -o /dev/null

# Show detailed response
echo "Detailed response:"
curl -v -H "Authorization: Bearer $JWT_TOKEN" "${BASE_URL}/weather/" --max-time 10
```


### Test API Portal Access

```bash
# Test API Portal
echo "Testing API Portal:"
curl -s -w "Portal Status: %{http_code}\n" -o /dev/null "${BASE_URL}/portal"

echo "API Portal URL: ${BASE_URL}/portal"
```

## 📝 Configuration Files Overview

### Key Configuration Files

1. **api.yaml** - API definition with JWT authentication
   - Configures APIAuth with Keycloak JWT validation
   - Uses `sid` claim from JWT tokens
   - JWKS URL points to Keycloak internal service

2. **apim.yaml** - API Management configuration
   - API plans with rate limiting
   - API catalog items
   - Managed applications and subscriptions

3. **portal.yaml** - Developer portal configuration
   - API portal with OIDC authentication
   - Trusted URLs and routing
   - Portal IngressRoute configuration

4. **k8s-manifests/** - Organized YAML manifests and deployment scripts
   - `k8s-manifests/redis/` - Redis deployment with dynamic password generation
   - `k8s-manifests/traefik/` - Traefik dashboard configuration
   - `k8s-manifests/keycloak/` - Keycloak and PostgreSQL manifests

## 🔧 Troubleshooting

### Common Issues and Solutions

#### 1. Traefik Not Accessible

```bash
# Check Traefik service
microk8s kubectl get svc -n traefik traefik

# Check Traefik pods
microk8s kubectl get pods -n traefik

# Check logs
microk8s kubectl logs -n traefik -l app.kubernetes.io/name=traefik
```

#### 2. Keycloak Not Responding

```bash
# Check Keycloak pods
microk8s kubectl get pods -n keycloak

# Check Keycloak logs
microk8s kubectl logs -n keycloak -l app=keycloak

```

#### 3. JWT Authentication Issues

```bash
# Check Traefik logs for JWT errors
microk8s kubectl logs -n traefik -l app.kubernetes.io/name=traefik | grep -i jwt
```

#### 4. Getting JWT Tokens from Keycloak

To test the API with JWT authentication, obtain a token using the OAuth2 client credentials flow:

```bash
# Set your variables
export VM_IP=$(microk8s kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed 's|https://||' | sed 's|:.*||')
export TRAEFIK_PORT=$(microk8s kubectl get svc -n traefik traefik -o jsonpath='{.spec.ports[0].nodePort}')
export CLIENT_ID="traefik"
export CLIENT_SECRET="traefik_secret"

# Get access token using client credentials
TOKEN=$(curl -s -X POST "http://${VM_IP}:${TRAEFIK_PORT}/keycloak/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}" | \
  jq -r '.access_token')

echo "JWT Token: $TOKEN"

# Test API with JWT token
curl -H "Authorization: Bearer $TOKEN" "http://${VM_IP}:${TRAEFIK_PORT}/weather/"
```

**Alternative: Get token for a specific user**

```bash
# Get token for user authentication flow
TOKEN=$(curl -s -X POST "http://${VM_IP}:${TRAEFIK_PORT}/keycloak/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}&username=traefik&password=topsecretpassword" | \
  jq -r '.access_token')

echo "User JWT Token: $TOKEN"
```

## 🎯 Access URLs

After successful deployment, access your services at:

- **Traefik Dashboard**: `http://${VM_IP}:${TRAEFIK_PORT}/dashboard/`
- **Keycloak Admin Console**: `http://${VM_IP}:${TRAEFIK_PORT}/keycloak/admin/`
- **API Portal**: `http://${VM_IP}:${TRAEFIK_PORT}/portal`
- **Weather API**: `http://${VM_IP}:${TRAEFIK_PORT}/weather/`

### Example URLs (if VM_IP=192.168.64.2, TRAEFIK_PORT=30303)

- **Traefik Dashboard**: `http://192.168.64.2:30303/dashboard/` ✅
- **Keycloak Admin Console**: `http://192.168.64.2:30303/keycloak/admin/` ✅
- **API Portal**: `http://192.168.64.2:30303/portal`
- **Weather API**: `http://192.168.64.2:30303/weather/` ✅

## 🔑 Default Credentials

### Keycloak Admin
- **Username**: `admin`
- **Password**: `admin`

### OAuth2 Client
- **Client ID**: `traefik`
- **Client Secret**: `traefik_secret`

### Test User
- **Username**: `traefik`
- **Password**: `topsecretpassword`

## 🧹 Cleanup

To remove the entire deployment:

```bash
# Delete applications
microk8s kubectl delete namespace apps

# Delete Keycloak
microk8s kubectl delete namespace keycloak

# Uninstall Traefik
microk8s helm3 uninstall traefik -n traefik

# Uninstall Redis
microk8s helm3 uninstall redis -n traefik

# Delete Traefik namespace
microk8s kubectl delete namespace traefik

# Stop and uninstall MicroK8s
microk8s stop
microk8s uninstall
```

## 📚 Additional Resources

- [MicroK8s Documentation](https://microk8s.io/docs)
- [Traefik Hub Documentation](https://doc.traefik.io/traefik-hub/)
- [Keycloak Documentation](https://www.keycloak.org/documentation)
- [Kubernetes Documentation](https://kubernetes.io/docs/)