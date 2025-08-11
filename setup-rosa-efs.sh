#!/bin/bash

# SPDX-FileCopyrightText: 2024 SAP edge team
#
# SPDX-License-Identifier: Apache-2.0

# Script to enable AWS EFS CSI Driver Operator on ROSA with region-wide EFS
# Based on: https://cloud.redhat.com/experts/rosa/aws-efs/

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    local missing_tools=()

    if ! command -v oc &> /dev/null; then
        missing_tools+=("oc")
    fi

    if ! command -v aws &> /dev/null; then
        missing_tools+=("aws")
    fi

    if ! command -v jq &> /dev/null; then
        missing_tools+=("jq")
    fi

    if ! command -v watch &> /dev/null; then
        missing_tools+=("watch")
    fi

    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_error "Please install the missing tools and try again."
        exit 1
    fi

    # Check if logged into OpenShift
    if ! oc whoami &> /dev/null; then
        log_error "Not logged into OpenShift. Please run 'oc login' first."
        exit 1
    fi

    # Check if logged into AWS
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "Not logged into AWS. Please configure AWS credentials first."
        exit 1
    fi

    log_success "All prerequisites met"
}

# Set up environment variables
setup_environment() {
    log_info "Setting up environment variables..."

    # Get cluster name from environment or prompt
    CLUSTER_NAME="${CLUSTER_NAME:-$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' | sed 's/-[^-]*$//')}"
    if [ -z "${CLUSTER_NAME}" ]; then
        read -r -p "Enter your ROSA cluster name: " CLUSTER_NAME
    fi
    export CLUSTER_NAME

    # Set AWS region
    if [ -z "${AWS_REGION:-}" ]; then
        AWS_REGION="eu-central-1"
        export AWS_REGION
    fi

    # Get OIDC provider
    OIDC_PROVIDER=$(oc get authentication.config.openshift.io cluster -o json \
        | jq -r .spec.serviceAccountIssuer| sed -e "s/^https:\/\///")
    export OIDC_PROVIDER

    # Get AWS account ID
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    export AWS_ACCOUNT_ID

    # Set up scratch directory
    export SCRATCH_DIR=/tmp/scratch
    export AWS_PAGER=""
    mkdir -p $SCRATCH_DIR

    log_success "Environment variables set:"
    log_info "  CLUSTER_NAME: $CLUSTER_NAME"
    log_info "  AWS_REGION: $AWS_REGION"
    log_info "  OIDC_PROVIDER: $OIDC_PROVIDER"
    log_info "  AWS_ACCOUNT_ID: $AWS_ACCOUNT_ID"
}

# Create IAM Policy
create_iam_policy() {
    log_info "Creating IAM policy for EFS CSI Driver..."

    cat << EOF > $SCRATCH_DIR/efs-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "elasticfilesystem:DescribeAccessPoints",
        "elasticfilesystem:DescribeFileSystems",
        "elasticfilesystem:DescribeMountTargets",
        "elasticfilesystem:TagResource",
        "ec2:DescribeAvailabilityZones"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "elasticfilesystem:CreateAccessPoint"
      ],
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "aws:RequestTag/efs.csi.aws.com/cluster": "true"
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": "elasticfilesystem:DeleteAccessPoint",
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/efs.csi.aws.com/cluster": "true"
        }
      }
    }
  ]
}
EOF

    # Create the policy
    POLICY=$(aws iam create-policy --policy-name "${CLUSTER_NAME}-rosa-efs-csi" \
       --policy-document file://$SCRATCH_DIR/efs-policy.json \
       --query 'Policy.Arn' --output text 2>/dev/null) || \
       POLICY=$(aws iam list-policies \
       --query "Policies[?PolicyName==\`${CLUSTER_NAME}-rosa-efs-csi\`].Arn" \
       --output text)

    export POLICY
    log_success "IAM policy created/found: $POLICY"
}

