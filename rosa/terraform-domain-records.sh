#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2024 SAP edge team
# SPDX-FileContributor: Kirill Satarin (@kksat)
# SPDX-FileContributor: Manjun Jiao (@mjiao)
#
# SPDX-License-Identifier: Apache-2.0
# This helper script creates or updates Route 53 DNS records for a ROSA cluster using Terraform.
# It discovers the cluster's API and ingress endpoints, resolves their IPs, and
# deploys the appropriate Terraform configuration (A-records or CNAMEs) under your domain.

# shellcheck disable=SC2059
set -euo pipefail

DOMAIN=""
ROSA_CLUSTER_NAME="sapeic-cluster"
TERRAFORM_DIR="rosa/terraform"

print_help() {
  echo "Usage: $0 --domain DOMAIN --rosa-name NAME [--terraform-dir DIR]"
  echo
  echo "Options:"
  echo "  --domain DOMAIN             Specify the domain (Route53 hosted zone)"
  echo "  --rosa-name NAME            Specify the ROSA cluster name"
  echo "  --terraform-dir DIR         Specify Terraform directory (default: rosa/terraform)"
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
    --terraform-dir)
      TERRAFORM_DIR="$2"
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

# Get Route53 hosted zone ID to verify it exists
echo "Verifying Route53 hosted zone exists for domain '${DOMAIN}'..."
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

# Prepare Terraform variables
cd "${TERRAFORM_DIR}"

# Create terraform.tfvars file
cat > terraform.tfvars <<EOF
cluster_name = "${ROSA_CLUSTER_NAME}"
domain_name = "${DOMAIN}"
EOF

if [ -z "${API_IP}" ] || [ -z "${INGRESS_IP}" ]; then
  echo "Warning: Could not resolve IP addresses. Using CNAME records instead."
  cat >> terraform.tfvars <<EOF
use_cname_records = true
api_target = "${API_URL}"
ingress_target = "${INGRESS_DOMAIN}"
EOF
else
  echo "API IP: ${API_IP}"
  echo "Ingress IP: ${INGRESS_IP}"
  cat >> terraform.tfvars <<EOF
use_cname_records = false
ipv4_address = "${API_IP}"
EOF
fi

# Initialize and apply Terraform
echo "Initializing Terraform..."
terraform init

echo "Planning Terraform deployment..."
terraform plan -var-file=terraform.tfvars

echo "Applying Terraform configuration..."
terraform apply -var-file=terraform.tfvars -auto-approve

echo "Domain records created successfully!"
echo "Custom endpoints:"
echo "  API: api.${ROSA_CLUSTER_NAME}.${DOMAIN}"
echo "  Console: console-openshift-console.apps.${ROSA_CLUSTER_NAME}.${DOMAIN}"
echo "  Apps: *.apps.${ROSA_CLUSTER_NAME}.${DOMAIN}"
