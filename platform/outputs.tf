output "management_group_ids" {
  description = "Management group IDs by short name."
  value = {
    root      = azurerm_management_group.root.id
    platform  = azurerm_management_group.platform.id
    workloads = azurerm_management_group.workloads.id
    prod      = azurerm_management_group.prod.id
    nonprod   = azurerm_management_group.nonprod.id
    sandbox   = azurerm_management_group.sandbox.id
  }
}

output "log_analytics_workspace_id" {
  description = "Central workspace for diagnostics."
  value       = azurerm_log_analytics_workspace.central.id
}