# Create Trust Policy and IAM Role
create_iam_role() {
    log_info "Creating IAM role for EFS CSI Driver..."

    cat <<EOF > $SCRATCH_DIR/TrustPolicy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:sub": [
            "system:serviceaccount:openshift-cluster-csi-drivers:aws-efs-csi-driver-operator",
            "system:serviceaccount:openshift-cluster-csi-drivers:aws-efs-csi-driver-controller-sa"
          ]
        }
      }
    }
  ]
}
EOF

    # Create the role
    ROLE=$(aws iam create-role \
      --role-name "${CLUSTER_NAME}-aws-efs-csi-operator" \
      --assume-role-policy-document file://$SCRATCH_DIR/TrustPolicy.json \
      --query "Role.Arn" --output text 2>/dev/null) || \
      ROLE=$(aws iam get-role \
      --role-name "${CLUSTER_NAME}-aws-efs-csi-operator" \
      --query "Role.Arn" --output text)

    export ROLE
    log_success "IAM role created/found: $ROLE"

    # Attach policy to role
    log_info "Attaching policy to role..."
    aws iam attach-role-policy \
       --role-name "${CLUSTER_NAME}-aws-efs-csi-operator" \
       --policy-arn "$POLICY"
    log_success "Policy attached to role"
}

# Deploy AWS EFS Operator
deploy_efs_operator() {
    log_info "Creating secret for AWS EFS Operator..."

    cat << EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
 name: aws-efs-cloud-credentials
 namespace: openshift-cluster-csi-drivers
stringData:
  credentials: |-
    [default]
    role_arn = $ROLE
    web_identity_token_file = /var/run/secrets/openshift/serviceaccount/token
EOF

    log_success "Secret created"

    log_info "Installing EFS Operator..."

    # Check if OperatorGroup already exists
    if ! oc get operatorgroup -n openshift-cluster-csi-drivers &>/dev/null; then
        log_info "Creating OperatorGroup..."
        cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-cluster-csi-drivers-operatorgroup
  namespace: openshift-cluster-csi-drivers
EOF
    else
        log_info "OperatorGroup already exists"
    fi

    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  labels:
    operators.coreos.com/aws-efs-csi-driver-operator.openshift-cluster-csi-drivers: ""
  name: aws-efs-csi-driver-operator
  namespace: openshift-cluster-csi-drivers
spec:
  channel: stable
  installPlanApproval: Automatic
  name: aws-efs-csi-driver-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

    log_success "EFS Operator installation initiated"

    log_info "Waiting for EFS Operator to be ready..."
    while ! oc get deployment aws-efs-csi-driver-operator -n openshift-cluster-csi-drivers &>/dev/null; do
        log_info "Waiting for operator deployment to be created..."
        sleep 10
    done

    oc wait --for=condition=Available deployment/aws-efs-csi-driver-operator \
        -n openshift-cluster-csi-drivers --timeout=300s
    log_success "EFS Operator is running"
}

# Install AWS EFS CSI Driver
install_csi_driver() {
    log_info "Installing AWS EFS CSI Driver..."

    cat <<EOF | oc apply -f -
apiVersion: operator.openshift.io/v1
kind: ClusterCSIDriver
metadata:
    name: efs.csi.aws.com
spec:
  managementState: Managed
EOF

    log_success "EFS CSI Driver installation initiated"

    log_info "Waiting for CSI driver to be ready..."
    # Wait for the daemonset to be created first
    while ! oc get daemonset aws-efs-csi-driver-node -n openshift-cluster-csi-drivers &>/dev/null; do
        log_info "Waiting for CSI driver daemonset to be created..."
        sleep 10
    done

    # Then wait for it to be ready
    while true; do
        DAEMONSET_STATUS=$(oc get daemonset aws-efs-csi-driver-node -n openshift-cluster-csi-drivers -o json)
        DESIRED=$(echo "$DAEMONSET_STATUS" | jq -r '.status.desiredNumberScheduled')
        READY=$(echo "$DAEMONSET_STATUS" | jq -r '.status.numberReady')

        log_info "Waiting for CSI driver daemonset to be ready (Current: $READY/$DESIRED)..."

        if [ "$DESIRED" = "$READY" ] && [ "$DESIRED" -gt 0 ]; then
            break
        fi
        sleep 10
    done

    oc wait --for=condition=Ready daemonset/aws-efs-csi-driver-node \
        -n openshift-cluster-csi-drivers --timeout=300s
    log_success "EFS CSI Driver is running"
}

