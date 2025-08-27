#!/bin/bash

set -e  # Exit on any error

echo "🚀 Starting Keycloak deployment for MicroK8s..."

# Check prerequisites
command -v microk8s >/dev/null 2>&1 || { echo "❌ microk8s is required but not installed. Aborting." >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "❌ curl is required but not installed. Aborting." >&2; exit 1; }

# Check if microk8s is running
if ! microk8s status --wait-ready --timeout 30; then
    echo "❌ MicroK8s is not running or ready. Please start it with: microk8s start"
    exit 1
fi

# Check and enable networking addon if needed
echo "🔍 Checking networking configuration..."
if ! microk8s status | grep -q "kube-ovn.*enabled"; then
    echo "🌐 Enabling kube-ovn networking addon..."
    microk8s enable kube-ovn
    echo "⏳ Waiting for kube-ovn to be ready..."
    if ! microk8s kubectl wait --for=condition=ready pod -l app=kube-ovn-cni -n kube-ovn --timeout=300s; then
        echo "❌ kube-ovn failed to start. Check with: microk8s kubectl get pods -n kube-ovn"
        exit 1
    fi
    echo "✅ Networking addon ready"
else
    echo "✅ Networking addon already enabled"
fi

# Step 0: Create required namespaces
echo "📦 Creating required namespaces..."
microk8s kubectl create namespace traefik --dry-run=client -o yaml | microk8s kubectl apply -f -

# Step 1: Deploy PostgreSQL Database
echo "📊 Deploying PostgreSQL database..."
cat <<EOF | microk8s kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak-postgres
  namespace: traefik
spec:
  replicas: 1
  selector:
    matchLabels:
      app: keycloak-postgres
  template:
    metadata:
      labels:
        app: keycloak-postgres
    spec:
      containers:
      - name: postgres
        image: postgres:15
        env:
        - name: POSTGRES_DB
          value: "keycloak-db"
        - name: POSTGRES_USER
          value: "postgres"
        - name: POSTGRES_PASSWORD
          value: "topsecretpassword"
        ports:
        - containerPort: 5432
        volumeMounts:
        - name: postgres-storage
          mountPath: /var/lib/postgresql/data
      volumes:
      - name: postgres-storage
        emptyDir: {}

---

apiVersion: v1
kind: Service
metadata:
  name: keycloak-postgres-postgresql
  namespace: traefik
spec:
  selector:
    app: keycloak-postgres
  ports:
  - port: 5432
    targetPort: 5432
EOF

echo "⏳ Waiting for PostgreSQL to be ready..."
if ! microk8s kubectl wait --for=condition=ready pod -l app=keycloak-postgres -n traefik --timeout=300s; then
    echo "❌ PostgreSQL failed to start. Check logs with: microk8s kubectl logs -n traefik -l app=keycloak-postgres"
    exit 1
fi

# Step 2: Install Keycloak Operator
echo "🔧 Installing Keycloak operator..."
microk8s kubectl create namespace keycloak --dry-run=client -o yaml | microk8s kubectl apply -f -

microk8s kubectl create rolebinding keycloak-operator-traefik-access \
  --clusterrole=edit \
  --serviceaccount=keycloak:keycloak-operator \
  --namespace=traefik --dry-run=client -o yaml | microk8s kubectl apply -f -

microk8s kubectl apply -f keycloak-operator/keycloaks.k8s.keycloak.org-v1.yml
microk8s kubectl apply -f keycloak-operator/keycloakrealmimports.k8s.keycloak.org-v1.yml
microk8s kubectl apply -f keycloak-operator/kubernetes.yml -n keycloak

echo "⏳ Waiting for Keycloak operator to be ready..."
if ! microk8s kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=keycloak-operator -n keycloak --timeout=300s; then
    echo "❌ Keycloak operator failed to start. Check logs with: microk8s kubectl logs -n keycloak -l app.kubernetes.io/name=keycloak-operator"
    exit 1
fi

