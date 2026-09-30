# Secrets are referenced by the container apps through their identities. Terraform creates the vault and the
# role assignments only; secret values are set by the owner with a script (spec 3, decision 3).
# The vault holds no state that is not recreatable: secret values are reloaded by script, and rebuilt or throwaway
# environments must be removable (see the Checkov skips below).
# tflint-ignore: azurerm_resources_missing_prevent_destroy
resource "azurerm_key_vault" "this" {
  #checkov:skip=CKV_AZURE_42:Purge protection off so a throwaway or rebuilt environment can be removed; production decides in plan 05
  #checkov:skip=CKV_AZURE_110:Same as CKV_AZURE_42
  #checkov:skip=CKV_AZURE_109:No network rules before revenue (ADR 6, variant C); access needs an Entra token and a role
  #checkov:skip=CKV_AZURE_189:Public network access by design until the VNet switch (ADR 6)
  #checkov:skip=CKV2_AZURE_32:No private endpoint before revenue (ADR 6); private endpoints are denied by policy
  name                          = "kv-swiftjob-${local.env_short}-${local.suffix}"
  location                      = var.location
  resource_group_name           = data.azurerm_resource_group.this.name
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  purge_protection_enabled      = false
  soft_delete_retention_days    = 7
  public_network_access_enabled = true
  tags                          = local.tags
}
