-include .env

# Set default values if not provided in .env
ROSA_TOKEN?=
ROSA_REGION?=eu-central-1
ROSA_VERSION?=4.19.2
ROSA_WORKER_MACHINE_TYPE?=m5.xlarge
ROSA_WORKER_REPLICAS?=10
ROSA_DOMAIN?=
ROSA_SUBNET_IDS?=
ROSA_AVAILABILITY_ZONES?=
CLUSTER_ADMIN_PASSWORD?=$(shell openssl rand -base64 12)
CLUSTER_NAME?=sapeic-cluster


.PHONY: rosa-login
rosa-login:  ## Login using ROSA token
	$(call required-environment-variables,ROSA_TOKEN)
	@rosa login --token="${ROSA_TOKEN}"
	@rosa create account-roles --mode auto

.PHONY: rosa-init
rosa-init:  ## ROSA init
	rosa init

.PHONY: rosa-operator-roles
rosa-operator-roles:  ## Create ROSA operator roles for cluster
	$(call required-environment-variables,CLUSTER_NAME)
	rosa create operator-roles --cluster "${CLUSTER_NAME}" --mode auto

.PHONY: rosa-oidc-provider
rosa-oidc-provider:  ## Create OIDC provider for cluster
	$(call required-environment-variables,CLUSTER_NAME)
	rosa create oidc-provider --cluster "${CLUSTER_NAME}" --mode auto

.PHONY: rosa-domain-zone-exists
rosa-domain-zone-exists:  ## Fail if Route53 hosted zone does not exist
	$(call required-environment-variables,ROSA_DOMAIN)
	ROSA_DOMAIN=${ROSA_DOMAIN} rosa/rosa-domain-zone-exists.sh

.PHONY: rosa-deploy
rosa-deploy: rosa-domain-zone-exists rosa-network-deploy rosa-account-roles rosa-cluster rosa-operator-roles rosa-oidc-provider  ## Deploy ROSA cluster with all dependencies
	$(info ROSA cluster deployment complete)

.PHONY: rosa-cluster
rosa-cluster:  ## Create ROSA cluster
	$(call required-environment-variables,ROSA_TOKEN CLUSTER_NAME)
	@if [ -z "${ROSA_SUBNET_IDS}" ]; then \
		PRIVATE_SUBNETS=$$(cd rosa/terraform && terraform output -raw private_subnets 2>/dev/null || echo ""); \
		PUBLIC_SUBNETS=$$(cd rosa/terraform && terraform output -raw public_subnets 2>/dev/null || echo ""); \
		if [ -n "$$PRIVATE_SUBNETS" ] && [ -n "$$PUBLIC_SUBNETS" ]; then \
			ALL_SUBNETS="$$PRIVATE_SUBNETS,$$PUBLIC_SUBNETS"; \
			echo "Using subnets from Terraform outputs: $$ALL_SUBNETS"; \
			rosa create cluster --cluster-name "${CLUSTER_NAME}" \
				--region "${ROSA_REGION}" \
				--version "${ROSA_VERSION}" \
				--subnet-ids "$$ALL_SUBNETS" \
				--machine-cidr "10.0.0.0/16" \
				--service-cidr "172.30.0.0/16" \
				--pod-cidr "10.128.0.0/14" \
				$(if ${ROSA_WORKER_MACHINE_TYPE},--compute-machine-type "${ROSA_WORKER_MACHINE_TYPE}") \
				$(if ${ROSA_WORKER_REPLICAS},--replicas ${ROSA_WORKER_REPLICAS}) \
				--host-prefix "23" \
				$(if ${PULL_SECRET},--pull-secret-file "${PULL_SECRET}") \
				--sts --mode auto; \
		else \
			echo "No subnet IDs found from Terraform, creating cluster with default networking"; \
			rosa create cluster --cluster-name "${CLUSTER_NAME}" \
				--region "${ROSA_REGION}" \
				--version "${ROSA_VERSION}" \
				--machine-cidr "10.0.0.0/16" \
				--service-cidr "172.30.0.0/16" \
				--pod-cidr "10.128.0.0/14" \
				$(if ${ROSA_WORKER_MACHINE_TYPE},--compute-machine-type "${ROSA_WORKER_MACHINE_TYPE}") \
				$(if ${ROSA_WORKER_REPLICAS},--replicas ${ROSA_WORKER_REPLICAS}) \
				--host-prefix "23" \
				$(if ${PULL_SECRET},--pull-secret-file "${PULL_SECRET}") \
				--sts --mode auto; \
		fi; \
	else \
		echo "Using provided subnet IDs: ${ROSA_SUBNET_IDS}"; \
		rosa create cluster --cluster-name "${CLUSTER_NAME}" \
			--region "${ROSA_REGION}" \
			--version "${ROSA_VERSION}" \
			--subnet-ids "${ROSA_SUBNET_IDS}" \
			--machine-cidr "10.0.0.0/16" \
			--service-cidr "172.30.0.0/16" \
			--pod-cidr "10.128.0.0/14" \
			$(if ${ROSA_WORKER_MACHINE_TYPE},--compute-machine-type "${ROSA_WORKER_MACHINE_TYPE}") \
			$(if ${ROSA_WORKER_REPLICAS},--replicas ${ROSA_WORKER_REPLICAS}) \
			--host-prefix "23" \
			$(if ${ROSA_AVAILABILITY_ZONES},--availability-zones "${ROSA_AVAILABILITY_ZONES}") \
			$(if ${PULL_SECRET},--pull-secret-file "${PULL_SECRET}") \
			--sts --mode auto; \
	fi

