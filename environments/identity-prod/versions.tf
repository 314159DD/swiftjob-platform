terraform {
  required_version = "~> 1.16"
  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.10"
    }
  }
  # resource_group_name and storage_account_name come from -backend-config (repository variables). The backend signs in
  # with the workforce identity of the job (ARM_*); the azuread provider signs in to the production external tenant
  # (providers.tf).
  backend "azurerm" {
    container_name   = "prod"
    key              = "identity-prod.tfstate"
    use_azuread_auth = true
  }
}
