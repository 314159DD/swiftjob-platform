# Container Apps environment with workload profiles, Consumption only and without a custom VNet (ADR 6):
# no load balancer, no public IPs, no environment management fee.
# logs_destination "log-analytics" would need the workspace shared key; the central workspace has local
# authentication off, so the environment logs to Azure Monitor and a diagnostic setting (Entra) forwards them.
resource "azurerm_container_app_environment" "this" {
  name                = "cae-${local.name}"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.this.name
  logs_destination    = "azure-monitor"
  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
  tags = local.tags
}

resource "azurerm_monitor_diagnostic_setting" "environment" {
  name                           = "to-central-workspace"
  target_resource_id             = azurerm_container_app_environment.this.id
  log_analytics_workspace_id     = var.log_analytics_workspace_id
  log_analytics_destination_type = "Dedicated"
  enabled_log {
    category = "ContainerAppConsoleLogs"
  }
  enabled_log {
    category = "ContainerAppSystemLogs"
  }
}
