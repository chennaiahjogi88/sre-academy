#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
APP_NS="sre-platform"
MON_NS="monitoring"

# ---------------------------------------------------------------------------
# CONFIG — set these before running
# ---------------------------------------------------------------------------
DOCKERHUB_USER="${DOCKERHUB_USER:-kotidevops}"
BACKEND_IMAGE="${BACKEND_IMAGE:-${DOCKERHUB_USER}/kt-backend:v2}"
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
Usage: $0 <command> [--yes]

Commands:
  deploy     Deploy the full stack (app + monitoring)
  teardown   Tear down everything

Options:
  --yes      Skip interactive confirmations

Examples:
  $0 deploy
  $0 teardown --yes
EOF
}

confirm_or_exit() {
  local msg="$1"
  local auto_confirm=${2:-false}
  if [ "$auto_confirm" = true ]; then
    return 0
  fi
  read -rp "$msg [y/N] " yn
  [[ "$yn" =~ ^[Yy]$ ]] || exit 1
}

check_context() {
  echo "==> Verifying kubectl is pointed at EKS..."
  local CONTEXT
  CONTEXT=$(kubectl config current-context || true)
  echo "    Current context: $CONTEXT"
  if [[ "$CONTEXT" != *"eks"* && "$CONTEXT" != *"koti-dev"* ]]; then
    echo "WARNING: context '$CONTEXT' doesn't look like your EKS cluster."
    confirm_or_exit "Continue anyway?"
  fi
}

check_ebs_csi() {
  echo "==> Checking EBS CSI driver..."
  if kubectl get daemonset ebs-csi-node -n kube-system &>/dev/null; then
    echo "    EBS CSI driver already present."
    return 0
  fi

  echo "    EBS CSI driver not found — attempting to install via EKS managed addon..."

  # Derive cluster name from the current kubectl context.
  # Contexts created by 'aws eks update-kubeconfig' look like:
  #   arn:aws:eks:<region>:<account>:cluster/<name>   or   <name>
  local RAW_CONTEXT
  RAW_CONTEXT=$(kubectl config current-context 2>/dev/null || true)
  local CLUSTER_NAME
  CLUSTER_NAME=$(echo "$RAW_CONTEXT" | sed 's|.*/cluster/||; s|.*/||')

  if [ -z "$CLUSTER_NAME" ]; then
    echo "ERROR: Could not derive cluster name from context '$RAW_CONTEXT'."
    echo "       Run manually: aws eks create-addon --cluster-name <name> --addon-name aws-ebs-csi-driver"
    exit 1
  fi

  echo "    Detected cluster: $CLUSTER_NAME"

  # Create addon (idempotent — succeeds even if already being created).
  aws eks create-addon \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name aws-ebs-csi-driver \
    --resolve-conflicts OVERWRITE 2>&1 | grep -v "already exists" || true

  echo "    Waiting for EBS CSI addon to become ACTIVE (up to 5 min)..."
  local TIMEOUT=300 SLEEP=10 TRIES
  TRIES=$((TIMEOUT / SLEEP))
  for i in $(seq 1 "$TRIES"); do
    local STATUS
    STATUS=$(aws eks describe-addon \
      --cluster-name "$CLUSTER_NAME" \
      --addon-name aws-ebs-csi-driver \
      --query 'addon.status' --output text 2>/dev/null || echo "UNKNOWN")
    if [ "$STATUS" = "ACTIVE" ]; then
      echo "    EBS CSI addon is ACTIVE."
      return 0
    fi
    echo "    Status: $STATUS — attempt $i/$TRIES"
    sleep "$SLEEP"
  done

  echo "ERROR: EBS CSI addon did not become ACTIVE within ${TIMEOUT}s."
  exit 1
}

