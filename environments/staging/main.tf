# Constructed ID instead of a data source: the data source would read the workspace shared keys into state.
locals {
  central_workspace_id = "/subscriptions/${var.subscription_id}/resourceGroups/rg-swiftjob-platform/providers/Microsoft.OperationalInsights/workspaces/log-swiftjob-platform"
}

module "workload" {
  source                     = "../../modules/workload"
  environment                = var.environment
  resource_group_name        = var.resource_group_name
  compute_location           = var.compute_location
  log_analytics_workspace_id = local.central_workspace_id
  identities                 = var.identities
  blob_containers            = var.blob_containers
  telemetry_publishers       = var.telemetry_publishers
  budget_amount              = var.budget_amount
  budget_start_date          = var.budget_start_date
  alert_email                = var.alert_email
  apps_enabled               = var.apps_enabled
  images                     = var.images
  registry                   = var.registry
  secrets                    = var.secrets
  apps                       = var.apps
  jobs                       = var.jobs
  alerts                     = var.alerts
}
