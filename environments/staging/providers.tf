provider "azurerm" {
  features {
    # tf-staging lacks subscription-level deletedVaults rights; rebuilds use name_salt instead of purge or recover.
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = false
    }
  }
  subscription_id                 = var.subscription_id
  resource_provider_registrations = "none" # registered once by scripts/bootstrap.sh
  storage_use_azuread             = true
}
