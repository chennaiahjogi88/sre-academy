#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
APP_NS="sre-platform"
MON_NS="monitoring"
ROLLOUT_TIMEOUT="300s"

usage() {
  echo "Usage: $0 <command> [options]"
  echo ""
  echo "Commands:"
  echo "  deploy     Deploy the full SRE platform stack"
  echo "  teardown   Tear down the SRE platform stack"
  echo ""
  echo "Deploy options:"
  echo "  --build       Build image for native platform into minikube's daemon (skip if no code changes)"
  echo "  --push        Build multi-arch images and push to Docker Hub"
  echo "  --multi-arch  Build linux/amd64 + linux/arm64 into minikube's daemon"
  echo ""
  echo "Teardown options:"
  echo "  --yes, -y   Skip all confirmation prompts"
  exit 0
}

# ── Shared helpers ────────────────────────────────────────────────────────────

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

# ── Deploy ────────────────────────────────────────────────────────────────────

deploy() {
  local BUILD_IMAGES=false
  local PUSH_IMAGES=false
  local MULTI_ARCH=false

  while [[ "$#" -gt 0 ]]; do
    case $1 in
      -g|--global)  ;;
      --build)      BUILD_IMAGES=true ;;
      --push)       PUSH_IMAGES=true; MULTI_ARCH=true ;;
      --multi-arch) BUILD_IMAGES=true; MULTI_ARCH=true ;;
      *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
  done

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

  echo "==> Starting minikube tunnel in background (assigns 127.0.0.1 to LoadBalancer services)..."
  minikube tunnel >/tmp/minikube-tunnel.log 2>&1 &
  TUNNEL_PID=$!
  echo "    Tunnel PID: $TUNNEL_PID  (logs: /tmp/minikube-tunnel.log)"

  echo "==> Waiting for ingress-nginx-controller to get external IP (127.0.0.1)..."
  for i in $(seq 1 30); do
    EXT_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
               -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    [[ "$EXT_IP" == "127.0.0.1" ]] && { echo "    External IP: 127.0.0.1"; break; }
    echo "    ($i/30) waiting for external IP..."; sleep 5
  done

  if [[ "$PUSH_IMAGES" == "true" ]]; then
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
    echo "    Images pushed. Using registry images in minikube."
  elif [[ "$BUILD_IMAGES" == "true" ]]; then
    echo "==> Pointing Docker to minikube's daemon..."
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
  else
    echo "==> Skipping image build — using existing images (kotidevops/kt-backend:v6, kotidevops/kt-frontend:v6)"
    echo "    Pass --build to rebuild locally, or --push to build multi-arch and push."
  fi

  echo ""
  echo "==> Deploying application stack (namespace: $APP_NS)..."
  kubectl apply -f "$SCRIPT_DIR/namespace.yaml"
  kubectl apply -f "$SCRIPT_DIR/storageclass-minikube.yaml"
  kubectl apply -f "$SCRIPT_DIR/configmap.yaml"
  kubectl apply -f "$SCRIPT_DIR/postgres.yaml"
  kubectl apply -f "$SCRIPT_DIR/backend.yaml"
  kubectl apply -f "$SCRIPT_DIR/frontend.yaml"
  kubectl apply -f "$SCRIPT_DIR/locust/locust.yaml"

  echo ""
  echo "==> Deploying monitoring stack (namespace: $MON_NS)..."
  kubectl apply -f "$SCRIPT_DIR/monitoring/namespace.yaml"
  kubectl apply -f "$SCRIPT_DIR/monitoring/rbac.yaml"
  kubectl apply -f "$SCRIPT_DIR/monitoring/loki.yaml"
  kubectl apply -f "$SCRIPT_DIR/monitoring/promtail.yaml"
  kubectl apply -f "$SCRIPT_DIR/monitoring/jaeger.yaml"
  kubectl apply -f "$SCRIPT_DIR/monitoring/prometheus.yaml"
  kubectl apply -f "$SCRIPT_DIR/monitoring/alertmanager.yaml"
  kubectl apply -f "$SCRIPT_DIR/monitoring/grafana.yaml"

  echo ""
  echo "==> Waiting for ingress-nginx admission webhook to be ready..."
  kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=120s

  echo "==> Applying Ingress resources..."
  kubectl apply -f "$SCRIPT_DIR/ingress-minikube.yaml"
  kubectl apply -f "$SCRIPT_DIR/monitoring/ingress.yaml"

  echo ""
  echo "==> Waiting for Postgres..."
  kubectl rollout status statefulset/postgres -n "$APP_NS" --timeout="$ROLLOUT_TIMEOUT"

  echo "==> Waiting for backend..."
  kubectl rollout status deployment/sre-backend -n "$APP_NS" --timeout="$ROLLOUT_TIMEOUT"

  echo "==> Waiting for frontend..."
  kubectl rollout status deployment/sre-frontend -n "$APP_NS" --timeout="$ROLLOUT_TIMEOUT"

  echo "==> Waiting for Prometheus..."
  kubectl rollout status deployment/prometheus -n "$MON_NS" --timeout="$ROLLOUT_TIMEOUT"

  echo "==> Waiting for Alertmanager..."
  kubectl rollout status deployment/alertmanager -n "$MON_NS" --timeout="$ROLLOUT_TIMEOUT"

  echo "==> Waiting for MailHog..."
  kubectl rollout status deployment/mailhog -n "$MON_NS" --timeout="$ROLLOUT_TIMEOUT"

  echo "==> Waiting for Grafana..."
  kubectl rollout status deployment/grafana -n "$MON_NS" --timeout="$ROLLOUT_TIMEOUT"

  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║              Stack is up — access guide                     ║"
  echo "╠══════════════════════════════════════════════════════════════╣"
  echo "║  Add to /etc/hosts (run once):                              ║"
  echo "║    echo \"127.0.0.1 sre.ktech.local\" | sudo tee -a /etc/hosts"
  echo "╠══════════════════════════════════════════════════════════════╣"
  echo "║  Port-forwards:                                             ║"
  echo "║    kubectl port-forward svc/frontend-service  8080:80    -n $APP_NS"
  echo "║    kubectl port-forward svc/backend-service   3001:3001  -n $APP_NS"
  echo "║    kubectl port-forward svc/locust-master-service 8089:8089 -n $APP_NS"
  echo "║    kubectl port-forward svc/prometheus-service    9090:9090  -n $MON_NS"
  echo "║    kubectl port-forward svc/alertmanager-service 9093:9093  -n $MON_NS"
  echo "║    kubectl port-forward svc/mailhog-service       8025:8025  -n $MON_NS"
  echo "║    kubectl port-forward svc/grafana-service       3000:3000  -n $MON_NS"
  echo "║    kubectl port-forward svc/loki-service          3100:3100  -n $MON_NS"
  echo "║    kubectl port-forward svc/jaeger-service       16686:16686 -n $MON_NS"
  echo "╠══════════════════════════════════════════════════════════════╣"
  echo "║  Credentials:                                               ║"
  echo "║    Grafana:  admin / Grafana@123                            ║"
  echo "║    App:      student@ktech.sre / Student@123                ║"
  echo "║    Admin:    admin@ktech.sre / Admin@123                    ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
}

