provider "azurerm" {
  features {}
  subscription_id                 = var.subscription_id
  resource_provider_registrations = "none" # registered once by scripts/bootstrap.sh
  storage_use_azuread             = true
}
