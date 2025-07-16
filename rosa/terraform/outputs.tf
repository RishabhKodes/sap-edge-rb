# SPDX-FileCopyrightText: 2024 SAP edge team
# SPDX-License-Identifier: Apache-2.0

# Network Outputs
output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnets" {
  description = "Comma-separated list of public subnet IDs"
  value       = "${aws_subnet.public_1.id},${aws_subnet.public_2.id}"
}

output "private_subnets" {
  description = "Comma-separated list of private subnet IDs"
  value       = "${aws_subnet.private_1.id},${aws_subnet.private_2.id}"
}

output "public_subnet_ids" {
  description = "List of public subnet IDs"
  value       = [aws_subnet.public_1.id, aws_subnet.public_2.id]
}

output "private_subnet_ids" {
  description = "List of private subnet IDs"
  value       = [aws_subnet.private_1.id, aws_subnet.private_2.id]
}

output "all_subnet_ids" {
  description = "List of all subnet IDs"
  value       = [
    aws_subnet.public_1.id,
    aws_subnet.public_2.id,
    aws_subnet.private_1.id,
    aws_subnet.private_2.id
  ]
}

output "availability_zones" {
  description = "List of availability zones used"
  value       = [
    aws_subnet.public_1.availability_zone,
    aws_subnet.public_2.availability_zone
  ]
}

# Domain Records Outputs (conditional)
output "api_endpoint" {
  description = "API endpoint DNS name"
  value       = var.domain_name != "" ? "api.${var.cluster_name}.${var.domain_name}" : ""
}

output "apps_wildcard" {
  description = "Apps wildcard DNS name"
  value       = var.domain_name != "" ? "*.apps.${var.cluster_name}.${var.domain_name}" : ""
}

output "console_endpoint" {
  description = "Console endpoint DNS name"
  value       = var.domain_name != "" ? "console-openshift-console.apps.${var.cluster_name}.${var.domain_name}" : ""
}

output "hosted_zone" {
  description = "Route53 hosted zone name"
  value       = var.domain_name
}
