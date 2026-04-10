#!/bin/bash
# ============================================================
# Teardown — Remove all lab resources
# ============================================================
echo "Deleting namespace ktech-demo and all its resources..."
kubectl delete namespace ktech-demo --ignore-not-found
echo "Done. All ktech-demo resources removed."
