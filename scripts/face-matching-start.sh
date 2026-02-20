#!/usr/bin/env bash
# face-matching-start.sh — Mở lại cả hai pod face-matching (restore replicas)
# Usage: ./scripts/face-matching-start.sh

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-banking-ekyc-487718}"
CLUSTER_NAME="${CLUSTER_NAME:-banking-ekyc-cluster}"
CLUSTER_ZONE="${CLUSTER_ZONE:-us-central1}"
NAMESPACE="${NAMESPACE:-default}"
DEPLOYMENTS=("face-matching-signup" "face-matching-signin")
DEFAULT_REPLICAS=1

echo "==> [$(date '+%Y-%m-%d %H:%M:%S')] Starting face-matching workers..."

# Re-authenticate if running in CI
if [[ "${CI:-false}" == "true" ]]; then
  gcloud container clusters get-credentials "$CLUSTER_NAME" \
    --region "$CLUSTER_ZONE" \
    --project "$PROJECT_ID"
fi

for DEPLOY in "${DEPLOYMENTS[@]}"; do
  if ! kubectl get deployment "$DEPLOY" -n "$NAMESPACE" &>/dev/null; then
    echo "  ✗ Deployment '$DEPLOY' not found in namespace '$NAMESPACE' — skipping"
    continue
  fi

  # Read saved replica count from annotation, fallback to default
  PREVIOUS=$(kubectl get deployment "$DEPLOY" -n "$NAMESPACE" \
    -o jsonpath='{.metadata.annotations.auto-scale/previous-replicas}' 2>/dev/null || echo "")
  TARGET="${PREVIOUS:-$DEFAULT_REPLICAS}"

  CURRENT=$(kubectl get deployment "$DEPLOY" -n "$NAMESPACE" \
    -o jsonpath='{.spec.replicas}')

  if [[ "$CURRENT" -gt 0 ]]; then
    echo "  - $DEPLOY is already running with $CURRENT replicas. Skipping."
    continue
  fi

  kubectl scale deployment "$DEPLOY" -n "$NAMESPACE" --replicas="$TARGET"
  echo "  ✓ $DEPLOY scaled up to $TARGET replicas"
done

echo ""
echo "==> Waiting for rollouts..."
for DEPLOY in "${DEPLOYMENTS[@]}"; do
  if kubectl get deployment "$DEPLOY" -n "$NAMESPACE" &>/dev/null; then
    kubectl rollout status deployment/"$DEPLOY" -n "$NAMESPACE" --timeout=120s || true
  fi
done

echo ""
echo "==> Face-matching workers are ready."
kubectl get pods -n "$NAMESPACE" -l app=face-matching
