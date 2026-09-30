data "azurerm_log_analytics_workspace" "central" {
  name                = "log-swiftjob-platform"
  resource_group_name = "rg-swiftjob-platform"
}

module "workload" {
  source                     = "../../modules/workload"
  environment                = var.environment
  resource_group_name        = var.resource_group_name
  log_analytics_workspace_id = data.azurerm_log_analytics_workspace.central.id
  identities                 = var.identities
  blob_containers            = var.blob_containers
  telemetry_publishers       = var.telemetry_publishers
  budget_amount              = var.budget_amount
  budget_start_date          = var.budget_start_date
  alert_email                = var.alert_email
}