.PHONY: rosa-cluster-status
rosa-cluster-status:  ## Get ROSA cluster status
	$(call required-environment-variables,ROSA_TOKEN CLUSTER_NAME)
	rosa describe cluster --cluster "${CLUSTER_NAME}"

.PHONY: rosa-cluster-delete
rosa-cluster-delete:  ## Delete ROSA cluster
	$(call required-environment-variables,ROSA_TOKEN CLUSTER_NAME)
	rosa delete cluster --cluster "${CLUSTER_NAME}" --yes

.PHONY: rosa-cluster-admin
rosa-cluster-admin:  ## Create cluster admin
	$(call required-environment-variables,CLUSTER_NAME)
	@echo "Creating cluster admin credentials..."
	@if rosa describe admin --cluster "${CLUSTER_NAME}" >/dev/null 2>&1; then \
		echo "Existing admin user found. Deleting it first..."; \
		rosa delete admin --cluster "${CLUSTER_NAME}" --yes >/dev/null 2>&1; \
		echo "Waiting for admin deletion to complete..."; \
		sleep 5; \
	fi
	@rosa create admin --cluster "${CLUSTER_NAME}" --password "${CLUSTER_ADMIN_PASSWORD}" >/dev/null
	@echo "\nCluster admin credentials created successfully!"
	@echo "Username: kubeadmin"
	@echo "Password: ${CLUSTER_ADMIN_PASSWORD}"
	@echo "\nYou can use these credentials to log in to the cluster console or with 'oc login'"

.PHONY: rosa-credentials
rosa-credentials:  ## Get ROSA cluster credentials
	$(call required-environment-variables,ROSA_TOKEN CLUSTER_NAME)
	@rosa describe admin --cluster=${CLUSTER_NAME}

