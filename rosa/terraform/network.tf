# SPDX-FileCopyrightText: 2025 SAP edge team
# SPDX-FileContributor: Kirill Satarin (@kksat)
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-FileContributor: Rishabh Bhandari (@RishabhKodes)

# SPDX-License-Identifier: Apache-2.0

data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.1.2"

  count                = 1
  name                 = var.vpc_name
  cidr                 = var.vpc_cidr
  azs                  = data.aws_availability_zones.available.names
  private_subnets      = var.private_subnets
  public_subnets       = var.public_subnets
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = var.tags

  # Ensure VPC is not destroyed until after ROSA cleanup completes.
  # The time_sleep resource waits for AWS to clean up ROSA-created resources
  # (security groups, ENIs) before allowing VPC deletion.
  depends_on = [time_sleep.wait_for_rosa_cleanup]
}
