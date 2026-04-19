#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
APP_NS="sre-platform"
MON_NS="monitoring"

# Increase kubectl request timeout for EKS (network latency + large payloads)
KUBECTL="kubectl --request-timeout=5m"

# ---------------------------------------------------------------------------
# CONFIG — set these before running
# ---------------------------------------------------------------------------
DOCKERHUB_USER="${DOCKERHUB_USER:-kotidevops}"
BACKEND_IMAGE="${BACKEND_IMAGE:-${DOCKERHUB_USER}/kt-backend:v4}"
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

install_nginx_ingress() {
  echo "==> Checking NGINX Ingress Controller..."
  if kubectl get deployment ingress-nginx-controller -n ingress-nginx &>/dev/null; then
    echo "    NGINX Ingress Controller already installed."
  else
    echo "    Installing NGINX Ingress Controller (AWS NLB mode)..."
    $KUBECTL apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.3/deploy/static/provider/aws/deploy.yaml

    echo "    Waiting for ingress-nginx controller to be ready (up to 3 min)..."
    $KUBECTL rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s
    echo "    NGINX Ingress Controller is ready."
  fi

  # Enable snippet annotations — required for WebSocket proxy headers in ingress rules.
  # Disabled by default in ingress-nginx v1.9+; without this the configuration-snippet
  # annotation is silently ignored and WebSocket upgrades won't be injected.
  echo "    Enabling snippet annotations in ingress-nginx ConfigMap..."
  $KUBECTL patch configmap ingress-nginx-controller -n ingress-nginx \
    --type merge -p '{"data":{"allow-snippet-annotations":"true"}}' 2>/dev/null || true
}

tag_node_sg_for_nlb() {
  # The Kubernetes NLB controller discovers which VPC security groups to add NodePort
  # rules into by looking for the tag kubernetes.io/cluster/<name>=owned.
  # EKS auto-tags the cluster SG but NOT the Terraform-managed node SG.
  # Tagging the node SG here ensures NLB rules land on the right SG on every fresh install.
  echo "==> Tagging node security group for NLB auto-discovery..."

  local RAW_CONTEXT
  RAW_CONTEXT=$(kubectl config current-context 2>/dev/null || true)
  local CLUSTER_NAME
  CLUSTER_NAME=$(echo "$RAW_CONTEXT" | sed 's|.*/cluster/||; s|.*/||')

  if [ -z "$CLUSTER_NAME" ]; then
    echo "    WARNING: Could not derive cluster name — skipping node SG tagging."
    return 0
  fi

  # Terraform names the node SG "<cluster-name>-node" via the Name tag.
  local SG_IDS
  SG_IDS=$(aws ec2 describe-security-groups \
    --filters "Name=tag:Name,Values=${CLUSTER_NAME}-node" \
    --query 'SecurityGroups[*].GroupId' --output text 2>/dev/null || echo "")

  if [ -z "$SG_IDS" ]; then
    echo "    No node SG found with Name=${CLUSTER_NAME}-node — skipping."
    return 0
  fi

  for SG_ID in $SG_IDS; do
    echo "    Tagging $SG_ID → kubernetes.io/cluster/${CLUSTER_NAME}=owned"
    aws ec2 create-tags \
      --resources "$SG_ID" \
      --tags "Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=owned" 2>/dev/null || true
  done
  echo "    Node SG tagged."
}