# Prepare VPC for EFS
prepare_vpc() {
    log_info "Preparing VPC for EFS access..."

    # Get VPC ID from worker node
    NODE=$(oc get nodes --selector=node-role.kubernetes.io/worker \
      -o jsonpath='{.items[0].metadata.name}')

    VPC=$(aws ec2 describe-instances \
      --filters "Name=private-dns-name,Values=$NODE" \
      --query 'Reservations[*].Instances[*].{VpcId:VpcId}' \
      --region "$AWS_REGION" \
      | jq -r '.[0][0].VpcId')

    export VPC
    log_success "Found VPC: $VPC"

    # Create or get security group for EFS
    SG=$(aws ec2 describe-security-groups \
      --filters "Name=group-name,Values=efs-sg" "Name=vpc-id,Values=$VPC" \
      --query 'SecurityGroups[0].GroupId' \
      --region "$AWS_REGION" --output text 2>/dev/null || echo "None")

    if [ "$SG" = "None" ]; then
        log_info "Creating security group for EFS..."
        SG=$(aws ec2 create-security-group \
          --group-name efs-sg \
          --description "Security group for EFS" \
          --vpc-id "$VPC" \
          --region "$AWS_REGION" \
          --query 'GroupId' --output text)

        # Add NFS rule
        aws ec2 authorize-security-group-ingress \
          --group-id "$SG" \
          --protocol tcp \
          --port 2049 \
          --source-group "$SG" \
          --region "$AWS_REGION"

        log_success "Security group created: $SG"
    else
        log_success "Found existing security group: $SG"
    fi

    export SG
}

# Create region-wide EFS
create_efs() {
    log_info "Creating region-wide EFS File System..."

    EFS=$(aws efs create-file-system --creation-token "efs-token-$(date +%s)" \
       --region "${AWS_REGION}" \
       --encrypted --query 'FileSystemId' --output text 2>/dev/null || \
       aws efs describe-file-systems \
       --query "FileSystems[?CreationToken=='efs-token-1'].FileSystemId" \
       --output text | head -1)

    export EFS
    log_success "EFS File System created/found: $EFS"

    log_info "Waiting for EFS to be available..."
    aws efs wait file-system-available --file-system-id "$EFS" --region "$AWS_REGION"
    log_success "EFS is available"

    log_info "Creating mount targets for region-wide EFS..."

    for SUBNET in $(aws ec2 describe-subnets \
      --filters Name=vpc-id,Values="$VPC" Name='tag:kubernetes.io/role/internal-elb',Values='*' \
      --query 'Subnets[*].{SubnetId:SubnetId}' \
      --region "$AWS_REGION" \
      | jq -r '.[].SubnetId'); do

        # Check if mount target already exists
        EXISTING_MT=$(aws efs describe-mount-targets \
          --file-system-id "$EFS" \
          --region "$AWS_REGION" \
          --query "MountTargets[?SubnetId=='$SUBNET'].MountTargetId" \
          --output text)

        if [ -z "$EXISTING_MT" ]; then
            log_info "Creating mount target in subnet: $SUBNET"
            MOUNT_TARGET=$(aws efs create-mount-target --file-system-id "$EFS" \
               --subnet-id "$SUBNET" --security-groups "$SG" \
               --region "$AWS_REGION" \
               --query 'MountTargetId' --output text)
            log_success "Mount target created: $MOUNT_TARGET"
        else
            log_info "Mount target already exists in subnet $SUBNET: $EXISTING_MT"
        fi
    done

    log_info "Waiting for all mount targets to be available..."
    aws efs wait mount-target-available --file-system-id "$EFS" --region "$AWS_REGION"
    log_success "All mount targets are available"
}

