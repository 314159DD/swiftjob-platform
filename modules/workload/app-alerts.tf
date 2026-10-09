# Application alerts on the backend's log lines and request telemetry (the infrastructure alerts are in alerts.tf and
# postgres.tf). Quiet by default: 15-minute evaluation, auto-mitigation, thresholds per environment in var.alerts.
# Console lines land in the ContainerAppConsoleLogs table of the central workspace (column Log); the queries filter the
# environment's resource group through _ResourceId, like the job alerts, and parse the fields out of Log.
locals {
  watch_logs = var.apps_enabled && var.alerts.log_alerts

  # Short route labels of the request names ("GET /api/scan/<run_id>/events") and their p95 limits in milliseconds.
  route_limits = {
    scan_events    = var.alerts.route_p95_ms.scan_events
    titles_suggest = var.alerts.route_p95_ms.titles_suggest
    onboarding     = var.alerts.route_p95_ms.onboarding
  }
  # KQL: request name to route label; "" for every other route
  route_case       = "case(name has \"/api/scan/\" and name has \"/events\", \"scan_events\", name has \"/api/titles/suggest\", \"titles_suggest\", name has \"/api/onboarding/\", \"onboarding\", \"\")"
  route_limit_case = "case(route == \"scan_events\", ${local.route_limits.scan_events}, route == \"titles_suggest\", ${local.route_limits.titles_suggest}, ${local.route_limits.onboarding})"
}

# LLM_CALL model=<id> purpose=<name> ok=<true|false> status=<code or exception class> fallback=<true|false> took_ms=<n>
# A primary model failing without a fallback is the dead-model case: the call dies into the error path.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "llm_primary_failures" {
  count                   = local.watch_logs ? 1 : 0
  name                    = "alert-${local.name}-llm-primary-failures"
  location                = var.location
  resource_group_name     = data.azurerm_resource_group.this.name
  scopes                  = [var.log_analytics_workspace_id]
  description             = "More than ${var.alerts.llm_failures_per_hour} LLM calls per hour failed for one model without a fallback (LLM_CALL ok=false fallback=false)."
  severity                = 2
  evaluation_frequency    = "PT15M"
  window_duration         = "PT1H"
  auto_mitigation_enabled = true
  criteria {
    query                   = <<-KQL
      ContainerAppConsoleLogs
      | where _ResourceId contains "${local.rg_match}"
      | where Log contains "LLM_CALL" and Log contains "ok=false" and Log contains "fallback=false"
      | extend model = extract(@"model=(\S+)", 1, Log)
    KQL
    time_aggregation_method = "Count"
    threshold               = var.alerts.llm_failures_per_hour
    operator                = "GreaterThan"
    dimension {
      name     = "model"
      operator = "Include"
      values   = ["*"]
    }
  }
  action {
    action_groups = [azurerm_monitor_action_group.email.id]
  }
  tags = local.tags
}