deploy_all() {
  local auto_confirm=${1:-false}
  check_context
  check_ebs_csi

  # ── Application namespace ──────────────────────────────────────────────────
  echo ""
  echo "==> Applying application stack (namespace: $APP_NS)..."
  kubectl apply -f "$SCRIPT_DIR/namespace.yaml"
  kubectl apply -f "$SCRIPT_DIR/storageclass.yaml"
  kubectl apply -f "$SCRIPT_DIR/configmap.yaml"
  kubectl apply -f "$SCRIPT_DIR/postgres.yaml"
  kubectl apply -f "$SCRIPT_DIR/backend.yaml"
  kubectl apply -f "$SCRIPT_DIR/frontend.yaml"
  kubectl apply -f "$SCRIPT_DIR/locust/locust.yaml"

  # ── Monitoring namespace ───────────────────────────────────────────────────
  echo ""
  echo "==> Applying monitoring stack (namespace: $MON_NS)..."
  kubectl apply -f "$SCRIPT_DIR/monitoring/namespace.yaml"
  kubectl apply -f "$SCRIPT_DIR/monitoring/rbac.yaml"
  kubectl apply -f "$SCRIPT_DIR/monitoring/loki.yaml"
  kubectl apply -f "$SCRIPT_DIR/monitoring/promtail.yaml"
  kubectl apply -f "$SCRIPT_DIR/monitoring/jaeger.yaml"
  kubectl apply -f "$SCRIPT_DIR/monitoring/prometheus.yaml"

  # Inject dashboard JSON files as a ConfigMap so Grafana auto-provisions them
  echo "==> Loading Grafana dashboard JSON files..."
  kubectl create configmap grafana-dashboards \
    --from-file="$APP_DIR/grafana/dashboards/" \
    -n "$MON_NS" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl apply -f "$SCRIPT_DIR/monitoring/grafana.yaml"

  # ── Wait for rollouts ──────────────────────────────────────────────────────
  echo ""
  echo "==> Waiting for Postgres..."
  kubectl rollout status statefulset/postgres -n "$APP_NS" --timeout=180s

  echo "==> Waiting for backend..."
  kubectl rollout status deployment/sre-backend -n "$APP_NS" --timeout=120s

  echo "==> Waiting for frontend..."
  kubectl rollout status deployment/sre-frontend -n "$APP_NS" --timeout=120s

  echo "==> Waiting for Loki..."
  kubectl rollout status statefulset/loki -n "$MON_NS" --timeout=120s

  echo "==> Waiting for Prometheus..."
  kubectl rollout status deployment/prometheus -n "$MON_NS" --timeout=120s

  echo "==> Waiting for Grafana..."
  kubectl rollout status deployment/grafana -n "$MON_NS" --timeout=120s

  echo "==> Waiting for Jaeger..."
  kubectl rollout status deployment/jaeger -n "$MON_NS" --timeout=120s

  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║              Stack is up — access guide                     ║"
  echo "╠══════════════════════════════════════════════════════════════╣"
  echo "║  Get the nginx ingress LoadBalancer hostname:               ║"
  echo "║    kubectl get svc -n ingress-nginx ingress-nginx-controller║"
  echo "╠══════════════════════════════════════════════════════════════╣"
  echo "║  Port-forwards (quick local access):                        ║"
  echo "║    kubectl port-forward svc/frontend-service   8080:80     -n $APP_NS"
  echo "║    kubectl port-forward svc/backend-service    3001:3001   -n $APP_NS"
  echo "║    kubectl port-forward svc/locust-master-service 8089:8089 -n $APP_NS"
  echo "║    kubectl port-forward svc/prometheus-service 9090:9090   -n $MON_NS"
  echo "║    kubectl port-forward svc/grafana-service    3000:3000   -n $MON_NS"
  echo "║    kubectl port-forward svc/loki-service       3100:3100   -n $MON_NS"
  echo "║    kubectl port-forward svc/jaeger-service     16686:16686 -n $MON_NS"
  echo "╠══════════════════════════════════════════════════════════════╣"
  echo "║  Credentials:                                               ║"
  echo "║    Grafana:  admin / Grafana@123                            ║"
  echo "║    App:      student@ktech.sre / Student@123                ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
}

teardown_all() {
  local auto_confirm=${1:-false}
  check_context
  confirm_or_exit "This will delete BOTH the app ($APP_NS) and monitoring ($MON_NS) namespaces. Continue?" "$auto_confirm"

  echo "==> Tearing down application stack..."
  kubectl delete -f "$SCRIPT_DIR/locust/locust.yaml"         --ignore-not-found
  kubectl delete -f "$SCRIPT_DIR/frontend.yaml"              --ignore-not-found
  kubectl delete -f "$SCRIPT_DIR/backend.yaml"               --ignore-not-found
  kubectl delete -f "$SCRIPT_DIR/postgres.yaml"              --ignore-not-found
  kubectl delete -f "$SCRIPT_DIR/configmap.yaml"             --ignore-not-found
  kubectl delete -f "$SCRIPT_DIR/storageclass.yaml"          --ignore-not-found
  kubectl delete -f "$SCRIPT_DIR/namespace.yaml"             --ignore-not-found

  echo "==> Tearing down monitoring stack..."
  kubectl delete -f "$SCRIPT_DIR/monitoring/grafana.yaml"    --ignore-not-found
  kubectl delete -f "$SCRIPT_DIR/monitoring/prometheus.yaml" --ignore-not-found
  kubectl delete -f "$SCRIPT_DIR/monitoring/jaeger.yaml"     --ignore-not-found
  kubectl delete -f "$SCRIPT_DIR/monitoring/promtail.yaml"   --ignore-not-found
  kubectl delete -f "$SCRIPT_DIR/monitoring/loki.yaml"       --ignore-not-found
  kubectl delete -f "$SCRIPT_DIR/monitoring/rbac.yaml"       --ignore-not-found
  kubectl delete -f "$SCRIPT_DIR/monitoring/namespace.yaml"  --ignore-not-found

  echo "==> Waiting for namespaces to terminate..."
  kubectl wait --for=delete namespace/$APP_NS --timeout=120s || true
  kubectl wait --for=delete namespace/$MON_NS --timeout=120s || true

  echo "==> Teardown complete."
}

## ----- main -----
if [ $# -lt 1 ]; then usage; exit 2; fi

CMD="$1"; shift || true
AUTO_CONFIRM=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --yes|-y) AUTO_CONFIRM=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

case "$CMD" in
  deploy)   deploy_all "$AUTO_CONFIRM" ;;
  teardown) teardown_all "$AUTO_CONFIRM" ;;
  *) echo "Unknown command: $CMD"; usage; exit 2 ;;
esac