# Step 3: Deploy Database Secret (to keycloak namespace where Keycloak instance will run)
echo "🔐 Deploying database secret..."
microk8s kubectl create secret generic keycloak-db-secret -n keycloak --from-literal=username=postgres --from-literal=password=topsecretpassword --dry-run=client -o yaml | microk8s kubectl apply -f -

# Step 4: Deploy Keycloak Instance (move to keycloak namespace where operator can see it)
echo "🔑 Deploying Keycloak instance..."
(echo "apiVersion: k8s.keycloak.org/v2alpha1
kind: Keycloak
metadata:
  name: keycloak
  namespace: keycloak"; cat main/keycloak.yaml | tail -n +5) | microk8s kubectl apply -f -

echo "⏳ Waiting for Keycloak to be ready..."
if ! microk8s kubectl wait --for=condition=ready pod -l app=keycloak -n keycloak --timeout=600s; then
    echo "❌ Keycloak failed to start. Check logs with: microk8s kubectl logs -n keycloak -l app=keycloak"
    echo "💡 Check if database secret exists: microk8s kubectl get secret keycloak-db-secret -n keycloak"
    exit 1
fi

# Step 5: Deploy Keycloak Realm Configuration (move to keycloak namespace where operator can see it)
echo "👥 Importing Keycloak realm configuration..."
(echo "apiVersion: k8s.keycloak.org/v2alpha1
kind: KeycloakRealmImport
metadata:
  name: keycloak-oauth
  namespace: keycloak"; cat main/keycloak-realm.yaml | tail -n +5) | microk8s kubectl apply -f -

echo "⏳ Waiting for realm import to complete..."
sleep 30

# Step 6: Add Traefik OAuth2 Client
echo "🔧 Adding Traefik OAuth2 client to Keycloak..."

# Wait for admin secret to be available
echo "⏳ Waiting for admin credentials to be ready..."
SECRET_READY=false
for i in {1..30}; do
  if microk8s kubectl get secret keycloak-initial-admin -n keycloak >/dev/null 2>&1; then
    SECRET_READY=true
    break
  fi
  sleep 2
done

if [ "$SECRET_READY" = false ]; then
  echo "⚠️  Admin secret not ready after 60 seconds, skipping Traefik client creation"
  echo "✅ Keycloak deployment completed (without Traefik client)"
  echo ""
  echo "📋 Verification commands:"
  echo "  microk8s kubectl get pods -n keycloak -l app=keycloak"
  echo "  microk8s kubectl get keycloak -n keycloak" 
  echo "  microk8s kubectl get keycloakrealmimport -n keycloak"
  echo ""
  echo "🔗 Access Keycloak:"
  echo "  microk8s kubectl port-forward svc/keycloak-service -n keycloak 9091:7000"
  exit 0
fi

# Get admin credentials
ADMIN_USER=$(microk8s kubectl get secret keycloak-initial-admin -n keycloak -o jsonpath='{.data.username}' | base64 -d 2>/dev/null)
ADMIN_PASS=$(microk8s kubectl get secret keycloak-initial-admin -n keycloak -o jsonpath='{.data.password}' | base64 -d 2>/dev/null)

# Start port forwarding in background
microk8s kubectl port-forward svc/keycloak-service -n keycloak 9091:7000 >/dev/null 2>&1 &
PF_PID=$!

# Set trap to cleanup port forward on script exit
trap "kill $PF_PID 2>/dev/null || true" EXIT

sleep 5

# Get admin access token
echo "🔐 Getting admin access token..."
TOKEN_RESPONSE=$(curl -s -X POST \
  "http://localhost:9091/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&client_id=admin-cli&username=${ADMIN_USER}&password=${ADMIN_PASS}" 2>/dev/null)

# Extract access_token from JSON response using grep and sed
ADMIN_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -o '"access_token":"[^"]*"' | sed 's/"access_token":"//g' | sed 's/"//g')

if [ "$ADMIN_TOKEN" = "null" ] || [ -z "$ADMIN_TOKEN" ]; then
  echo "⚠️  Could not get admin token, skipping Traefik client creation"
  kill $PF_PID 2>/dev/null
else
  echo "✅ Got admin token"
  
  # Create Traefik client
  echo "🚀 Creating Traefik client..."
  CLIENT_RESPONSE=$(curl -s -X POST \
    "http://localhost:9091/admin/realms/keycloak-oauth/clients" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{
      "clientId": "traefik",
      "name": "traefik", 
      "description": "Traefik OAuth2/OIDC Client for authentication flows",
      "enabled": true,
      "clientAuthenticatorType": "client-secret",
      "secret": "traefik_secret",
      "redirectUris": [],
      "webOrigins": [],
      "bearerOnly": false,
      "consentRequired": false,
      "standardFlowEnabled": false,
      "implicitFlowEnabled": false,
      "directAccessGrantsEnabled": false,
      "serviceAccountsEnabled": true,
      "publicClient": false,
      "frontchannelLogout": false,
      "protocol": "openid-connect",
      "fullScopeAllowed": true,
      "defaultClientScopes": ["web-origins", "acr", "profile", "roles", "email"],
      "optionalClientScopes": ["address", "phone", "offline_access", "microprofile-jwt"]
    }' 2>/dev/null)

  # Test the client credentials flow
  echo "🧪 Testing client_credentials flow..."
  sleep 2
  TOKEN_RESPONSE_TEST=$(curl -s -X POST \
    "http://localhost:9091/realms/keycloak-oauth/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials&client_id=traefik&client_secret=traefik_secret" 2>/dev/null)
  
  # Extract access_token from JSON response using grep and sed
  TOKEN_TEST=$(echo "$TOKEN_RESPONSE_TEST" | grep -o '"access_token":"[^"]*"' | sed 's/"access_token":"//g' | sed 's/"//g')

  if [[ "$CLIENT_RESPONSE" == *"already exists"* ]]; then
    echo "ℹ️  Traefik client already exists, testing..."
  fi

  if [ "$TOKEN_TEST" = "null" ] || [ -z "$TOKEN_TEST" ]; then
    echo "⚠️  Traefik client test failed"
  else
    echo "✅ Traefik client ready and tested successfully!"
  fi

  # Clean up port forward
  kill $PF_PID 2>/dev/null
fi

echo "✅ Keycloak deployment completed!"
echo ""
echo "📋 Verification commands:"
echo "  microk8s kubectl get pods -n keycloak -l app=keycloak"
echo "  microk8s kubectl get keycloak -n keycloak" 
echo "  microk8s kubectl get keycloakrealmimport -n keycloak"
echo ""
echo "🔗 Access Keycloak:"
echo "  microk8s kubectl port-forward svc/keycloak-service -n keycloak 9091:7000"
echo ""
echo "👤 Default credentials:"
echo "  To get admin credentials run:"
echo "    microk8s kubectl get secret keycloak-initial-admin -n keycloak -o jsonpath='{.data.username}' | base64 -d && echo"
echo "    microk8s kubectl get secret keycloak-initial-admin -n keycloak -o jsonpath='{.data.password}' | base64 -d && echo"
echo "  Realm users (from keycloak-oauth realm):"
echo "    admin / topsecretpassword"
echo "    developer / topsecretpassword"
echo ""
echo "🔧 OAuth2/OIDC Client for Traefik:"
echo "  Client ID: traefik"
echo "  Client Secret: traefik_secret"
echo "  Grant Type: client_credentials (service account enabled)"
echo "  Token Endpoint: http://localhost:9091/realms/keycloak-oauth/protocol/openid-connect/token"
echo ""
echo "🧪 Test the client_credentials flow:"
echo "  curl -X POST \"http://localhost:9091/realms/keycloak-oauth/protocol/openid-connect/token\" \\"
echo "    -H \"Content-Type: application/x-www-form-urlencoded\" \\"
echo "    -d \"grant_type=client_credentials&client_id=traefik&client_secret=traefik_secret\" | grep access_token"