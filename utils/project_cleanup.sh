#!/bin/bash

# Usage check
if [ $# -lt 1 ]; then
    echo "Usage: $0 <project_name>"
    exit 1
fi

PROJECT_NAME=$1

# Function to print with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Check if project exists
if ! oc get project "$PROJECT_NAME" &>/dev/null; then
    log "Error: Project '$PROJECT_NAME' does not exist"
    exit 1
fi

log "Starting deletion process for project: $PROJECT_NAME"

# Function to remove finalizers from a resource
remove_finalizers() {
    local RESOURCE_TYPE=$1
    local NAMESPACE=$2

    log "Processing $RESOURCE_TYPE in namespace $NAMESPACE"

    # Get resources of this type
    RESOURCES=$(oc get "$RESOURCE_TYPE" -n "$NAMESPACE" -o name 2>/dev/null)

    if [ -z "$RESOURCES" ]; then
        log "No $RESOURCE_TYPE found in project $NAMESPACE"
        return
    fi

    log "Found $(echo "$RESOURCES" | wc -l) $RESOURCE_TYPE resources"

    # For each resource, remove finalizers
    echo "$RESOURCES" | while read -r RESOURCE; do
        if [ -z "$RESOURCE" ]; then
            continue
        fi

        log "Removing finalizers from $RESOURCE"
        if oc patch "$RESOURCE" -n "$NAMESPACE" --type json -p '[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null; then
            log "Successfully removed finalizers from $RESOURCE"
        else
            log "Failed to remove finalizers from $RESOURCE"
        fi
    done
}

# First attempt to delete the project normally
log "Attempting standard project deletion..."
oc delete project "$PROJECT_NAME" --wait=false


sleep 5

# Check if project is still there
if ! oc get project "$PROJECT_NAME" &>/dev/null; then
    log "Project '$PROJECT_NAME' was deleted successfully."
    exit 0
fi

# Project is still there, analyze what's preventing deletion
log "Project still exists. Analyzing remaining resources..."

# Get project details in YAML format for analysis
PROJECT_YAML=$(oc get project "$PROJECT_NAME" -o yaml)
log "Project details obtained."

# Extract information about remaining resources from status
log "Checking for remaining resources in the project status..."

# Extract custom resource types that are preventing deletion
# Look for lines with "has X resource instances" in the project yaml
CUSTOM_RESOURCES=$(echo "$PROJECT_YAML" | grep -o '[a-zA-Z0-9]\+\.[a-zA-Z0-9.]\+ has [0-9]\+ resource instances' | sed 's/ has [0-9]\+ resource instances//')

if [ -n "$CUSTOM_RESOURCES" ]; then
    log "Found custom resources preventing deletion:"
    echo "$CUSTOM_RESOURCES" | while read -r RESOURCE_TYPE; do
        log "- $RESOURCE_TYPE"
        remove_finalizers "$RESOURCE_TYPE" "$PROJECT_NAME"
    done
else
    log "No custom resources explicitly listed in status"
fi

# Extract finalizer types from the status
FINALIZER_TYPES=$(echo "$PROJECT_YAML" | grep -o '[a-zA-Z0-9./-]\+ in [0-9]\+ resource instances' | sed 's/ in [0-9]\+ resource instances//')

if [ -n "$FINALIZER_TYPES" ]; then
    log "Found these finalizer types:"
    echo "$FINALIZER_TYPES"
else
    log "No specific finalizer types listed in status"
fi

# Remove finalizers from the project itself
log "Removing finalizers from project $PROJECT_NAME"
if oc patch project "$PROJECT_NAME" --type json -p '[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null; then
    log "Successfully removed finalizers from project"
else
    log "Failed to remove finalizers from project"
fi

# Instead of using a predefined list, discover all resource types in the project
log "Discovering all resource types in the project..."
API_RESOURCES=$(oc api-resources --namespaced=true -o name)
PRESENT_RESOURCES=()

for RESOURCE_TYPE in $API_RESOURCES; do
    # Check if resources of this type exist in the project
    if oc get "$RESOURCE_TYPE" -n "$PROJECT_NAME" --no-headers 2>/dev/null | grep -q .; then
        PRESENT_RESOURCES+=("$RESOURCE_TYPE")
    fi
done

# Process all discovered resources
log "Checking discovered resources for finalizers... Found ${#PRESENT_RESOURCES[@]} resource types"
for RESOURCE_TYPE in "${PRESENT_RESOURCES[@]}"; do
    remove_finalizers "$RESOURCE_TYPE" "$PROJECT_NAME"
done

# Add specific custom resources found in the edgelm example
# CUSTOM_RESOURCE_TYPES=(
#     "imagereplications.edgelm.sap.corp"
#     "replicationservices.edgelm.sap.corp"
#     "sapcloudconnectors.edgelm.sap.com"
#     "sourceregistries.edgelm.sap.corp"
#     "systemmappings.edgelm.sap.com"
# )

# dynamically get all custom resources
log "Checking for all custom resources in the project..."
CUSTOM_RESOURCES=$(oc get crd -o name | cut -d'/' -f2 | while read -r crd; do oc get "$crd" -n "$PROJECT_NAME" -o name 2>/dev/null; done | cut -d'/' -f2 | sort -u)

# Process all custom resources
log "Checking custom resources for finalizers..."
echo "$CUSTOM_RESOURCES" | while read -r RESOURCE_TYPE; do
    remove_finalizers "$RESOURCE_TYPE" "$PROJECT_NAME"
done

# Try to delete the project again after removing finalizers
log "Attempting to delete project again..."
oc delete project "$PROJECT_NAME" --wait=false

# Wait for the project to be deleted
MAX_WAIT=120
WAIT_INTERVAL=5
ELAPSED=0

log "Waiting for project to be deleted..."
while [ $ELAPSED -lt $MAX_WAIT ]; do
    if ! oc get project "$PROJECT_NAME" &>/dev/null; then
        log "Project '$PROJECT_NAME' has been successfully deleted."
        exit 0
    fi

    # If still not deleted after half the wait time, try force removal again
    if [ $ELAPSED -eq $(($MAX_WAIT / 2)) ]; then
        log "Project still exists. Forcing finalizer removal one more time..."
        oc patch project "$PROJECT_NAME" --type json -p '[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null
    fi

    log "Project still exists, waiting... ($ELAPSED/$MAX_WAIT seconds)"
    sleep $WAIT_INTERVAL
    ELAPSED=$((ELAPSED + WAIT_INTERVAL))
done

# Final check
if oc get project "$PROJECT_NAME" &>/dev/null; then
    log "WARNING: Project still exists after $MAX_WAIT seconds."
    log "Outputting current project status for debugging:"
    oc get project "$PROJECT_NAME" -o yaml
    exit 1
else
    log "Project '$PROJECT_NAME' has been successfully deleted."
    exit 0
fi
