#!/usr/bin/env bash
set -uo pipefail

NAMESPACE="sre-platform"

echo "==> Tearing down the SRE Platform stack..."

echo "    Deleting namespace '$NAMESPACE' (removes all resources inside)..."
kubectl delete namespace "$NAMESPACE" --ignore-not-found=true || true

echo ""
echo "    Namespace deleted. PersistentVolumes may still exist if using hostPath:"
kubectl get pv 2>/dev/null | grep -E "postgres-pvc|uploads-pvc" || true

echo ""
read -rp "Stop minikube as well? [y/N] " STOP_MINIKUBE
if [[ "$STOP_MINIKUBE" == "y" || "$STOP_MINIKUBE" == "Y" ]]; then
  echo "==> Stopping minikube..."
  minikube stop || true
  echo "    Minikube stopped. Run 'minikube delete' to wipe it completely."
else
  echo "    Minikube left running."
fi

echo ""
echo "==> Teardown complete."
