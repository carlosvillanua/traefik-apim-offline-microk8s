# Delete applications
microk8s kubectl delete namespace apps

# Uninstall Traefik
microk8s helm3 uninstall traefik -n traefik

# Delete Traefik namespace
microk8s kubectl delete namespace traefik

# Stop and uninstall MicroK8s
microk8s stop
microk8s uninstall