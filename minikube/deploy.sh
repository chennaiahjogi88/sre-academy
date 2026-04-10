#!/bin/bash
# ============================================================
# KTech SRE Academy — Minikube Lab Deploy Script
# ============================================================
set -e

NAMESPACE="ktech-demo"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "======================================================"
echo "  KTech SRE Academy — Kubernetes Lab Deployment"
echo "======================================================"

# ---- Pre-flight checks ----
echo ""
echo "[1/6] Checking prerequisites..."
command -v kubectl &>/dev/null || { echo "ERROR: kubectl not found"; exit 1; }
command -v minikube &>/dev/null || { echo "ERROR: minikube not found"; exit 1; }

minikube status | grep -q "Running" || { echo "ERROR: minikube is not running. Run: minikube start"; exit 1; }
echo "  minikube is running"

# ---- Enable required addons ----
echo ""
echo "[2/6] Enabling minikube addons..."
minikube addons enable ingress 2>/dev/null && echo "  ingress addon enabled" || echo "  ingress already enabled"
minikube addons enable metrics-server 2>/dev/null && echo "  metrics-server addon enabled" || echo "  metrics-server already enabled"

# ---- Apply manifests in order ----
echo ""
echo "[3/6] Applying Kubernetes manifests..."

MANIFESTS=(
  "00-namespace.yaml"
  "01-rbac.yaml"
  "02-config.yaml"
  "03-storage.yaml"
  "04-database.yaml"
  "05-cache.yaml"
  "06-app.yaml"
  "07-daemonset.yaml"
  "08-jobs.yaml"
  "09-ingress.yaml"
  "10-hpa.yaml"
  "11-networkpolicy.yaml"
  "12-pdb.yaml"
)

for manifest in "${MANIFESTS[@]}"; do
  echo "  Applying $manifest..."
  kubectl apply -f "$DIR/$manifest"
done

# ---- Wait for deployments ----
echo ""
echo "[4/6] Waiting for workloads to be ready..."
echo "  Waiting for postgres StatefulSet..."
kubectl rollout status statefulset/postgres -n $NAMESPACE --timeout=120s

echo "  Waiting for redis Deployment..."
kubectl rollout status deployment/redis -n $NAMESPACE --timeout=60s

echo "  Waiting for demo-app Deployment..."
kubectl rollout status deployment/demo-app -n $NAMESPACE --timeout=120s

# ---- Setup /etc/hosts ----
echo ""
echo "[5/6] Setting up local DNS..."
MINIKUBE_IP=$(minikube ip)
echo "  Minikube IP: $MINIKUBE_IP"

if ! grep -q "demo.ktech.local" /etc/hosts; then
  echo "  Adding entries to /etc/hosts (requires sudo)..."
  echo "$MINIKUBE_IP  demo.ktech.local metrics.ktech.local" | sudo tee -a /etc/hosts
else
  echo "  /etc/hosts already configured"
fi

# ---- Print summary ----
echo ""
echo "[6/6] Deployment complete! Summary:"
echo "======================================================"
echo ""
echo "Namespace: $NAMESPACE"
echo ""

kubectl get all -n $NAMESPACE

echo ""
echo "======================================================"
echo "Access points:"
echo ""
echo "  NodePort (direct):   $(minikube service demo-app-service -n $NAMESPACE --url 2>/dev/null || echo 'run: minikube service demo-app-service -n ktech-demo --url')"
echo "  Ingress (hostname):  http://demo.ktech.local"
echo "  Node Exporter:       http://metrics.ktech.local"
echo ""
echo "Useful commands:"
echo "  kubectl get all -n $NAMESPACE"
echo "  kubectl get pvc -n $NAMESPACE"
echo "  kubectl get hpa -n $NAMESPACE"
echo "  kubectl describe pdb -n $NAMESPACE"
echo "  kubectl logs -l app=demo-app -n $NAMESPACE"
echo "  kubectl exec -it \$(kubectl get pod -l app=postgres -n $NAMESPACE -o name | head -1) -n $NAMESPACE -- psql -U demouser -d demodb"
echo ""
echo "  # Watch HPA scaling:"
echo "  kubectl get hpa -n $NAMESPACE -w"
echo ""
echo "  # Generate load to trigger HPA:"
echo "  kubectl run load-gen --image=busybox --rm -it -n $NAMESPACE \\"
echo "    -- /bin/sh -c 'while true; do wget -q -O- http://demo-app-service/; done'"
echo "======================================================"
