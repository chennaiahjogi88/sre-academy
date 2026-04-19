#!/usr/bin/env bash
set -euo pipefail

# ── Argument parsing ─────────────────────────────────────────────────────────
PUSH_IMAGES=false          # --push  : build multi-arch and push to Docker Hub
MULTI_ARCH=false           # --multi-arch : build linux/amd64 + linux/arm64 locally

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -g|--global)     ;;
        --push)          PUSH_IMAGES=true;  MULTI_ARCH=true ;;
        --multi-arch)    MULTI_ARCH=true ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
APP_NS="sre-platform"
MON_NS="monitoring"
ROLLOUT_TIMEOUT="300s"

# ── Detect host OS and architecture ─────────────────────────────────────────
HOST_OS=$(uname -s)
HOST_ARCH=$(uname -m)
case "$HOST_ARCH" in
    x86_64)        NATIVE_PLATFORM="linux/amd64" ;;
    arm64|aarch64) NATIVE_PLATFORM="linux/arm64" ;;
    *)             echo "    Unknown arch '$HOST_ARCH', defaulting to linux/amd64"
                   NATIVE_PLATFORM="linux/amd64" ;;
esac
echo "==> Host: $HOST_OS / $HOST_ARCH  (native platform: $NATIVE_PLATFORM)"

echo "==> Checking minikube status..."
if ! minikube status --format='{{.Host}}' 2>/dev/null | grep -q "Running"; then
  echo "    Starting minikube..."
  minikube start --driver=docker --memory=6144 --cpus=3
else
  echo "    Minikube already running."
fi

echo "==> Enabling ingress addon..."
minikube addons enable ingress

ensure_buildx_builder() {
  local builder_name="multi-builder"
  if ! docker buildx inspect "$builder_name" >/dev/null 2>&1; then
    echo "==> Creating docker buildx builder '$builder_name'..."
    docker buildx create --name "$builder_name" --driver docker-container --use >/dev/null
  else
    docker buildx use "$builder_name"
  fi
  docker buildx inspect --bootstrap "$builder_name" >/dev/null
}

# ── Build Docker images ──────────────────────────────────────────────────────
if [[ "$PUSH_IMAGES" == "true" ]]; then
  # Multi-arch build + push to Docker Hub (requires `docker buildx` + logged-in account)
  ensure_buildx_builder
  echo "==> Building & pushing multi-arch images (linux/amd64 + linux/arm64)..."
  docker buildx build \
    --builder multi-builder \
    --platform linux/amd64,linux/arm64 \
    --push \
    -t kotidevops/kt-backend:v6 "$APP_DIR/backend"
  docker buildx build \
    --builder multi-builder \
    --platform linux/amd64,linux/arm64 \
    --push \
    -t kotidevops/kt-frontend:v6 "$APP_DIR/frontend"
  echo "    Images pushed. Skipping minikube docker-env (using registry images)."
else
echo "==> Pointing Docker to minikube's daemon..."
# Pointing Docker to minikube's daemon
eval "$(minikube docker-env --shell bash)"

  if [[ "$MULTI_ARCH" == "true" ]]; then
    ensure_buildx_builder
    echo "==> Building multi-arch images for minikube (linux/amd64 + linux/arm64)..."
    docker buildx build --load \
      --platform linux/amd64,linux/arm64 \
      -t kotidevops/kt-backend:v6 "$APP_DIR/backend"
    docker buildx build --load \
      --platform linux/amd64,linux/arm64 \
      -t kotidevops/kt-frontend:v6 "$APP_DIR/frontend"
  else
    echo "==> Building Docker images (platform: $NATIVE_PLATFORM)..."
    docker build --platform "$NATIVE_PLATFORM" \
      -t kotidevops/kt-backend:v6  "$APP_DIR/backend"
    docker build --platform "$NATIVE_PLATFORM" \
      -t kotidevops/kt-frontend:v6 "$APP_DIR/frontend"
  fi
fi

# ── Application namespace ────────────────────────────────────────────────────
echo ""
echo "==> Deploying application stack (namespace: $APP_NS)..."
kubectl apply -f "$SCRIPT_DIR/namespace.yaml"
kubectl apply -f "$SCRIPT_DIR/storageclass-minikube.yaml"
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

# ── Ingress resources ──────────────────────────────────────────────────────
echo ""
echo "==> Applying Ingress resources..."
kubectl apply -f "$SCRIPT_DIR/ingress-minikube.yaml"
kubectl apply -f "$SCRIPT_DIR/monitoring/ingress.yaml"

# ── Wait for critical services ───────────────────────────────────────────────
echo ""
echo "==> Waiting for Postgres..."
kubectl rollout status statefulset/postgres -n "$APP_NS" --timeout="$ROLLOUT_TIMEOUT"

echo "==> Waiting for backend..."
kubectl rollout status deployment/sre-backend -n "$APP_NS" --timeout="$ROLLOUT_TIMEOUT"

echo "==> Waiting for frontend..."
kubectl rollout status deployment/sre-frontend -n "$APP_NS" --timeout="$ROLLOUT_TIMEOUT"

echo "==> Waiting for Prometheus..."
kubectl rollout status deployment/prometheus -n "$MON_NS" --timeout="$ROLLOUT_TIMEOUT"

echo "==> Waiting for Grafana..."
kubectl rollout status deployment/grafana -n "$MON_NS" --timeout="$ROLLOUT_TIMEOUT"

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
