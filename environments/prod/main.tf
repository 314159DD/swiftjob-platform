# Constructed ID instead of a data source: the data source would read the workspace shared keys into state.
locals {
  central_workspace_id = "/subscriptions/${var.subscription_id}/resourceGroups/rg-swiftjob-platform/providers/Microsoft.OperationalInsights/workspaces/log-swiftjob-platform"
}

locals {
  # The warm-replica decision (plan 05 Q5) is a variable of this layer, so it cannot be forgotten in the configuration.
  apps = { for k, a in var.apps : k => merge(a, k == "api" ? { min_replicas = var.min_replicas_api } : {}, k == "web" ? { min_replicas = var.min_replicas_web } : {}) }
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
  apps                       = local.apps
  enable_custom_domains      = var.enable_custom_domains
  key_vault_purge_protection = var.key_vault_purge_protection
  jobs                       = var.jobs
  alerts                     = var.alerts
  postgres                   = var.postgres
  postgres_allowed_skus      = ["B_Standard_B1ms", "B_Standard_B2s"] # ADR 12: B2s once CPU alerts fire
}
