data "azurerm_resource_group" "platform" {
  name = "rg-swiftjob-platform" # created by scripts/bootstrap.sh
}

# One workspace for every environment's diagnostics (DeployIfNotExists policies point here).
resource "azurerm_log_analytics_workspace" "central" {
  name                         = "log-swiftjob-platform"
  location                     = var.location
  resource_group_name          = data.azurerm_resource_group.platform.name
  sku                          = "PerGB2018"
  retention_in_days            = 30
  daily_quota_gb               = var.log_daily_quota_gb
  local_authentication_enabled = false
  tags                         = local.tags
}
