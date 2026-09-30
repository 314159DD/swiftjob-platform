# Uploaded files in blob storage, reached only with Entra tokens: shared keys off, no anonymous access.
# Staging and throwaway environments must be removable; production decides on prevent_destroy in plan 05.
# tflint-ignore: azurerm_resources_missing_prevent_destroy
resource "azurerm_storage_account" "this" {
  #checkov:skip=CKV_AZURE_33:No queues are used
  #checkov:skip=CKV_AZURE_59:Public network access by design until the VNet switch (ADR 6); every request needs an Entra token
  #checkov:skip=CKV_AZURE_35:Same as CKV_AZURE_59
  #checkov:skip=CKV_AZURE_206:LRS is enough before revenue; the source of truth for uploaded files is the user
  #checkov:skip=CKV2_AZURE_1:Microsoft-managed keys; customer-managed keys cost a Key Vault key and operations
  #checkov:skip=CKV2_AZURE_33:No private endpoint before revenue (ADR 6)
  #checkov:skip=CKV2_AZURE_41:No SAS in phase 2 (shared keys are off); user delegation SAS comes with plan 04
  name                            = "stswiftjob${local.env_short}${local.suffix}"
  location                        = var.location
  resource_group_name             = data.azurerm_resource_group.this.name
  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  allow_nested_items_to_be_public = false
  public_network_access           = "Enabled"
  blob_properties {
    delete_retention_policy {
      days = 7
    }
    container_delete_retention_policy {
      days = 7
    }
  }
  tags = local.tags
}

resource "azurerm_storage_container" "this" {
  #checkov:skip=CKV2_AZURE_21:Blob logging goes through the diagnostics policy of the platform layer
  for_each              = var.blob_containers
  name                  = each.key
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

locals {
  blob_grants = merge([
    for c, v in var.blob_containers : {
      for id, role in v.access : "${c}-${id}" => { container = c, identity = id, role = role }
    }
  ]...)
}

resource "azurerm_role_assignment" "blob" {
  for_each             = local.blob_grants
  scope                = "${azurerm_storage_account.this.id}/blobServices/default/containers/${each.value.container}"
  role_definition_name = each.value.role
  principal_id         = azurerm_user_assigned_identity.this[each.value.identity].principal_id
  principal_type       = "ServicePrincipal"
  depends_on           = [azurerm_storage_container.this]
}
