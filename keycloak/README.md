# Keycloak Deployment Guide

This guide provides step-by-step instructions to deploy Keycloak with PostgreSQL database using the Keycloak operator.

## Prerequisites

- Kubernetes cluster running
- `kubectl` command available
- `curl` command available (for API testing)

## Quick Deployment

Run the deployment script from the keycloak directory:

```bash
./deploy.sh
```

This script will:
1. Deploy PostgreSQL database
2. Install Keycloak operator and CRDs
3. Deploy Keycloak instance 
4. Import realm configuration with users and groups
5. **Automatically create Traefik OAuth2 client**
6. Test the client_credentials flow

## Alternative: Step by Step Deployment

### Step 1: Create Namespaces and Deploy PostgreSQL
```bash
# Create required namespaces
kubectl create namespace traefik
kubectl create namespace keycloak

# Deploy PostgreSQL database
cat <<EOF | kubectl apply -f -
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

# Wait for PostgreSQL to be ready
kubectl wait --for=condition=ready pod -l app=keycloak-postgres -n traefik --timeout=300s
```

### Step 2: Install Keycloak Operator
```bash
# Deploy CRDs and Operator
kubectl apply -f keycloak-operator/keycloaks.k8s.keycloak.org-v1.yml
kubectl apply -f keycloak-operator/keycloakrealmimports.k8s.keycloak.org-v1.yml
kubectl apply -f keycloak-operator/kubernetes.yml -n keycloak

# Wait for operator to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=keycloak-operator -n keycloak --timeout=300s
```

### Step 3: Deploy Database Secret
```bash
kubectl create secret generic keycloak-db-secret -n keycloak --from-literal=username=postgres --from-literal=password=topsecretpassword
```

### Step 4: Deploy Keycloak Instance
```bash
(echo "apiVersion: k8s.keycloak.org/v2alpha1
kind: Keycloak
metadata:
  name: keycloak
  namespace: keycloak"; cat main/keycloak.yaml | tail -n +5) | kubectl apply -f -

# Wait for Keycloak to be ready
kubectl wait --for=condition=ready pod -l app=keycloak -n keycloak --timeout=600s
```

### Step 5: Deploy Realm Configuration
```bash
(echo "apiVersion: k8s.keycloak.org/v2alpha1
kind: KeycloakRealmImport
metadata:
  name: keycloak-oauth
  namespace: keycloak"; cat main/keycloak-realm.yaml | tail -n +5) | kubectl apply -f -
```

## Verification Steps

### Check PostgreSQL Status
```bash
kubectl get pods -n traefik -l app=keycloak-postgres
```

### Check Keycloak Operator Status
```bash
kubectl get pods -n keycloak -l app.kubernetes.io/name=keycloak-operator
```

### Check Keycloak Instance Status
```bash
kubectl get keycloak -n keycloak
kubectl get pods -n keycloak -l app=keycloak
```

### Check Realm Import Status
```bash
kubectl get keycloakrealmimport -n keycloak
```

### Access Keycloak
```bash
# Get Keycloak service
kubectl get svc -n keycloak | grep keycloak

# Port forward to access Keycloak
kubectl port-forward svc/keycloak-service -n keycloak 9091:7000
```

**Then access Keycloak at:** `http://localhost:9091`

## Troubleshooting

### View Operator Logs
```bash
kubectl logs -n keycloak -l app.kubernetes.io/name=keycloak-operator -f
```

### View Keycloak Logs
```bash
kubectl logs -n keycloak -l app=keycloak -f
```

### View PostgreSQL Logs
```bash
kubectl logs -n traefik -l app=keycloak-postgres -f
```

### Check Resource Status
```bash
# Check all resources in keycloak namespace
kubectl get all -n keycloak

# Check all resources in traefik namespace (PostgreSQL)
kubectl get all -n traefik

# Check all Keycloak custom resources
kubectl get keycloak,keycloakrealmimport -A
```

### Common Issues

