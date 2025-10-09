#!/bin/bash
set -euo pipefail

# Usage: ./force-delete-project.sh <project_name>
PROJECT=${1:-}

if [[ -z "$PROJECT" ]]; then
  echo "Usage: $0 <project_name>"
  exit 1
fi

if ! oc get project "$PROJECT" &>/dev/null; then
  echo "Project '$PROJECT' not found."
  exit 1
fi

echo "Fetching project details for '$PROJECT'..."
PROJECT_YAML=$(oc get project "$PROJECT" -o yaml)

RESOURCE_LINES=$(echo "$PROJECT_YAML" | grep -A3 "Some resources are remaining:" | sed 's/^.*message: //g' || true)
FINALIZER_LINES=$(echo "$PROJECT_YAML" | grep -A3 "Some content in the namespace has finalizers remaining:" | sed 's/^.*message: //g' || true)
ALL_LINES=$(printf "%s\n%s" "$RESOURCE_LINES" "$FINALIZER_LINES")

if [[ -z "$ALL_LINES" ]]; then
  echo "No dangling resources or finalizers found."
else
  echo "Detected remaining resources:"
  echo "$ALL_LINES"
fi

RESOURCE_TYPES=$(echo "$ALL_LINES" | grep -oE '([a-zA-Z0-9]+\.)+[a-zA-Z0-9]+' | sort -u)

if [[ -z "$RESOURCE_TYPES" ]]; then
  echo "No custom resources to clean up."
else
  for RESOURCE in $RESOURCE_TYPES; do
    echo "Processing resource: $RESOURCE"
    if oc get "$RESOURCE" -n "$PROJECT" &>/dev/null; then
      oc get "$RESOURCE" -n "$PROJECT" -o name | while read -r RES; do
        echo "Patching $RES to remove finalizers..."
        oc patch "$RES" -n "$PROJECT" --type json -p '[{"op": "remove", "path": "/metadata/finalizers"}]' || true
      done
    else
      echo "Resource type $RESOURCE not found; skipping."
    fi
  done
fi

echo "Removing project-level finalizers..."
oc patch project "$PROJECT" --type json -p '[{"op": "remove", "path": "/metadata/finalizers"}]' || true

echo "Deleting project '$PROJECT'..."
oc delete project "$PROJECT" --wait=false || true

echo "Cleanup initiated for project: $PROJECT"