# 401 or 402 from the provider means a revoked key or an empty credit balance: every call fails until someone acts, so
# this is critical and evaluated every 5 minutes (about 1.32 EUR per month instead of 0.44 EUR at 15 minutes).
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "llm_auth_or_credit" {
  count                   = local.watch_logs ? 1 : 0
  name                    = "alert-${local.name}-llm-auth-or-credit"
  location                = var.location
  resource_group_name     = data.azurerm_resource_group.this.name
  scopes                  = [var.log_analytics_workspace_id]
  description             = "An LLM call was answered with HTTP 401 or 402: the provider key is invalid or out of credit."
  severity                = 1
  evaluation_frequency    = "PT5M"
  window_duration         = "PT15M"
  auto_mitigation_enabled = true
  criteria {
    query                   = <<-KQL
      ContainerAppConsoleLogs
      | where _ResourceId contains "${local.rg_match}"
      | where Log contains "LLM_CALL" and Log contains "ok=false"
      | where Log matches regex @"status=40[12](\s|$)"
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

# SCAN_TIMING is printed by the backend at the end of every scan (also after an exception), with trigger=onboarding for
# the first scan of a new user. A run that did not end ok, or that ended ok with matched=0, is a new user who sees nothing.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "first_scan_bad" {
  count                   = local.watch_logs ? 1 : 0
  name                    = "alert-${local.name}-first-scan-bad"
  location                = var.location
  resource_group_name     = data.azurerm_resource_group.this.name
  scopes                  = [var.log_analytics_workspace_id]
  description             = "More than ${var.alerts.first_scan_failures_per_hour} first scans per hour ended without matches or with a failure (SCAN_TIMING trigger=onboarding)."
  severity                = 2
  evaluation_frequency    = "PT15M"
  window_duration         = "PT1H"
  auto_mitigation_enabled = true
  criteria {
    query                   = <<-KQL
      ContainerAppConsoleLogs
      | where _ResourceId contains "${local.rg_match}"
      | where Log contains "SCAN_TIMING" and Log contains "trigger=onboarding"
      | extend status = extract(@"status=(\S+)", 1, Log), matched = toint(extract(@"matched=(-?\d+)", 1, Log))
      | where status != "ok" or matched == 0
    KQL
    time_aggregation_method = "Count"
    threshold               = var.alerts.first_scan_failures_per_hour
    operator                = "GreaterThan"
  }
  action {
    action_groups = [azurerm_monitor_action_group.email.id]
  }
  tags = local.tags
}

# The ranking step gave up after its retry: the scan continues without a ranking and new users get no matches.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "ranking_timeout" {
  count                   = local.watch_logs ? 1 : 0
  name                    = "alert-${local.name}-ranking-timeout"
  location                = var.location
  resource_group_name     = data.azurerm_resource_group.this.name
  scopes                  = [var.log_analytics_workspace_id]
  description             = "The ranking timed out twice in a scan."
  severity                = 2
  evaluation_frequency    = "PT15M"
  window_duration         = "PT15M"
  auto_mitigation_enabled = true
  criteria {
    query                   = <<-KQL
      ContainerAppConsoleLogs
      | where _ResourceId contains "${local.rg_match}"
      | where Log contains "ranking timed out twice"
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

# Request telemetry (Application Insights, OpenTelemetry): p95 of the routes users wait on, one alert per route. The
# polling route stalled for 70 s once; at least 5 requests in the window keep a single slow call from alerting.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "route_p95" {
  count                   = local.watch_api ? 1 : 0
  name                    = "alert-${local.name}-route-p95"
  location                = var.location
  resource_group_name     = data.azurerm_resource_group.this.name
  scopes                  = [azurerm_application_insights.this.id]
  description             = "95th percentile above the limit on a key route over 15 minutes: scan events ${local.route_limits.scan_events} ms, title suggest ${local.route_limits.titles_suggest} ms, onboarding ${local.route_limits.onboarding} ms (at least 5 requests)."
  severity                = 2
  evaluation_frequency    = "PT15M"
  window_duration         = "PT15M"
  auto_mitigation_enabled = true
  criteria {
    query                   = <<-KQL
      requests
      | extend route = ${local.route_case}
      | where route != ""
      | summarize p95 = percentile(duration, 95), n = count() by route
      | where n >= 5 and p95 > ${local.route_limit_case}
    KQL
    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"
    dimension {
      name     = "route"
      operator = "Include"
      values   = ["*"]
    }
  }
  action {
    action_groups = [azurerm_monitor_action_group.email.id]
  }
  tags = local.tags
}

# Server errors on the key routes only; the app-wide 5xx metric alert in alerts.tf has the higher threshold.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "route_5xx" {
  count                   = local.watch_api ? 1 : 0
  name                    = "alert-${local.name}-route-5xx"
  location                = var.location
  resource_group_name     = data.azurerm_resource_group.this.name
  scopes                  = [azurerm_application_insights.this.id]
  description             = "More than ${var.alerts.route_5xx_threshold} server errors in 15 minutes on the scan events, title suggest or onboarding routes."
  severity                = 2
  evaluation_frequency    = "PT15M"
  window_duration         = "PT15M"
  auto_mitigation_enabled = true
  criteria {
    query                   = <<-KQL
      requests
      | extend route = ${local.route_case}
      | where route != "" and toint(resultCode) >= 500
    KQL
    time_aggregation_method = "Count"
    threshold               = var.alerts.route_5xx_threshold
    operator                = "GreaterThan"
    dimension {
      name     = "route"
      operator = "Include"
      values   = ["*"]
    }
  }
  action {
    action_groups = [azurerm_monitor_action_group.email.id]
  }
  tags = local.tags
}
