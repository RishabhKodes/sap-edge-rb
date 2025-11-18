#!/bin/bash

# SPDX-FileCopyrightText: 2025 SAP edge team
#
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

# Reusable JSON patch to remove metadata finalizers
REMOVE_METADATA_FINALIZERS_PATCH='[{"op": "remove", "path": "/metadata/finalizers"}]'

# Reusable JSON patch to remove spec finalizers (namespaces)
REMOVE_SPEC_FINALIZERS_PATCH='[{"op": "remove", "path": "/spec/finalizers"}]'

# Usage: ./delete_resources.sh <project_name>
PROJECT=${1:-}

if [[ -z "$PROJECT" ]]; then
  echo "Usage: $0 <project_name>"
  exit 1
fi

if ! oc get project "$PROJECT" &>/dev/null; then
  echo "Project '$PROJECT' not found; nothing to do."
  exit 0
fi

echo "Initiating deletion of project '$PROJECT'..."
oc delete project "$PROJECT" --wait=false || true

echo "Fetching project details for '$PROJECT'..."
PROJECT_JSON=$(oc get project "$PROJECT" -o json)

RESOURCE_LINES=$(echo "$PROJECT_JSON" | jq -r '.status.conditions[]? | select(.message | test("Some resources are remaining:")) | .message' || true)
FINALIZER_LINES=$(echo "$PROJECT_JSON" | jq -r '.status.conditions[]? | select(.message | test("Some content in the namespace has finalizers remaining:")) | .message' || true)
ALL_LINES=$(printf "%s\n%s" "$RESOURCE_LINES" "$FINALIZER_LINES")

if [[ -z "$ALL_LINES" ]]; then
  echo "No dangling resources or finalizers found."
else
  echo "Detected remaining resources:"
  echo "$ALL_LINES"
fi

if echo "$ALL_LINES" | grep -qE '\bpersistentvolumeclaims\.'; then
  echo "Removing finalizers from PVCs in '$PROJECT'..."
  oc get pvc -n "$PROJECT" -o name 2>/dev/null | while read -r PVC; do
    echo "Patching $PVC to remove finalizers..."
    oc patch "$PVC" -n "$PROJECT" --type json -p "$REMOVE_METADATA_FINALIZERS_PATCH" || true
    oc delete "$PVC" -n "$PROJECT" --force --grace-period=0 || true
  done
fi

# As a safety net, sweep all namespaced resource types: remove finalizers and attempt force deletion
echo "Sweeping all namespaced resource types in '$PROJECT' to remove finalizers and delete..."
oc api-resources --verbs=list --namespaced -o name | while read -r TYPE; do
  # Remove finalizers from each instance of this TYPE
  oc get "$TYPE" -n "$PROJECT" -o name 2>/dev/null | while read -r RES; do
    echo "Patching $RES to remove finalizers..."
    oc patch "$RES" -n "$PROJECT" --type json -p '[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
  done
done

echo "Cleanup initiated for project: $PROJECT"
