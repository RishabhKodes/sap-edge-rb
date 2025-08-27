# SPDX-FileCopyrightText: 2024 SAP edge team
# SPDX-License-Identifier: Apache-2.0

# Domain Records Outputs (conditional)
output "api_endpoint" {
  description = "API endpoint DNS name"
  value       = var.domain_name != "" ? "api.${var.cluster_name}.${var.domain_name}" : ""
}

output "console_endpoint" {
  description = "Console endpoint DNS name"
  value       = var.domain_name != "" ? "console-openshift-console.apps.${var.cluster_name}.${var.domain_name}" : ""
}

output "cluster_name" {
  description = "Name of the ROSA HCP cluster"
  value       = var.cluster_name
}

output "admin_credentials" {
  description = "Admin credentials for the cluster (if created)"
  value = var.create_admin_user ? {
    username = var.admin_username
    password = var.admin_password != "" ? "(set via variable)" : "(auto-generated - check Terraform state)"
  } : null
  sensitive = true
}