check_ebs_csi() {
  echo "==> Checking EBS CSI driver..."
  if $KUBECTL get daemonset ebs-csi-node -n kube-system &>/dev/null; then
    echo "    EBS CSI driver already present."
    return 0
  fi

  echo "    EBS CSI driver not found — attempting to install via EKS managed addon..."

  # Derive cluster name from the current kubectl context.
  # Contexts created by 'aws eks update-kubeconfig' look like:
  #   arn:aws:eks:<region>:<account>:cluster/<name>   or   <name>
  local RAW_CONTEXT
  RAW_CONTEXT=$(kubectl config current-context 2>/dev/null || true)  # config ops don't need the timeout flag
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
  install_nginx_ingress
  tag_node_sg_for_nlb
  check_ebs_csi

  # ── Application namespace ──────────────────────────────────────────────────
  echo ""
  echo "==> Applying application stack (namespace: $APP_NS)..."
  $KUBECTL apply -f "$SCRIPT_DIR/namespace.yaml"
  $KUBECTL apply -f "$SCRIPT_DIR/storageclass-eks.yaml"
  $KUBECTL apply -f "$SCRIPT_DIR/configmap.yaml"
  sed 's/storageClassName: standard/storageClassName: gp3/g' "$SCRIPT_DIR/postgres.yaml" | $KUBECTL apply -f -
  sed 's/storageClassName: standard/storageClassName: gp3/g' "$SCRIPT_DIR/backend.yaml" | $KUBECTL apply -f -
  $KUBECTL apply -f "$SCRIPT_DIR/frontend.yaml"
  $KUBECTL apply -f "$SCRIPT_DIR/locust/locust.yaml"

  # ── Monitoring namespace ───────────────────────────────────────────────────
  echo ""
  echo "==> Applying monitoring stack (namespace: $MON_NS)..."
  $KUBECTL apply -f "$SCRIPT_DIR/monitoring/namespace.yaml"
  $KUBECTL apply -f "$SCRIPT_DIR/monitoring/rbac.yaml"
  $KUBECTL apply -f "$SCRIPT_DIR/monitoring/loki.yaml"
  $KUBECTL apply -f "$SCRIPT_DIR/monitoring/promtail.yaml"
  $KUBECTL apply -f "$SCRIPT_DIR/monitoring/jaeger.yaml"
  $KUBECTL apply -f "$SCRIPT_DIR/monitoring/prometheus.yaml"

  # Inject dashboard JSON files as a ConfigMap so Grafana auto-provisions them
  echo "==> Loading Grafana dashboard JSON files..."
  kubectl create configmap grafana-dashboards \
    --from-file="$APP_DIR/grafana/dashboards/" \
    -n "$MON_NS" \
    --dry-run=client -o yaml | $KUBECTL apply -f -

  $KUBECTL apply -f "$SCRIPT_DIR/monitoring/grafana.yaml"

  # ── Ingress resources ──────────────────────────────────────────────────────
  echo ""
  echo "==> Applying Ingress resources..."
  $KUBECTL apply -f "$SCRIPT_DIR/ingress-eks.yaml"
  $KUBECTL apply -f "$SCRIPT_DIR/monitoring/ingress.yaml"

  # ── Wait for rollouts ──────────────────────────────────────────────────────
  echo ""
  echo "==> Waiting for Postgres..."
  $KUBECTL rollout status statefulset/postgres -n "$APP_NS" --timeout=180s

  echo "==> Waiting for backend..."
  $KUBECTL rollout status deployment/sre-backend -n "$APP_NS" --timeout=120s

  echo "==> Waiting for frontend..."
  $KUBECTL rollout status deployment/sre-frontend -n "$APP_NS" --timeout=120s

  echo "==> Waiting for Loki..."
  $KUBECTL rollout status statefulset/loki -n "$MON_NS" --timeout=120s

  echo "==> Waiting for Prometheus..."
  $KUBECTL rollout status deployment/prometheus -n "$MON_NS" --timeout=120s

  echo "==> Waiting for Grafana..."
  $KUBECTL rollout status deployment/grafana -n "$MON_NS" --timeout=120s

  echo "==> Waiting for Jaeger..."
  $KUBECTL rollout status deployment/jaeger -n "$MON_NS" --timeout=120s

  # Fetch the NLB hostname assigned by AWS
  NLB_HOST=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "<pending>")

  echo ""
  echo "╔══════════════════════════════════════════════════════════════════════╗"
  echo "║                  Stack is up — access guide                        ║"
  echo "╠══════════════════════════════════════════════════════════════════════╣"
  echo "║  NLB hostname (AWS LoadBalancer):                                  ║"
  echo "║    $NLB_HOST"
  echo "║                                                                    ║"
  echo "║  Add these to /etc/hosts (or Route53 CNAME → NLB hostname):       ║"
  echo "║    <NLB-IP>  app.ktech.io api.ktech.io locust.ktech.io            ║"
  echo "║    <NLB-IP>  grafana.ktech.io prometheus.ktech.io jaeger.ktech.io ║"
  echo "╠══════════════════════════════════════════════════════════════════════╣"
  echo "║  Ingress URLs (after DNS is set):                                  ║"
  echo "║    http://app.ktech.io          → SRE Platform frontend           ║"
  echo "║    http://api.ktech.io          → Backend API                     ║"
  echo "║    http://locust.ktech.io       → Locust load-test UI             ║"
  echo "║    http://grafana.ktech.io      → Grafana  (admin / Grafana@123)  ║"
  echo "║    http://prometheus.ktech.io   → Prometheus                      ║"
  echo "║    http://jaeger.ktech.io       → Jaeger trace UI                 ║"
  echo "╠══════════════════════════════════════════════════════════════════════╣"
  echo "║  Port-forwards (quick local access without DNS):                   ║"
  echo "║    kubectl port-forward svc/frontend-service      8080:80   -n $APP_NS ║"
  echo "║    kubectl port-forward svc/backend-service       3001:3001 -n $APP_NS ║"
  echo "║    kubectl port-forward svc/locust-master-service 8089:8089 -n $APP_NS ║"
  echo "║    kubectl port-forward svc/prometheus-service    9090:9090 -n $MON_NS ║"
  echo "║    kubectl port-forward svc/grafana-service       3000:3000 -n $MON_NS ║"
  echo "║    kubectl port-forward svc/loki-service          3100:3100 -n $MON_NS ║"
  echo "║    kubectl port-forward svc/jaeger-service     16686:16686  -n $MON_NS ║"
  echo "╠══════════════════════════════════════════════════════════════════════╣"
  echo "║  Credentials:                                                      ║"
  echo "║    Grafana:  admin / Grafana@123                                   ║"
  echo "║    App:      student@ktech.sre / Student@123                       ║"
  echo "╚══════════════════════════════════════════════════════════════════════╝"
}

