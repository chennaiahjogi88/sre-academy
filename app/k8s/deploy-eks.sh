#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
NAMESPACE="sre-platform"

# ---------------------------------------------------------------------------
# CONFIG — set these before running
# ---------------------------------------------------------------------------
DOCKERHUB_USER="${DOCKERHUB_USER:-kotidevops}"
BACKEND_IMAGE="${BACKEND_IMAGE:-${DOCKERHUB_USER}/sre-backend:latest}"
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
Usage: $0 <command> [--yes]

Commands:
  deploy     Deploy the full stack (namespace, storageclass, db, metrics, app)
  teardown   Tear down the stack (delete manifests)

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
  if ! kubectl get daemonset ebs-csi-node -n kube-system &>/dev/null; then
    echo "    EBS CSI driver not found. Installing via EKS add-on is recommended:"
    echo "      aws eks create-addon --cluster-name <cluster-name> --addon-name aws-ebs-csi-driver"
    echo "    Or continue if you already have it installed another way."
    confirm_or_exit "Continue?"
  fi
}

deploy_all() {
  local auto_confirm=${1:-false}
  check_context
  check_ebs_csi

  # Optional: build & push backend image if desired
  # echo "==> Building & pushing backend image..."
  # docker build -t "$BACKEND_IMAGE" "$APP_DIR/backend"
  # docker push "$BACKEND_IMAGE"

  echo "==> Applying manifests..."
  kubectl apply -f "$SCRIPT_DIR/namespace.yaml"
  kubectl apply -f "$SCRIPT_DIR/storageclass.yaml"
  kubectl apply -f "$SCRIPT_DIR/configmap.yaml"
  kubectl apply -f "$SCRIPT_DIR/postgres.yaml"
  kubectl apply -f "$SCRIPT_DIR/prometheus.yaml"
  kubectl apply -f "$SCRIPT_DIR/grafana.yaml"
  kubectl apply -f "$SCRIPT_DIR/backend.yaml"
  kubectl apply -f "$SCRIPT_DIR/frontend.yaml"

  echo "==> Waiting for Postgres to be ready..."
  kubectl rollout status statefulset/postgres -n "$NAMESPACE" --timeout=180s

  echo "==> Waiting for backend to be ready..."
  kubectl rollout status deployment/sre-backend -n "$NAMESPACE" --timeout=120s

  echo "==> Waiting for frontend to be ready..."
  kubectl rollout status deployment/sre-frontend -n "$NAMESPACE" --timeout=120s

  echo ""
  echo "==> Stack is up!"
  echo ""
  echo "    Get the nginx ingress LoadBalancer hostname:"
  echo "      kubectl get svc -n ingress-nginx ingress-nginx-controller"
  echo ""
  echo "    Port-forwards (for quick access without ingress):"
  echo "      kubectl port-forward svc/frontend-service   8080:80    -n $NAMESPACE"
  echo "      kubectl port-forward svc/backend-service    3001:3001  -n $NAMESPACE"
  echo "      kubectl port-forward svc/grafana-service    3000:3000  -n $NAMESPACE"
  echo "      kubectl port-forward svc/prometheus-service 9090:9090  -n $NAMESPACE"
  echo ""
  echo "    Grafana: admin / Grafana@123"
}

teardown_all() {
  local auto_confirm=${1:-false}
  check_context
  confirm_or_exit "This will delete the stack resources in namespace '$NAMESPACE'. Continue?" "$auto_confirm"

  echo "==> Deleting manifests (ignore not-found errors)..."
  kubectl delete -f "$SCRIPT_DIR/frontend.yaml" --ignore-not-found
  kubectl delete -f "$SCRIPT_DIR/backend.yaml" --ignore-not-found
  kubectl delete -f "$SCRIPT_DIR/grafana.yaml" --ignore-not-found
  kubectl delete -f "$SCRIPT_DIR/prometheus.yaml" --ignore-not-found
  kubectl delete -f "$SCRIPT_DIR/postgres.yaml" --ignore-not-found
  kubectl delete -f "$SCRIPT_DIR/configmap.yaml" --ignore-not-found
  kubectl delete -f "$SCRIPT_DIR/storageclass.yaml" --ignore-not-found
  kubectl delete -f "$SCRIPT_DIR/namespace.yaml" --ignore-not-found

  echo "==> Waiting for namespace to terminate (if applicable)..."
  kubectl wait --for=delete namespace/$NAMESPACE --timeout=120s || true

  echo "==> Teardown complete."
}

## ----- main -----
if [ $# -lt 1 ]; then
  usage
  exit 2
fi

CMD="$1"
shift || true
AUTO_CONFIRM=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --yes|-y)
      AUTO_CONFIRM=true
      shift
      ;;
    -h|--help)
      usage; exit 0
      ;;
    *)
      echo "Unknown arg: $1"; usage; exit 2
      ;;
  esac
done

case "$CMD" in
  deploy)
    deploy_all "$AUTO_CONFIRM"
    ;;
  teardown)
    teardown_all "$AUTO_CONFIRM"
    ;;
  *)
    echo "Unknown command: $CMD"; usage; exit 2
    ;;
esac
