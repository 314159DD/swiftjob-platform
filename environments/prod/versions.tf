terraform {
  required_version = "~> 1.16"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.7"
    }
  }
  # resource_group_name and storage_account_name come from -backend-config (repository variables).
  backend "azurerm" {
    container_name   = "prod"
    key              = "prod.tfstate"
    use_azuread_auth = true
  }
}
