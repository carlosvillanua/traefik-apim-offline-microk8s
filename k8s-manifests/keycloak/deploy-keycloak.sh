#!/bin/bash

set -e

echo "🚀 Deploying Keycloak to k3d cluster (dev-file database)..."

# Get host IP for external access
HOST_IP=${HOST_IP:-$(ifconfig | grep "inet " | grep -v 127.0.0.1 | head -1 | awk '{print $2}')}

# Deploy Keycloak (no PostgreSQL needed - using dev-file)
kubectl apply -f keycloak-k3d-deployment.yaml

echo "⏳ Waiting for Keycloak to be ready..."
kubectl wait --for=condition=ready pod -l app=keycloak --timeout=300s

echo "🔑 Configuring Keycloak client and user..."

# Wait for Keycloak to be fully ready
sleep 30

# Base URL for k3d cluster
BASE_URL="http://${HOST_IP}:8090"

# Get admin access token using external URL
ADMIN_TOKEN=$(curl -s "${BASE_URL}/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=password&client_id=admin-cli&username=admin&password=admin123" \
    --max-time 15 | grep -o '"access_token":"[^"]*' | cut -d'"' -f4 2>/dev/null || echo "")

if [ -n "$ADMIN_TOKEN" ]; then
    # Create traefik client
    echo "Creating Keycloak client 'traefik'..."
    curl -s "${BASE_URL}/admin/realms/master/clients" \
        -H "Authorization: Bearer $ADMIN_TOKEN" \
        -H "Content-Type: application/json" \
        --max-time 10 \
        -d "{
            \"clientId\": \"traefik\",
            \"secret\": \"traefik_secret\",
            \"enabled\": true,
            \"directAccessGrantsEnabled\": true,
            \"serviceAccountsEnabled\": true,
            \"redirectUris\": [\"${BASE_URL}/callback\", \"${BASE_URL}/portal/*\", \"http://${HOST_IP}/*\"],
            \"webOrigins\": [\"${BASE_URL}\", \"http://${HOST_IP}\"],
            \"attributes\": {
                \"access.token.lifespan\": \"300\"
            }
        }" > /dev/null 2>&1 && echo "✅ Client 'traefik' created successfully" || echo "⚠️  Client creation failed or may already exist"
    
    # Create traefik user and capture ID
    echo "Creating user 'traefik@example.com'..."
    HTTP_STATUS=$(curl -s -w "%{http_code}" -o /dev/null "${BASE_URL}/admin/realms/master/users" \
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
        }")

    if [ "$HTTP_STATUS" -eq 201 ] || [ "$HTTP_STATUS" -eq 409 ]; then
        # Get user ID
        TRAEFIK_USER_ID=$(curl -s "${BASE_URL}/admin/realms/master/users?username=traefik" \
            -H "Authorization: Bearer $ADMIN_TOKEN" \
            | grep -o '"id":"[^"]*' | head -1 | cut -d'"' -f4 2>/dev/null)
        
        if [ -n "$TRAEFIK_USER_ID" ]; then
            echo "✅ User 'traefik@example.com' ready with ID: $TRAEFIK_USER_ID"
            
            # Export user ID for APIM deployment
            export TRAEFIK_USER_ID
            echo "export TRAEFIK_USER_ID=$TRAEFIK_USER_ID" > ../../traefik_apim_offline/.keycloak_vars
            echo "🔄 Exported TRAEFIK_USER_ID variable for APIM deployment"
            echo "🎯 Variable saved: TRAEFIK_USER_ID=$TRAEFIK_USER_ID"
        else
            echo "⚠️ Could not retrieve user ID for traefik@example.com"
        fi
    else
        echo "⚠️ User creation failed with HTTP status: $HTTP_STATUS"
    fi
else
    echo "⚠️  Could not get admin token, please create client and user manually"
fi

echo "📱 Keycloak deployment completed!"
echo "🌐 Access Keycloak Admin Console: http://${HOST_IP}:8090/admin/"
echo "🌐 Direct access: http://localhost:8090/admin/"
echo "👤 Admin - Username: admin, Password: admin123"
echo "👤 Test User - Username: traefik, Email: traefik@example.com, Password: topsecretpassword"