#!/bin/bash

set -e

# Create namespace
microk8s kubectl create namespace keycloak --dry-run=client -o yaml | microk8s kubectl apply -f -

# Deploy PostgreSQL
microk8s kubectl apply -f postgres-deployment.yaml
microk8s kubectl apply -f postgres-service.yaml

# Wait for PostgreSQL to be ready
microk8s kubectl wait --for=condition=ready pod -l app=keycloak-postgres -n keycloak --timeout=300s

# Deploy Keycloak
microk8s kubectl apply -f keycloak-deployment.yaml
microk8s kubectl apply -f keycloak-service.yaml

# Wait for Keycloak to be ready
microk8s kubectl wait --for=condition=ready pod -l app=keycloak -n keycloak --timeout=300s

# Wait for Traefik CRDs then deploy IngressRoute
sleep 10
microk8s kubectl apply -f keycloak-ingressroute.yaml

echo "🔑 Configuring Keycloak client and user..."

# Wait for Keycloak to be fully ready
sleep 30

# Get VM IP and port for redirect URLs
VM_IP=$(microk8s kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed 's|https://||' | sed 's|:.*||')
TRAEFIK_PORT=$(microk8s kubectl get svc -n traefik traefik -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "")

if [ -n "$TRAEFIK_PORT" ]; then
    BASE_URL="http://${VM_IP}:${TRAEFIK_PORT}"
    
    # Get admin access token using external URL
    ADMIN_TOKEN=$(curl -s "${BASE_URL}/keycloak/realms/master/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=password&client_id=admin-cli&username=admin&password=admin" \
        --max-time 10 | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])" 2>/dev/null || echo "")
    
    if [ -n "$ADMIN_TOKEN" ]; then
        # Create traefik client
        echo "Creating Keycloak client 'traefik'..."
        curl -s "${BASE_URL}/keycloak/admin/realms/master/clients" \
            -H "Authorization: Bearer $ADMIN_TOKEN" \
            -H "Content-Type: application/json" \
            --max-time 10 \
            -d "{
                \"clientId\": \"traefik\",
                \"secret\": \"traefik_secret\",
                \"enabled\": true,
                \"directAccessGrantsEnabled\": true,
                \"serviceAccountsEnabled\": true,
                \"redirectUris\": [\"${BASE_URL}/callback\", \"${BASE_URL}/portal/*\"],
                \"webOrigins\": [\"${BASE_URL}\"],
                \"attributes\": {
                    \"access.token.lifespan\": \"300\"
                }
            }" > /dev/null 2>&1 && echo "✅ Client 'traefik' created successfully" || echo "⚠️  Client creation failed or may already exist"
        
        # Create traefik user
        echo "Creating user 'traefik@example.com'..."
        curl -s "${BASE_URL}/keycloak/admin/realms/master/users" \
            -H "Authorization: Bearer $ADMIN_TOKEN" \
            -H "Content-Type: application/json" \
            --max-time 10 \
            -d "{
                \"username\": \"traefik\",
                \"email\": \"traefik@example.com\",
                \"emailVerified\": true,
                \"enabled\": true,
                \"credentials\": [{
                    \"type\": \"password\",
                    \"value\": \"topsecretpassword\",
                    \"temporary\": false
                }]
            }" > /dev/null 2>&1 && echo "✅ User 'traefik@example.com' created successfully" || echo "⚠️  User creation failed or may already exist"
    else
        echo "⚠️  Could not get admin token, please create client and user manually"
    fi
else
    echo "⚠️  Traefik not found, please create client and user manually after Traefik deployment"
fi

echo "📱 Keycloak deployment completed!"
echo "🌐 Access Keycloak Admin Console: http://${VM_IP}:${TRAEFIK_PORT}/keycloak/admin/ (when Traefik is deployed)"
echo "👤 Admin - Username: admin, Password: admin"
echo "👤 Test User - Username: traefik, Email: traefik@example.com, Password: topsecretpassword"