# Create Storage Class
create_storage_class() {
    log_info "Creating Storage Class for EFS volume..."

    cat <<EOF | oc apply -f -
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: $EFS
  directoryPerms: "700"
  gidRangeStart: "1000"
  gidRangeEnd: "2000"
  basePath: "/dynamic_provisioning"
EOF

    log_success "Storage Class created"
}

# Create test resources
create_test_resources() {
    log_info "Creating test namespace and resources..."

    # Create namespace
    oc new-project efs-demo --skip-config-write=true || oc project efs-demo

    log_info "Creating PVC for testing..."

    cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-efs-volume
spec:
  storageClassName: efs-sc
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 5Gi
EOF

    log_success "PVC created"

    log_info "Creating test pod to write to EFS..."

    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
 name: test-efs
spec:
 volumes:
   - name: efs-storage-vol
     persistentVolumeClaim:
       claimName: pvc-efs-volume
 containers:
   - name: test-efs
     image: centos:latest
     command: [ "/bin/bash", "-c", "--" ]
     args: [ "while true; do echo 'hello efs' | tee -a /mnt/efs-data/verify-efs && sleep 5; done;" ]
     volumeMounts:
       - mountPath: "/mnt/efs-data"
         name: efs-storage-vol
EOF

    log_info "Waiting for test pod to be ready..."
    oc wait --for=condition=Ready pod/test-efs --timeout=300s
    log_success "Test pod is ready"

    log_info "Creating test pod to read from EFS..."

    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
 name: test-efs-read
spec:
 volumes:
   - name: efs-storage-vol
     persistentVolumeClaim:
       claimName: pvc-efs-volume
 containers:
   - name: test-efs-read
     image: centos:latest
     command: [ "/bin/bash", "-c", "--" ]
     args: [ "tail -f /mnt/efs-data/verify-efs" ]
     volumeMounts:
       - mountPath: "/mnt/efs-data"
         name: efs-storage-vol
EOF

    log_info "Waiting for read test pod to be ready..."
    oc wait --for=condition=Ready pod/test-efs-read --timeout=300s
    log_success "Read test pod is ready"

    log_info "Verifying EFS functionality..."
    sleep 10

    LOGS=$(oc logs test-efs-read --tail=5)
    if echo "$LOGS" | grep -q "hello efs"; then
        log_success "EFS verification successful! Pods can read and write to the shared volume."
        echo "Sample logs from read pod:"
        echo "$LOGS"
    else
        log_warning "EFS verification inconclusive. Check pod logs manually."
    fi
}

# Print summary
print_summary() {
    log_info "================================================"
    log_success "AWS EFS CSI Driver setup completed successfully!"
    log_info "================================================"
    log_info "Summary of created resources:"
    log_info "  IAM Policy: $POLICY"
    log_info "  IAM Role: $ROLE"
    log_info "  EFS File System: $EFS"
    log_info "  Security Group: $SG"
    log_info "  VPC: $VPC"
    log_info "  Storage Class: efs-sc"
    log_info "  Test Namespace: efs-demo"
    log_info ""
    log_info "To test the EFS setup:"
    log_info "  oc logs test-efs-read -f"
    log_info ""
    log_info "To use EFS in your applications:"
    log_info "  Use storage class 'efs-sc' in your PVC definitions"
    log_info "================================================"
}

# Main execution
main() {
    log_info "Starting AWS EFS CSI Driver setup for ROSA..."

    check_prerequisites
    setup_environment
    create_iam_policy
    create_iam_role
    deploy_efs_operator
    install_csi_driver
    prepare_vpc
    create_efs
    create_storage_class
    create_test_resources
    print_summary

    log_success "Setup completed successfully!"
}

# Run main function
main "$@"