**Keycloak pod not starting:**
- Check if database secret exists: `kubectl get secret keycloak-db-secret -n keycloak`
- Check PostgreSQL connectivity: `kubectl logs -n keycloak keycloak-0`

**Operator not managing resources:**
- Ensure operator is in same namespace as Keycloak CR: `kubectl get pods -n keycloak`
- Check operator logs for errors

**Admin credentials not working:**
- Get fresh credentials: `kubectl get secret keycloak-initial-admin -n keycloak -o yaml`
- Password is auto-generated on each deployment

## Configuration Details

### Default Credentials

**Master Realm Admin (for Keycloak Admin Console):**
- Get current credentials by running:
  ```bash
  kubectl get secret keycloak-initial-admin -n keycloak -o jsonpath='{.data.username}' | base64 -d && echo
  kubectl get secret keycloak-initial-admin -n keycloak -o jsonpath='{.data.password}' | base64 -d && echo
  ```
- Access: `http://localhost:9091/admin` (after port forwarding)

**Realm Users (keycloak-oauth realm):**
- Admin user: `admin` / `topsecretpassword`
- Developer user: `developer` / `topsecretpassword`

**Database:**
- Database password: `topsecretpassword` (base64 encoded in secret)

### OAuth Client Configuration

**Web Client (keycloak-oauth):**
- Client ID: `keycloak-oauth`
- Client Secret: `NoTgoLZpbrr5QvbNDIRIvmZOhe9wI0r0`
- Allowed redirect URIs: `/*`
- Allowed web origins: `/*`
- Grant types: authorization_code, implicit, direct_access

**Service Account Client (traefik):**
- Client ID: `traefik`
- Client Secret: `traefik_secret`
- Grant type: `client_credentials` only
- Service account enabled: Yes
- Token endpoint: `http://localhost:9091/realms/keycloak-oauth/protocol/openid-connect/token`

**Usage example:**
```bash
curl -X POST "http://localhost:9091/realms/keycloak-oauth/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=traefik&client_secret=traefik_secret" | grep access_token
```

### Groups
- `admins` - Administrator group
- `developers` - Developer group

## File Structure

```
keycloak/
├── keycloak-operator/
│   ├── keycloaks.k8s.keycloak.org-v1.yml          # CRD for Keycloak instances
│   ├── keycloakrealmimports.k8s.keycloak.org-v1.yml # CRD for realm imports
│   └── kubernetes.yml                              # Operator deployment
└── main/
    ├── keycloak.yaml                               # Keycloak instance definition
    ├── keycloak-secrets.yaml                      # Database credentials
    └── keycloak-realm.yaml                        # Realm configuration
```

## Architecture

- **Keycloak Operator**: Runs in `keycloak` namespace, manages Keycloak instances
- **PostgreSQL Database**: Runs in `traefik` namespace, stores Keycloak data
- **Keycloak Instance**: Runs in `keycloak` namespace, main authentication server
- **Realm Import**: Runs in `keycloak` namespace, configures the OAuth realm with users, groups, and clients

### Namespace Layout
```
keycloak/          # Operator, Keycloak instance, realm imports, secrets
├── keycloak-operator (pod)
├── keycloak-0 (statefulset pod)
├── keycloak-initial-admin (secret)
├── keycloak-db-secret (secret)
└── keycloak-oauth (realm import)

traefik/           # Database only
└── keycloak-postgres (deployment)
```

## Notes

1. **Cross-namespace setup**: PostgreSQL in `traefik` namespace, everything else in `keycloak` namespace
2. **Ephemeral storage**: PostgreSQL uses `emptyDir` - data will be lost on pod restart
3. **Production considerations**: Configure persistent storage and proper database backup
4. **OAuth/OIDC ready**: Includes comprehensive realm configuration with multiple grant types
5. **Service account client**: Traefik client automatically created for API authentication
6. **Auto-generated secrets**: Admin passwords are generated by the operator on each deployment