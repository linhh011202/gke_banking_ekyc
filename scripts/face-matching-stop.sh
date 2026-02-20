#!/usr/bin/env bash
# face-matching-stop.sh — Tắt tạm thời cả hai pod face-matching (scale to 0)
# Usage: ./scripts/face-matching-stop.sh

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-banking-ekyc-487718}"
CLUSTER_NAME="${CLUSTER_NAME:-banking-ekyc-cluster}"
CLUSTER_ZONE="${CLUSTER_ZONE:-us-central1}"
NAMESPACE="${NAMESPACE:-default}"
DEPLOYMENTS=("face-matching-signup" "face-matching-signin")

echo "==> [$(date '+%Y-%m-%d %H:%M:%S')] Stopping face-matching workers..."

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

  # Save current replica count before scaling down
  CURRENT=$(kubectl get deployment "$DEPLOY" -n "$NAMESPACE" \
    -o jsonpath='{.spec.replicas}')

  if [[ "$CURRENT" -eq 0 ]]; then
    echo "  - $DEPLOY is already scaled to 0. Skipping."
    continue
  fi

  kubectl annotate deployment "$DEPLOY" -n "$NAMESPACE" \
    auto-scale/previous-replicas="$CURRENT" --overwrite

  kubectl scale deployment "$DEPLOY" -n "$NAMESPACE" --replicas=0

  echo "  ✓ $DEPLOY stopped (was $CURRENT replicas)"
done

echo ""
echo "==> To start them again, run: ./scripts/face-matching-start.sh"
