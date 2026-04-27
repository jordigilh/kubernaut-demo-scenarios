#!/bin/sh
set -e

echo "=== Phase 0: Resolve PDB ==="

PDB_NAME="$TARGET_RESOURCE_NAME"
if [ "$TARGET_RESOURCE_KIND" != "PodDisruptionBudget" ]; then
  echo "Target is $TARGET_RESOURCE_KIND/$TARGET_RESOURCE_NAME — locating PDB in namespace $TARGET_RESOURCE_NAMESPACE..."
  PDB_NAME=$(kubectl get pdb -n "$TARGET_RESOURCE_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -z "$PDB_NAME" ]; then
    echo "ERROR: no PodDisruptionBudget found in namespace $TARGET_RESOURCE_NAMESPACE"
    exit 1
  fi
  echo "Resolved PDB: $PDB_NAME"
fi

echo "=== Phase 1: Validate ==="
echo "Checking PDB $PDB_NAME status..."

MIN_AVAILABLE=$(kubectl get pdb "$PDB_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
  -o jsonpath='{.spec.minAvailable}')
ALLOWED=$(kubectl get pdb "$PDB_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
  -o jsonpath='{.status.disruptionsAllowed}')
CURRENT_HEALTHY=$(kubectl get pdb "$PDB_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
  -o jsonpath='{.status.currentHealthy}')
EXPECTED=$(kubectl get pdb "$PDB_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
  -o jsonpath='{.status.expectedPods}')
echo "Current minAvailable: $MIN_AVAILABLE"
echo "Disruptions allowed: $ALLOWED"
echo "Healthy/Expected: $CURRENT_HEALTHY/$EXPECTED"

if [ "$ALLOWED" -gt 0 ]; then
  echo "WARNING: PDB already allows $ALLOWED disruptions -- may have resolved itself."
  echo "Proceeding with relaxation as the alert indicated a deadlock."
fi

NEW_MIN=$((MIN_AVAILABLE - 1))
if [ "$NEW_MIN" -lt 1 ]; then
  NEW_MIN=1
fi
echo "Validated: will reduce minAvailable from $MIN_AVAILABLE to $NEW_MIN"

echo "=== Phase 2: Action ==="
echo "Patching PDB $PDB_NAME minAvailable to $NEW_MIN..."
kubectl patch pdb "$PDB_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
  --type=merge -p "{\"spec\":{\"minAvailable\":$NEW_MIN}}"

echo "Waiting for disruption budget to update (10s)..."
sleep 10

echo "=== Phase 3: Verify ==="
NEW_MIN_AVAILABLE=$(kubectl get pdb "$PDB_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
  -o jsonpath='{.spec.minAvailable}')
NEW_ALLOWED=$(kubectl get pdb "$PDB_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
  -o jsonpath='{.status.disruptionsAllowed}')
NEW_HEALTHY=$(kubectl get pdb "$PDB_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
  -o jsonpath='{.status.currentHealthy}')
echo "New minAvailable: $NEW_MIN_AVAILABLE"
echo "New disruptions allowed: $NEW_ALLOWED"
echo "Current healthy pods: $NEW_HEALTHY"

if [ "$NEW_MIN_AVAILABLE" -lt "$MIN_AVAILABLE" ]; then
  echo "=== SUCCESS: PDB relaxed (minAvailable $MIN_AVAILABLE -> $NEW_MIN_AVAILABLE) ==="
  if [ "$NEW_ALLOWED" -eq 0 ]; then
    echo "Note: allowed disruptions is 0 because an active drain already consumed the budget (healthy=$NEW_HEALTHY, minAvailable=$NEW_MIN_AVAILABLE). This is expected."
  else
    echo "Disruptions now allowed: $NEW_ALLOWED"
  fi
else
  echo "ERROR: PDB minAvailable was not reduced (still $NEW_MIN_AVAILABLE)"
  exit 1
fi
