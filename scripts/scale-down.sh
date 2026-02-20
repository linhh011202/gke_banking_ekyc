#!/usr/bin/env bash
# scale-down.sh — Scale all deployments to 0 replicas to stop billing on VM nodes
# Usage: ./scripts/scale-down.sh [--project PROJECT_ID] [--cluster CLUSTER_NAME] [--zone ZONE]

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-banking-ekyc-487718}"
CLUSTER_NAME="${CLUSTER_NAME:-banking-ekyc-cluster}"
CLUSTER_ZONE="${CLUSTER_ZONE:-us-central1}"
NAMESPACE="${NAMESPACE:-default}"

echo "==> [$(date '+%Y-%m-%d %H:%M:%S')] Scaling down GKE cluster: $CLUSTER_NAME"

# Optionally re-authenticate (useful when run from Cloud Scheduler via Cloud Run)
if [[ "${CI:-false}" == "true" ]]; then
  gcloud container clusters get-credentials "$CLUSTER_NAME" \
    --region "$CLUSTER_ZONE" \
    --project "$PROJECT_ID"
fi

DEPLOYMENTS=(
  identity-service-banking-ekyc
  face-matching
  kong-gateway
)

for deploy in "${DEPLOYMENTS[@]}"; do
  if kubectl get deployment "$deploy" -n "$NAMESPACE" &>/dev/null; then
    # Save current replica count as annotation before scaling down
    CURRENT=$(kubectl get deployment "$deploy" -n "$NAMESPACE" \
      -o jsonpath='{.spec.replicas}')
    kubectl annotate deployment "$deploy" -n "$NAMESPACE" \
      auto-scale/previous-replicas="$CURRENT" --overwrite
    kubectl scale deployment "$deploy" -n "$NAMESPACE" --replicas=0
    echo "  ✓ $deploy scaled down (was $CURRENT replicas)"
  else
    echo "  - $deploy not found, skipping"
  fi
done

echo ""
echo "==> All deployments scaled to 0."
echo "    Cluster autoscaler will remove idle nodes within ~10 minutes."
echo "    Run ./scripts/scale-up.sh to restore."
