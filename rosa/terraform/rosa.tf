# SPDX-FileCopyrightText: 2025 SAP edge team
# SPDX-FileContributor: Kirill Satarin (@kksat)
# SPDX-FileContributor: Manjun Jiao (@mjiao)
#
# SPDX-License-Identifier: Apache-2.0

module "rosa-hcp" {
  source  = "terraform-redhat/rosa-hcp/rhcs"
  version = "1.6.2"

  cluster_name           = var.cluster_name
  openshift_version      = var.rosa_version
  machine_cidr           = module.vpc[0].vpc_cidr_block
  aws_subnet_ids         = concat(module.vpc[0].private_subnets, module.vpc[0].public_subnets)
  aws_availability_zones = slice(data.aws_availability_zones.available.names, 0, 3)
  replicas               = 3
  compute_machine_type   = var.compute_machine_type

  # IAM Role Configuration
  # Account roles: Pre-existing (created once per AWS account with rosa CLI)
  #   rosa create account-roles --prefix ManagedOpenShift --mode auto --yes
  #
  # OIDC + Operator roles: Created per cluster (cluster-specific)
  # These are created/destroyed with each cluster deployment
  create_account_roles  = var.create_account_roles
  account_role_prefix   = var.account_role_prefix
  create_oidc           = var.create_oidc
  oidc_config_id        = var.oidc_config_id
  create_operator_roles = var.create_operator_roles
  operator_role_prefix  = var.operator_role_prefix != "" ? var.operator_role_prefix : var.cluster_name
}

# Wait for AWS to complete async cleanup of ROSA-created resources (security groups, ENIs)
# before allowing VPC destruction. ROSA creates resources in the VPC that are not managed
# by Terraform, and AWS needs time to clean them up after the cluster is deleted.
resource "time_sleep" "wait_for_rosa_cleanup" {
  destroy_duration = "5m"

  depends_on = [module.rosa-hcp]
}
