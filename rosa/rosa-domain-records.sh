#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2024 SAP edge team
# SPDX-FileContributor: Kirill Satarin (@kksat)
# SPDX-FileContributor: Manjun Jiao (@mjiao)
#
# SPDX-License-Identifier: Apache-2.0
# This helper script creates or updates Route 53 DNS records for a ROSA cluster.
# It discovers the cluster's API and ingress endpoints, resolves their IPs, and
# deploys the appropriate CloudFormation stack (A-records or CNAMEs) under your domain.

# shellcheck disable=SC2059
set -euo pipefail

DOMAIN=""
ROSA_CLUSTER_NAME="sapeic-cluster"
STACK_NAME=""

print_help() {
  echo "Usage: $0 --domain DOMAIN --rosa-name NAME [--stack-name STACK_NAME]"
  echo
  echo "Options:"
  echo "  --domain DOMAIN             Specify the domain (Route53 hosted zone)"
  echo "  --rosa-name NAME            Specify the ROSA cluster name"
  echo "  --stack-name STACK_NAME     Specify CloudFormation stack name (optional)"
  echo "  --help                      Show this help message"
  exit 1
}

# Process command-line arguments
while (( "$#" )); do
  case "$1" in
    --domain)
      DOMAIN="$2"
      shift 2
      ;;
    --rosa-name)
      ROSA_CLUSTER_NAME="$2"
      shift 2
      ;;
    --stack-name)
      STACK_NAME="$2"
      shift 2
      ;;
    --help)
      print_help
      ;;
    *)
      echo "Error: Invalid argument '$1'"
      print_help
  esac
done

if [ -z "${DOMAIN}" ] || [ -z "${ROSA_CLUSTER_NAME}" ]; then
  echo "Error: Missing required arguments"
  print_help
fi

# Set default stack name if not provided
if [ -z "${STACK_NAME}" ]; then
  STACK_NAME="rosa-domain-records-${ROSA_CLUSTER_NAME}"
fi

# Check if ROSA cluster exists
echo "Checking if ROSA cluster '${ROSA_CLUSTER_NAME}' exists..."
if ! rosa describe cluster --cluster "${ROSA_CLUSTER_NAME}" >/dev/null 2>&1; then
  echo "Error: ROSA cluster '${ROSA_CLUSTER_NAME}' does not exist"
  exit 1
fi

# Get cluster API and Ingress endpoints
echo "Getting ROSA cluster endpoints..."
if ! API_URL=$(rosa describe cluster --cluster "${ROSA_CLUSTER_NAME}" --output json | jq -r '.api.url' | sed 's|https://||' | sed 's|:6443||'); then
  echo "Error: Failed to get API URL"
  exit 1
fi

if ! CONSOLE_URL=$(rosa describe cluster --cluster "${ROSA_CLUSTER_NAME}" --output json | jq -r '.console.url' | sed 's|https://||'); then
  echo "Error: Failed to get console URL"
  exit 1
fi

# Extract the base ingress domain from console URL
# Console URL format: console-openshift-console.apps.${cluster}.${random}.${region}.rosa.openshiftapps.com
INGRESS_DOMAIN=${CONSOLE_URL#console-openshift-console.}

echo "API URL: ${API_URL}"
echo "Console URL: ${CONSOLE_URL}"
echo "Ingress Domain: ${INGRESS_DOMAIN}"

# Get Route53 hosted zone ID
echo "Getting Route53 hosted zone ID for domain '${DOMAIN}'..."
if ! HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "${DOMAIN}" --query "HostedZones[?Name=='${DOMAIN}.'].Id" --output text | sed 's|/hostedzone/||'); then
  echo "Error: Failed to get hosted zone ID"
  exit 1
fi

if [ -z "${HOSTED_ZONE_ID}" ]; then
  echo "Error: Route53 hosted zone for domain '${DOMAIN}' not found"
  exit 1
fi

echo "Found hosted zone ID: ${HOSTED_ZONE_ID}"

# Resolve IP addresses for the endpoints
echo "Resolving IP addresses..."
API_IP=$(nslookup "${API_URL}" | grep -A1 "Name:" | tail -n1 | awk '{print $2}' || echo "")
INGRESS_IP=$(nslookup "console-openshift-console.${INGRESS_DOMAIN}" | grep -A1 "Name:" | tail -n1 | awk '{print $2}' || echo "")

if [ -z "${API_IP}" ] || [ -z "${INGRESS_IP}" ]; then
  echo "Warning: Could not resolve IP addresses. Using CNAME records instead."
  USE_CNAME=true
else
  echo "API IP: ${API_IP}"
  echo "Ingress IP: ${INGRESS_IP}"
  USE_CNAME=false
fi

# Deploy CloudFormation stack for domain records
echo "Creating domain records for ROSA cluster..."

if [ "${USE_CNAME}" = "true" ]; then
  # Create CNAME records pointing to the original endpoints
  if ! aws cloudformation deploy \
    --template-file rosa/domain-records-cname.yaml \
    --stack-name "${STACK_NAME}" \
    --parameter-overrides \
    HostedZoneName="${DOMAIN}" \
    ClusterName="${ROSA_CLUSTER_NAME}" \
    APITarget="${API_URL}" \
    IngressTarget="${INGRESS_DOMAIN}"; then
    echo "Error: Failed to deploy CloudFormation stack with CNAME records"
    exit 1
  fi
else
  # Create A records with resolved IP addresses
  if ! aws cloudformation deploy \
    --template-file rosa/domain-records.yaml \
    --stack-name "${STACK_NAME}" \
    --parameter-overrides \
    HostedZoneName="${DOMAIN}" \
    ClusterName="${ROSA_CLUSTER_NAME}" \
    IPv4Address="${API_IP}"; then
    echo "Error: Failed to deploy CloudFormation stack with A records"
    exit 1
  fi
fi

echo "Domain records created successfully!"
echo "Custom endpoints:"
echo "  API: api.${ROSA_CLUSTER_NAME}.${DOMAIN}"
echo "  Console: console-openshift-console.apps.${ROSA_CLUSTER_NAME}.${DOMAIN}"
echo "  Apps: *.apps.${ROSA_CLUSTER_NAME}.${DOMAIN}"
