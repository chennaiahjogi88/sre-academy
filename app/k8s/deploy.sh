#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
APP_NS="sre-platform"
MON_NS="monitoring"

echo "==> Checking minikube status..."
if ! minikube status --format='{{.Host}}' 2>/dev/null | grep -q "Running"; then
  echo "    Starting minikube..."
  minikube start --driver=docker --memory=6144 --cpus=3
else
  echo "    Minikube already running."
fi

echo "==> Enabling ingress addon..."
minikube addons enable ingress

echo "==> Patching ingress-nginx-controller service to LoadBalancer..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=90s
kubectl patch svc ingress-nginx-controller -n ingress-nginx --type='json' \
  -p='[{"op": "replace", "path": "/spec/type", "value": "LoadBalancer"}]'

# echo "==> Pointing Docker to minikube's daemon..."
# eval "$(minikube docker-env)"

echo "==> Building Docker images..."
docker build -t kotidevops/kt-backend:v2 "$APP_DIR/backend"
docker build -t kotidevops/kt-frontend:v1 "$APP_DIR/frontend"

# ── Application namespace ────────────────────────────────────────────────────
echo ""
echo "==> Deploying application stack (namespace: $APP_NS)..."
kubectl apply -f "$SCRIPT_DIR/namespace.yaml"
kubectl apply -f "$SCRIPT_DIR/configmap.yaml"
kubectl apply -f "$SCRIPT_DIR/postgres.yaml"
kubectl apply -f "$SCRIPT_DIR/backend.yaml"
kubectl apply -f "$SCRIPT_DIR/frontend.yaml"
kubectl apply -f "$SCRIPT_DIR/locust/locust.yaml"

# ── Monitoring namespace ─────────────────────────────────────────────────────
echo ""
echo "==> Deploying monitoring stack (namespace: $MON_NS)..."
kubectl apply -f "$SCRIPT_DIR/monitoring/namespace.yaml"
kubectl apply -f "$SCRIPT_DIR/monitoring/rbac.yaml"
kubectl apply -f "$SCRIPT_DIR/monitoring/loki.yaml"
kubectl apply -f "$SCRIPT_DIR/monitoring/promtail.yaml"
kubectl apply -f "$SCRIPT_DIR/monitoring/jaeger.yaml"
kubectl apply -f "$SCRIPT_DIR/monitoring/prometheus.yaml"
kubectl apply -f "$SCRIPT_DIR/monitoring/grafana.yaml"

# ── Wait for critical services ───────────────────────────────────────────────
echo ""
echo "==> Waiting for Postgres..."
kubectl rollout status statefulset/postgres -n "$APP_NS" --timeout=120s

echo "==> Waiting for backend..."
kubectl rollout status deployment/sre-backend -n "$APP_NS" --timeout=120s

echo "==> Waiting for frontend..."
kubectl rollout status deployment/sre-frontend -n "$APP_NS" --timeout=120s

echo "==> Waiting for Prometheus..."
kubectl rollout status deployment/prometheus -n "$MON_NS" --timeout=120s

echo "==> Waiting for Grafana..."
kubectl rollout status deployment/grafana -n "$MON_NS" --timeout=120s

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              Stack is up — access guide                     ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Add to /etc/hosts (run once):                              ║"
echo "║    echo \"\$(minikube ip) sre.ktech.local\" | sudo tee -a /etc/hosts"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Port-forwards:                                             ║"
echo "║    kubectl port-forward svc/frontend-service  8080:80    -n $APP_NS"
echo "║    kubectl port-forward svc/backend-service   3001:3001  -n $APP_NS"
echo "║    kubectl port-forward svc/locust-master-service 8089:8089 -n $APP_NS"
echo "║    kubectl port-forward svc/prometheus-service 9090:9090 -n $MON_NS"
echo "║    kubectl port-forward svc/grafana-service   3000:3000  -n $MON_NS"
echo "║    kubectl port-forward svc/loki-service      3100:3100  -n $MON_NS"
echo "║    kubectl port-forward svc/jaeger-service    16686:16686 -n $MON_NS"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Credentials:                                               ║"
echo "║    Grafana:  admin / Grafana@123                            ║"
echo "║    App:      student@ktech.sre / Student@123                ║"
echo "║    Admin:    admin@ktech.sre / Admin@123                    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