.PHONY: rosa-kubeconfig
rosa-kubeconfig:  ## Get ROSA kubeconfig file
	$(call required-environment-variables,ROSA_TOKEN CLUSTER_NAME)
	@echo "Logging in to ROSA..."
	@rosa login --token="${ROSA_TOKEN}"
	@echo "Setting up kubeconfig for cluster ${CLUSTER_NAME}..."
	@API_URL=$$(rosa describe cluster --cluster "${CLUSTER_NAME}" --output json | jq -r '.api.url') && \
	if [ -n "$$API_URL" ] && [ "$$API_URL" != "null" ]; then \
		echo "API URL: $$API_URL"; \
		ROSA_LOGIN_TOKEN=$$(rosa token) && \
		oc login "$$API_URL" --token="$$ROSA_LOGIN_TOKEN" && \
		echo "Successfully configured kubeconfig for cluster ${CLUSTER_NAME}"; \
	else \
		echo "Error: Could not retrieve API URL for cluster ${CLUSTER_NAME}"; \
		echo "Make sure the cluster exists and is in a ready state"; \
		exit 1; \
	fi

.PHONY: rosa-url
rosa-url:  ## Get ROSA cluster URL
	$(call required-environment-variables,ROSA_TOKEN CLUSTER_NAME)
	@rosa describe cluster --cluster "${CLUSTER_NAME}" --output json | jq -r '.api.url'

.PHONY: rosa-console-url
rosa-console-url:  ## Get ROSA console URL
	$(call required-environment-variables,ROSA_TOKEN CLUSTER_NAME)
	@rosa describe cluster --cluster "${CLUSTER_NAME}" --output json | jq -r '.console.url'

.PHONY: rosa-network-deploy
rosa-network-deploy:  ## Deploy VPC and subnets for ROSA using Terraform
	$(call required-environment-variables,ROSA_REGION CLUSTER_NAME)
	@echo "Deploying VPC and subnets for ROSA cluster using Terraform..."
	@cd rosa/terraform && \
	cat > network.tfvars <<-EOF && \
		aws_region = "${ROSA_REGION}" \
		cluster_name = "${CLUSTER_NAME}" \
		vpc_name = "rosa-${CLUSTER_NAME}-vpc" \
		environment_tag = "rosa" \
		vpc_cidr = "10.0.0.0/16" \
		public_subnet_1_cidr = "10.0.0.0/24" \
		public_subnet_2_cidr = "10.0.1.0/24" \
		private_subnet_1_cidr = "10.0.2.0/24" \
		private_subnet_2_cidr = "10.0.3.0/24" \
	EOF \
	terraform init && \
	terraform plan -var-file=network.tfvars && \
	terraform apply -var-file=network.tfvars -auto-approve
	$(info VPC and subnets deployed for ROSA cluster using Terraform)

.PHONY: rosa-oc-login
rosa-oc-login:  ## Login with oc to existing ROSA cluster
	$(call required-environment-variables,CLUSTER_NAME)
	@API_URL=$$(rosa describe cluster --cluster "${CLUSTER_NAME}" --output json | jq -r '.api.url') && \
	ADMIN_USER=$$(rosa describe admin --cluster "${CLUSTER_NAME}" | grep "Admin Username" | awk '{print $$3}') && \
	ADMIN_PASS=$$(rosa describe admin --cluster "${CLUSTER_NAME}" | grep "Admin Password" | awk '{print $$3}') && \
	oc login "$$API_URL" -u "$$ADMIN_USER" -p "$$ADMIN_PASS"

.PHONY: rosa-domain-records
rosa-domain-records:  ## Create domain records for ROSA using Terraform
	$(call required-environment-variables,CLUSTER_NAME ROSA_DOMAIN)
	rosa/terraform-domain-records.sh \
		--domain ${ROSA_DOMAIN} \
		--rosa-name ${CLUSTER_NAME}

.PHONY: rosa-delete-operator-roles
rosa-delete-operator-roles:  ## Delete ROSA operator roles
	$(call required-environment-variables,CLUSTER_NAME)
	rosa delete operator-roles --cluster "${CLUSTER_NAME}" --mode auto --yes

.PHONY: rosa-delete-oidc-provider
rosa-delete-oidc-provider:  ## Delete OIDC provider
	$(call required-environment-variables,CLUSTER_NAME)
	rosa delete oidc-provider --cluster "${CLUSTER_NAME}" --mode auto --yes