delete_nginx_ingress() {
  echo "==> Removing NGINX Ingress Controller..."
  if kubectl get namespace ingress-nginx &>/dev/null; then
    $KUBECTL delete -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.3/deploy/static/provider/aws/deploy.yaml \
      --ignore-not-found
    echo "    Waiting for ingress-nginx namespace to terminate..."
    $KUBECTL wait --for=delete namespace/ingress-nginx --timeout=120s || true
    echo "    NGINX Ingress Controller removed."
  else
    echo "    ingress-nginx namespace not found — skipping."
  fi
}

teardown_all() {
  local auto_confirm=${1:-false}
  check_context
  confirm_or_exit "This will delete BOTH the app ($APP_NS) and monitoring ($MON_NS) namespaces. Continue?" "$auto_confirm"

  echo "==> Removing Ingress resources..."
  $KUBECTL delete -f "$SCRIPT_DIR/ingress-eks.yaml"         --ignore-not-found
  $KUBECTL delete -f "$SCRIPT_DIR/monitoring/ingress.yaml"  --ignore-not-found

  echo "==> Tearing down application stack..."
  $KUBECTL delete -f "$SCRIPT_DIR/locust/locust.yaml"         --ignore-not-found
  $KUBECTL delete -f "$SCRIPT_DIR/frontend.yaml"              --ignore-not-found
  $KUBECTL delete -f "$SCRIPT_DIR/backend.yaml"               --ignore-not-found
  $KUBECTL delete -f "$SCRIPT_DIR/postgres.yaml"              --ignore-not-found
  $KUBECTL delete -f "$SCRIPT_DIR/configmap.yaml"             --ignore-not-found
  $KUBECTL delete -f "$SCRIPT_DIR/storageclass-eks.yaml"      --ignore-not-found
  $KUBECTL delete -f "$SCRIPT_DIR/namespace.yaml"             --ignore-not-found

  echo "==> Tearing down monitoring stack..."
  $KUBECTL delete -f "$SCRIPT_DIR/monitoring/grafana.yaml"    --ignore-not-found
  $KUBECTL delete -f "$SCRIPT_DIR/monitoring/prometheus.yaml" --ignore-not-found
  $KUBECTL delete -f "$SCRIPT_DIR/monitoring/jaeger.yaml"     --ignore-not-found
  $KUBECTL delete -f "$SCRIPT_DIR/monitoring/promtail.yaml"   --ignore-not-found
  $KUBECTL delete -f "$SCRIPT_DIR/monitoring/loki.yaml"       --ignore-not-found
  $KUBECTL delete -f "$SCRIPT_DIR/monitoring/rbac.yaml"       --ignore-not-found
  $KUBECTL delete -f "$SCRIPT_DIR/monitoring/namespace.yaml"  --ignore-not-found

  echo "==> Waiting for namespaces to terminate..."
  $KUBECTL wait --for=delete namespace/$APP_NS --timeout=120s || true
  $KUBECTL wait --for=delete namespace/$MON_NS --timeout=120s || true

  delete_nginx_ingress

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
