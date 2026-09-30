# Workspace-based Application Insights in the central workspace. Local authentication off: telemetry is only
# accepted with an Entra token of an identity that holds Monitoring Metrics Publisher.
resource "azurerm_application_insights" "this" {
  name                         = "appi-${local.name}"
  location                     = var.location
  resource_group_name          = data.azurerm_resource_group.this.name
  workspace_id                 = var.log_analytics_workspace_id
  application_type             = "web"
  local_authentication_enabled = false
  tags                         = local.tags
}

resource "azurerm_role_assignment" "telemetry" {
  for_each             = toset(var.telemetry_publishers)
  scope                = azurerm_application_insights.this.id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = azurerm_user_assigned_identity.this[each.key].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_monitor_action_group" "email" {
  name                = "ag-${local.name}-email"
  resource_group_name = data.azurerm_resource_group.this.name
  short_name          = "sj${local.env_short}mail"
  location            = "global"
  email_receiver {
    name                    = "owner"
    email_address           = var.alert_email
    use_common_alert_schema = true
  }
  tags = local.tags
}