# ── Teardown ──────────────────────────────────────────────────────────────────

teardown() {
  local AUTO_CONFIRM=false
  local NAMESPACES=("sre-platform" "monitoring" "ingress-nginx")

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --yes|-y) AUTO_CONFIRM=true ;;
      -h|--help) echo "Usage: $0 teardown [--yes]"; exit 0 ;;
      *) echo "Unknown arg: $1"; echo "Usage: $0 teardown [--yes]"; exit 2 ;;
    esac
    shift
  done

  confirm_or_exit() {
    local msg="$1"
    if [[ "$AUTO_CONFIRM" == "true" ]]; then return 0; fi
    read -rp "$msg [y/N] " yn
    [[ "$yn" =~ ^[Yy]$ ]] || exit 1
  }

  echo "==> Tearing down the SRE Platform stack..."

  for ns in "${NAMESPACES[@]}"; do
    echo "    Deleting namespace '$ns' (removes all resources inside)..."
    kubectl delete namespace "$ns" --ignore-not-found=true || true
  done

  echo ""
  echo "    Waiting for namespaces to terminate (this may take a minute)..."
  for ns in "${NAMESPACES[@]}"; do
    echo "      waiting for namespace/$ns to be deleted..."
    kubectl wait --for=delete "namespace/$ns" --timeout=120s || true
  done

  echo ""
  echo "    PersistentVolumes that may be left behind (if any):"
  kubectl get pv 2>/dev/null | grep -E "postgres-pvc|uploads-pvc" || true

  echo ""
  if [[ "$AUTO_CONFIRM" == "true" ]]; then
    echo "==> Stopping minikube..."
    minikube stop || true
    echo "    Minikube stopped. Run 'minikube delete' to wipe it completely."
  else
    read -rp "Stop minikube as well? [y/N] " STOP_MINIKUBE
    if [[ "$STOP_MINIKUBE" == "y" || "$STOP_MINIKUBE" == "Y" ]]; then
      echo "==> Stopping minikube..."
      minikube stop || true
      echo "    Minikube stopped. Run 'minikube delete' to wipe it completely."
    else
      echo "    Minikube left running."
    fi
  fi

  echo ""
  echo "==> Teardown complete."
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

[[ "$#" -eq 0 ]] && usage

COMMAND="$1"
shift

case "$COMMAND" in
  deploy)   deploy "$@" ;;
  teardown) teardown "$@" ;;
  -h|--help|help) usage ;;
  *) echo "Unknown command: $COMMAND"; usage ;;
esac
