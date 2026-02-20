#!/usr/bin/env bash
# scale-up.sh — Restore deployments to their previous replica counts
# Usage: ./scripts/scale-up.sh [--project PROJECT_ID] [--cluster CLUSTER_NAME] [--zone ZONE]

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-banking-ekyc-487718}"
CLUSTER_NAME="${CLUSTER_NAME:-banking-ekyc-cluster}"
CLUSTER_ZONE="${CLUSTER_ZONE:-us-central1}"
NAMESPACE="${NAMESPACE:-default}"

echo "==> [$(date '+%Y-%m-%d %H:%M:%S')] Scaling up GKE cluster: $CLUSTER_NAME"

if [[ "${CI:-false}" == "true" ]]; then
  gcloud container clusters get-credentials "$CLUSTER_NAME" \
    --region "$CLUSTER_ZONE" \
    --project "$PROJECT_ID"
fi

# Default replica counts if annotation is missing
declare -A DEFAULTS=(
  [identity-service-banking-ekyc]=1
  [face-matching]=1
  [kong-gateway]=1
)

for deploy in "${!DEFAULTS[@]}"; do
  if kubectl get deployment "$deploy" -n "$NAMESPACE" &>/dev/null; then
    # Read saved replica count from annotation
    PREVIOUS=$(kubectl get deployment "$deploy" -n "$NAMESPACE" \
      -o jsonpath='{.metadata.annotations.auto-scale/previous-replicas}' 2>/dev/null || echo "")
    TARGET="${PREVIOUS:-${DEFAULTS[$deploy]}}"
    kubectl scale deployment "$deploy" -n "$NAMESPACE" --replicas="$TARGET"
    echo "  ✓ $deploy scaled up to $TARGET replicas"
  else
    echo "  - $deploy not found, skipping"
  fi
done

echo ""
echo "==> Waiting for rollouts to complete..."
for deploy in "${!DEFAULTS[@]}"; do
  if kubectl get deployment "$deploy" -n "$NAMESPACE" &>/dev/null; then
    kubectl rollout status deployment/"$deploy" -n "$NAMESPACE" --timeout=120s || true
  fi
done

echo ""
echo "==> Cluster is ready."
kubectl get pods -n "$NAMESPACE"
