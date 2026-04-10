#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
NAMESPACE="sre-platform"

echo "==> Checking minikube status..."
if ! minikube status --format='{{.Host}}' 2>/dev/null | grep -q "Running"; then
  echo "    Starting minikube..."
  minikube start --driver=docker --memory=4096 --cpus=2
else
  echo "    Minikube already running."
fi

echo "==> Enabling ingress addon..."
minikube addons enable ingress

# echo "==> Pointing Docker to minikube's daemon..."
# eval "$(minikube docker-env)"

# echo "==> Building Docker images..."
# docker build -t sre-backend:latest "$APP_DIR/backend"
# docker build -t sre-frontend:latest "$APP_DIR/frontend"

echo "==> Applying manifests..."
kubectl apply -f "$SCRIPT_DIR/namespace.yaml"
kubectl apply -f "$SCRIPT_DIR/configmap.yaml"
kubectl apply -f "$SCRIPT_DIR/postgres.yaml"
kubectl apply -f "$SCRIPT_DIR/prometheus.yaml"
kubectl apply -f "$SCRIPT_DIR/grafana.yaml"
kubectl apply -f "$SCRIPT_DIR/backend.yaml"
kubectl apply -f "$SCRIPT_DIR/frontend.yaml"

echo "==> Waiting for Postgres to be ready..."
kubectl rollout status statefulset/postgres -n "$NAMESPACE" --timeout=120s

echo "==> Waiting for backend to be ready..."
kubectl rollout status deployment/sre-backend -n "$NAMESPACE" --timeout=120s

echo "==> Waiting for frontend to be ready..."
kubectl rollout status deployment/sre-frontend -n "$NAMESPACE" --timeout=120s

echo ""
echo "==> Stack is up. Useful commands:"
echo ""
echo "    Add to /etc/hosts (run once):"
echo "      echo \"\$(minikube ip) sre.ktech.local\" | sudo tee -a /etc/hosts"
echo ""
echo "    Port-forwards:"
echo "      kubectl port-forward svc/frontend-service   8080:80    -n $NAMESPACE"
echo "      kubectl port-forward svc/backend-service    3001:3001  -n $NAMESPACE"
echo "      kubectl port-forward svc/grafana-service    3000:3000  -n $NAMESPACE"
echo "      kubectl port-forward svc/prometheus-service 9090:9090  -n $NAMESPACE"
echo ""
echo "    Or open via minikube tunnel (runs in foreground):"
echo "      minikube tunnel"
echo ""
echo "    App URL (after /etc/hosts entry): http://sre.ktech.local"
echo "    Grafana: admin / Grafana@123"