.PHONY: rosa-delete-domain-records
rosa-delete-domain-records:  ## Delete domain records using Terraform
	$(call required-environment-variables,CLUSTER_NAME)
	@cd rosa/terraform && \
	if [ -f terraform.tfvars ]; then \
		terraform destroy -var-file=terraform.tfvars -auto-approve || true; \
	fi
	$(info Domain records destruction completed)

.PHONY: rosa-delete-network
rosa-delete-network:  ## Delete network using Terraform
	$(call required-environment-variables,CLUSTER_NAME)
	@cd rosa/terraform && \
	if [ -f network.tfvars ]; then \
		terraform destroy -var-file=network.tfvars -auto-approve || true; \
	fi
	$(info Network destruction completed)

.PHONY: rosa-cleanup
rosa-cleanup: rosa-cluster-delete rosa-delete-operator-roles rosa-delete-oidc-provider rosa-delete-domain-records rosa-delete-network  ## Complete cleanup of ROSA cluster and resources
	$(info ROSA cluster and associated resources cleanup complete)

.PHONY: rosa-create-token
rosa-create-token:  ## Create authentication token for ROSA cluster
	@rosa token

.PHONY: rosa-machine-pools
rosa-machine-pools:  ## List machine pools for ROSA cluster
	$(call required-environment-variables,CLUSTER_NAME)
	rosa list machine-pools --cluster "${CLUSTER_NAME}"

.PHONY: rosa-ingress
rosa-ingress:  ## List ingress for ROSA cluster
	$(call required-environment-variables,CLUSTER_NAME)
	rosa list ingress --cluster "${CLUSTER_NAME}"

.PHONY: rosa-identity-providers
rosa-identity-providers:  ## List identity providers for ROSA cluster
	$(call required-environment-variables,CLUSTER_NAME)
	rosa list identity-providers --cluster "${CLUSTER_NAME}"

# TODO: Add EFS configuration script/target for ROSA cluster.

# Terraform-specific targets
.PHONY: rosa-terraform-init
rosa-terraform-init:  ## Initialize Terraform in rosa/terraform directory
	@echo "Initializing Terraform..."
	@cd rosa/terraform && terraform init

.PHONY: rosa-terraform-plan
rosa-terraform-plan:  ## Run terraform plan with network configuration
	$(call required-environment-variables,ROSA_REGION CLUSTER_NAME)
	@cd rosa/terraform && \
	cat > network.tfvars <<-EOF && \
		aws_region = "${ROSA_REGION}" \
		cluster_name = "${CLUSTER_NAME}" \
		vpc_name = "rosa-${CLUSTER_NAME}-vpc" \
		environment_tag = "rosa" \
		vpc_cidr = "10.0.0.0/16" \
		public_subnet_1_cidr = "10.0.0.0/24" \
		public_subnet_2_cidr = "10.0.1.0/24" \
		private_subnet_1_cidr = "10.0.2.0/24" \
		private_subnet_2_cidr = "10.0.3.0/24" \
	EOF \
	terraform plan -var-file=network.tfvars

.PHONY: rosa-terraform-output
rosa-terraform-output:  ## Show terraform outputs
	@cd rosa/terraform && terraform output

.PHONY: rosa-terraform-state
rosa-terraform-state:  ## Show terraform state
	@cd rosa/terraform && terraform state list

.PHONY: rosa-terraform-validate
rosa-terraform-validate:  ## Validate Terraform configuration
	@cd rosa/terraform && terraform validate

.PHONY: rosa-terraform-fmt
rosa-terraform-fmt:  ## Format Terraform files
	@cd rosa/terraform && terraform fmt

.PHONY: rosa-terraform-clean
rosa-terraform-clean:  ## Clean Terraform working directory (remove .terraform and tfvars)
	@echo "Cleaning Terraform working directory..."
	@cd rosa/terraform && \
	rm -rf .terraform .terraform.lock.hcl *.tfvars *.tfplan
	$(info Terraform working directory cleaned)
