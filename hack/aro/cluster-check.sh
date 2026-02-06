#!/bin/bash
# SPDX-FileCopyrightText: 2024 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
#
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# Check if ARO cluster exists and return status
# Required environment variables:
# - ARO_CLUSTER_NAME: ARO cluster name
# - ARO_RESOURCE_GROUP: Azure resource group name

# Exit codes:
# 0 - Cluster exists and is ready
# 1 - Cluster does not exist
# 2 - Cluster exists but in failed state
# 3 - Missing required parameters

usage() {
    echo "Usage: $0 [--status-only]"
    echo "Check if ARO cluster exists"
    echo ""
    echo "Options:"
    echo "  --status-only    Only return true/false (for makefile compatibility)"
    echo ""
    echo "Required environment variables:"
    echo "  ARO_CLUSTER_NAME   - ARO cluster name"
    echo "  ARO_RESOURCE_GROUP - Azure resource group name"
    echo ""
    echo "Exit codes:"
    echo "  0 - Cluster exists and is ready"
    echo "  1 - Cluster does not exist"
    echo "  2 - Cluster exists but in failed state" 
    echo "  3 - Missing required parameters"
    exit 3
}

validate_requirements() {
    local missing_vars=()
    
    if [[ -z "${ARO_CLUSTER_NAME:-}" ]]; then
        missing_vars+=("ARO_CLUSTER_NAME")
    fi
    
    if [[ -z "${ARO_RESOURCE_GROUP:-}" ]]; then
        missing_vars+=("ARO_RESOURCE_GROUP")
    fi
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        if [[ "${STATUS_ONLY:-false}" == "true" ]]; then
            echo "false"
        else
            echo "❌ Missing required environment variables: ${missing_vars[*]}" >&2
        fi
        exit 3
    fi
    
    # Check if Azure CLI is available
    if ! command -v az >/dev/null 2>&1; then
        if [[ "${STATUS_ONLY:-false}" == "true" ]]; then
            echo "false"
        else
            echo "❌ Azure CLI not found. Please install Azure CLI." >&2
        fi
        exit 3
    fi
}

check_cluster() {
    local status_only="${STATUS_ONLY:-false}"

    # Try to get cluster status
    local cluster_status
    if cluster_status=$(az aro show --name "${ARO_CLUSTER_NAME}" --resource-group "${ARO_RESOURCE_GROUP}" --query "provisioningState" -o tsv 2>/dev/null); then
        # Cluster exists - for --status-only, return "true" for ANY existing cluster
        # This ensures teardown waits until cluster is fully deleted (az aro show fails)
        if [[ "${status_only}" == "true" ]]; then
            echo "true"
            exit 0
        fi

        # Detailed output for non-status-only mode
        case "${cluster_status}" in
            "Succeeded")
                echo "✅ Cluster '${ARO_CLUSTER_NAME}' exists and is ready (status: ${cluster_status})"
                exit 0
                ;;
            "Deleting")
                echo "🗑️ Cluster '${ARO_CLUSTER_NAME}' is being deleted (status: ${cluster_status})" >&2
                exit 2
                ;;
            "Failed")
                echo "❌ Cluster '${ARO_CLUSTER_NAME}' exists but is in failed state: ${cluster_status}" >&2
                exit 2
                ;;
            *)
                echo "⏳ Cluster '${ARO_CLUSTER_NAME}' exists but is not ready (status: ${cluster_status})" >&2
                exit 2
                ;;
        esac
    else
        # Cluster does not exist
        if [[ "${status_only}" == "true" ]]; then
            echo "false"
        else
            echo "ℹ️  Cluster '${ARO_CLUSTER_NAME}' does not exist in resource group '${ARO_RESOURCE_GROUP}'"
        fi
        exit 1
    fi
}

main() {
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --status-only)
                STATUS_ONLY="true"
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                echo "Unknown option: $1" >&2
                usage
                ;;
        esac
    done
    
    validate_requirements
    check_cluster
}

# Allow script to be sourced for testing
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi