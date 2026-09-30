# Operations alerts to the e-mail action group (the kill switch group is separate, as in A1).
locals {
  rg_match       = "/resourcegroups/${lower(data.azurerm_resource_group.this.name)}/"
  watch_api      = var.apps_enabled && var.alerts.api_app != null
  missed_watched = var.apps_enabled ? { for k, j in var.jobs : k => j if j.enabled && j.cron != null && j.missed_alert_hours != null } : {}
  # Log alert windows must be PT5M to PT6H, P1D or P2D. The window is the smallest allowed one that covers the
  # requested hours; the query filters the exact hours, so the effective window stays as requested.
  missed_window = { for k, j in local.missed_watched : k => (j.missed_alert_hours <= 6 ? "PT${j.missed_alert_hours}H" : (j.missed_alert_hours <= 24 ? "P1D" : "P2D")) }
}

resource "azurerm_monitor_metric_alert" "api_5xx" {
  count               = local.watch_api ? 1 : 0
  name                = "alert-${local.name}-api-5xx"
  resource_group_name = data.azurerm_resource_group.this.name
  scopes              = [azurerm_container_app.this[var.alerts.api_app].id]
  description         = "More than ${var.alerts.api_5xx_threshold} server errors in 15 minutes."
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"
  criteria {
    metric_namespace = "Microsoft.App/containerApps"
    metric_name      = "Requests"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = var.alerts.api_5xx_threshold
    dimension {
      name     = "statusCodeCategory"
      operator = "Include"
      values   = ["5xx"]
    }
  }
  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
  tags = local.tags
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "api_p95" {
  count                   = local.watch_api ? 1 : 0
  name                    = "alert-${local.name}-api-p95"
  location                = var.location
  resource_group_name     = data.azurerm_resource_group.this.name
  scopes                  = [azurerm_application_insights.this.id]
  description             = "95th percentile request duration above ${var.alerts.api_p95_ms} ms over 15 minutes (at least 10 requests)."
  severity                = 2
  evaluation_frequency    = "PT5M"
  window_duration         = "PT15M"
  auto_mitigation_enabled = true
  criteria {
    query                   = <<-KQL
      requests
      | summarize p95 = percentile(duration, 95), n = count()
      | where n >= 10 and p95 > ${var.alerts.api_p95_ms}
    KQL
    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"
  }
  action {
    action_groups = [azurerm_monitor_action_group.email.id]
  }
  tags = local.tags
}

# Stateless on purpose: one mail per failing window.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "job_failed" {
  count                = var.apps_enabled && length(var.jobs) > 0 ? 1 : 0
  name                 = "alert-${local.name}-job-failed"
  location             = var.location
  resource_group_name  = data.azurerm_resource_group.this.name
  scopes               = [var.log_analytics_workspace_id]
  description          = "A job reported status=failed."
  severity             = 2
  evaluation_frequency = "PT15M"
  window_duration      = "PT15M"
  criteria {
    query                   = <<-KQL
      ContainerAppConsoleLogs
      | where _ResourceId contains "${local.rg_match}"
      | where Log contains "JOB_RESULT " and Log contains "status=failed"
    KQL
    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"
  }
  action {
    action_groups = [azurerm_monitor_action_group.email.id]
  }
  tags = local.tags
}

# No successful run within the window: catches crashes, timeouts and pull failures, which print no result line.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "job_missed" {
  for_each                = local.missed_watched
  name                    = "alert-${local.name}-missed-${each.key}"
  location                = var.location
  resource_group_name     = data.azurerm_resource_group.this.name
  scopes                  = [var.log_analytics_workspace_id]
  description             = "No successful run of ${each.key} in ${each.value.missed_alert_hours} hours."
  severity                = 2
  evaluation_frequency    = "PT1H"
  window_duration         = local.missed_window[each.key]
  auto_mitigation_enabled = true
  criteria {
    query                   = <<-KQL
      ContainerAppConsoleLogs
      | where TimeGenerated > ago(${each.value.missed_alert_hours}h)
      | where _ResourceId contains "${local.rg_match}"
      | where JobName == "job-${var.environment}-${each.key}"
      | where Log contains "JOB_RESULT job=${each.key} " and Log contains "status=ok"
    KQL
    time_aggregation_method = "Count"
    threshold               = 1
    operator                = "LessThan"
  }
  action {
    action_groups = [azurerm_monitor_action_group.email.id]
  }
  tags = local.tags
}
