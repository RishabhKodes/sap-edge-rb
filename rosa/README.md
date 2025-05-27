<!--
SPDX-FileCopyrightText: 2025 SAP edge team
SPDX-FileContributor: Kirill Satarin (@kksat)
SPDX-FileContributor: Manjun Jiao (@mjiao)

SPDX-License-Identifier: Apache-2.0
-->


# ROSA Infrastructure Templates and Scripts

This directory contains AWS CloudFormation templates and scripts for deploying Red Hat OpenShift Service on AWS (ROSA) clusters, equivalent to the Azure bicep templates for ARO.

## Files Overview

### CloudFormation Templates

- **`network.yaml`** - Creates VPC, subnets, NAT gateways, and route tables for ROSA clusters
- **`domain-records.yaml`** - Creates Route53 DNS records (A records by default; CNAME fallback handled automatically by the helper script)

### Scripts

- **`rosa-domain-records.sh`** - Creates domain records by extracting cluster endpoints and setting up DNS

## Usage

### Prerequisites

1. **ROSA CLI installed and configured**
   ```bash
   # Install ROSA CLI
   curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/rosa/latest/rosa-linux.tar.gz
   tar -xzf rosa-linux.tar.gz
   sudo mv rosa /usr/local/bin/

   # Login to ROSA
   rosa login --token="your-rosa-token"
   ```

2. **AWS CLI configured with appropriate permissions**
   ```bash
   aws configure
   ```

3. **Route53 hosted zone created for your domain**
   ```bash
   aws route53 create-hosted-zone --name your-domain.com --caller-reference $(date +%s)
   ```

### Environment Variables

Set the following variables in your environment or makefile:

```bash
export CLUSTER_NAME=sapeic-cluster
export ROSA_REGION=eu-central-1
export ROSA_VERSION=4.18.13
export ROSA_DOMAIN=sapeic.com
export ROSA_TOKEN=your-rosa-token
```

### Deployment Workflow

1. **Full deployment** (recommended):
   ```bash
   make rosa-cluster
   ```

2. **Step-by-step deployment**:
   ```bash
   # 1. Verify domain zone exists
   make rosa-domain-zone-exists

   # 2. Deploy network infrastructure
   make rosa-network-deploy

   # 3. Create cluster
   make rosa-cluster

   # 4. Create operator roles and OIDC provider
   make rosa-operator-roles
   make rosa-oidc-provider

   # 5. Create domain records (optional)
   make rosa-domain-records
   ```

### Cluster Management

```bash
# Get cluster status
make rosa-cluster-status

# Create cluster admin
make rosa-cluster-admin

# Login with oc CLI
make rosa-oc-login

# Get cluster credentials
make rosa-credentials

# Get cluster URLs
make rosa-url
make rosa-console-url
```

### Cleanup

```bash
# Complete cleanup (cluster + infrastructure)
make rosa-cleanup

# Individual cleanup steps
make rosa-cluster-delete #recommended
make rosa-delete-operator-roles
make rosa-delete-oidc-provider
make rosa-delete-domain-records
make rosa-delete-network
```

## Network Architecture

The `network.yaml` template creates:

- **VPC**: 10.0.0.0/16 CIDR block
- **Public Subnets**:
  - 10.0.0.0/24 (AZ-a)
  - 10.0.1.0/24 (AZ-b)
- **Private Subnets**:
  - 10.0.2.0/24 (AZ-a)
  - 10.0.3.0/24 (AZ-b)
- **NAT Gateways**: One per AZ for private subnet internet access
- **Route Tables**: Separate routing for public and private subnets

## Domain Configuration

### A Records (default)
When IP addresses can be resolved, creates A records pointing to cluster IPs:
- `api.${CLUSTER_NAME}.${DOMAIN}` → API endpoint IP
- `*.apps.${CLUSTER_NAME}.${DOMAIN}` → Ingress IP
- `console-openshift-console.apps.${CLUSTER_NAME}.${DOMAIN}` → Ingress IP

### CNAME Records (fallback)
When IP resolution fails, creates CNAME records pointing to original endpoints:
- `api.${CLUSTER_NAME}.${DOMAIN}` → CNAME to API endpoint
- `*.apps.${CLUSTER_NAME}.${DOMAIN}` → CNAME to ingress domain
- `console-openshift-console.apps.${CLUSTER_NAME}.${DOMAIN}` → CNAME to console endpoint

## Troubleshooting

### Common Issues

1. **Subnet ID errors**: Ensure the network stack deployed successfully before creating the cluster
2. **Domain resolution failures**: Script automatically falls back to CNAME records
3. **Permission errors**: Verify AWS IAM permissions for CloudFormation, Route53, and ROSA operations
4. **Region mismatches**: Ensure `ROSA_REGION` matches your AWS CLI default region

### Viewing Stack Status

```bash
# Check network stack status (replace AWS_ACCOUNT_ID with your account ID)
aws cloudformation describe-stacks \
  --stack-name "rosa-network-stack-${AWS_ACCOUNT_ID}" \
  --region ${ROSA_REGION}
