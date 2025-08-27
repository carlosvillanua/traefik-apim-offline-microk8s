# MicroK8s with Traefik Installation Guide

This guide contains the working commands for installing MicroK8s with Traefik.

## Installation Steps

### 1. Install MicroK8s

```bash
sudo snap install microk8s --classic --channel=1.32/stable
```

### 2. Enable Community Repository and Traefik

```bash
# Enable community repository first
sudo /snap/bin/microk8s enable community

# Install Redis for APIM rate limiting purposes
microk8s helm3 repo add bitnami https://charts.bitnami.com/bitnami
microk8s helm3 repo update
microk8s enable hostpath-storage
microk8s kubectl create namespace traefik
microk8s helm3 install redis bitnami/redis \
  --namespace traefik \
  --set replica.replicaCount=1 \
  --set persistence.enabled=false

export REDIS_PASSWORD=$(kubectl get secret --namespace traefik redis -o jsonpath="{.data.redis-password}" | base64 -d)

# Get your external IP 

SERVER_IP=hostname -I | awk '{print $1}'


# Install Traefik Hub

microk8s helm repo add --force-update traefik https://traefik.github.io/charts
microk8s kubectl create secret generic traefik-hub-license --namespace traefik --from-literal=token= <GET A TRIAL LICENSE FROM TRAEFIK>

microk8s helm upgrade --install --namespace traefik traefik traefik/traefik \
  --set hub.token=traefik-hub-license \
  --set hub.apimanagement.enabled=true \
  --set ingressRoute.dashboard.enabled=true \
  --set ingressRoute.dashboard.matchRule='Host(`$SERVER_IP`)' \
  --set ingressRoute.dashboard.entryPoints={web} \
  --set "providers.kubernetesCRD.allowExternalNameServices=true" \
  --set "providers.kubernetesCRD.allowCrossNamespace=true" \
  --set hub.redis.endpoints=redis-master.traefik.svc.cluster.local:6379 \
  --set hub.redis.password=${REDIS_PASSWORD} \
  --set image.registry=ghcr.io --set image.repository=traefik/traefik-hub --set image.tag=v3.17.4
```

### 3. Verify Installation

```bash
# Check Traefik service
microk8s kubectl get service -n traefik traefik

# Check Traefik pods
microk8s kubectl get pods -n traefik

#Check when all the pods are running

  while [[ $(microk8s kubectl get pods -n traefik --no-headers | awk '$3 != "Running"' | wc -l) -gt 0 ]]; do echo "Waiting for pods..."; sleep 5; done && echo "All pods running!"

```

## Access Points

First, get your server's IP address and Traefik service ports:

```bash
# Get your server's IP address
hostname -I | awk '{print $1}'

# Get Traefik service ports
microk8s kubectl get service -n traefik traefik
```

Access Traefik using your IP and the NodePort values from the service output:
- **HTTP**: `http://YOUR_IP:HTTP_PORT`
- **Dashboard**: `https://YOUR_IP:HTTPS_PORT`

Example service output:
```
NAME      TYPE           CLUSTER-IP       EXTERNAL-IP   PORT(S)                      AGE
traefik   LoadBalancer   10.152.183.178   <pending>     80:32121/TCP,443:32503/TCP   14m
```

In this example, the ports would be 32121 (HTTP) and 32503 (HTTPS).

Deploy and Test a full APIM Offline

# Get IP address (works on Linux/macOS)
  IP=$(hostname -I 2>/dev/null | awk '{print $1}' || ifconfig | grep 'inet' | grep -v 127.0.0.1 | head -1 | awk '{print $2}' 2>/dev/null || ip route get 1 2>/dev/null | awk '{print $7}')

  # Extract port from any LoadBalancer service with 443 port mapping
  PORT=$(kubectl get svc -A | grep LoadBalancer | grep -o '443:[0-9]*' | head -1 | cut -d: -f2)

  # Create EXTERNAL_IP
  EXTERNAL_IP="$IP:$PORT"
  echo "EXTERNAL_IP=$EXTERNAL_IP"

  
APIM Offline Example 

## Gitea Installation and IngressRoute

### Install Gitea

```bash
# Add Gitea Helm repository
microk8s helm3 repo add gitea-charts https://dl.gitea.io/charts/

# Install Gitea
microk8s helm3 install gitea gitea-charts/gitea -n default
```

### Port Forward (Temporary Access)

```bash
kubectl --namespace default port-forward svc/gitea-http 3000:3000
```

### IngressRoute for Gitea

```bash
cat <<EOF | microk8s kubectl apply -f -
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: gitea-ingressroute
  namespace: traefik
spec:
  entryPoints:
    - websecure
  routes:
    - match: PathPrefix(\`/gitea\`)
      kind: Rule
      services:
        - name: gitea-http
          namespace: default
          port: 3000
      middlewares: 
        - name: stripprefix-admin
          namespace: traefik

---

apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: stripprefix-admin
  namespace: traefik
spec:
  stripPrefix:
    prefixes:
      - /gitea
EOF
``