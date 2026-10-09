mock_provider "time" {}

mock_provider "azurerm" {
  mock_data "azurerm_resource_group" {
    defaults = {
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-swiftjob-staging"
      location = "germanywestcentral"
    }
  }
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id = "00000000-0000-0000-0000-000000000001"
      object_id = "00000000-0000-0000-0000-000000000002"
    }
  }
  mock_resource "azurerm_storage_account" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-swiftjob-staging/providers/Microsoft.Storage/storageAccounts/mockstorage"
    }
  }
  mock_resource "azurerm_container_app_environment" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-swiftjob-staging/providers/Microsoft.App/managedEnvironments/cae-mock"
    }
  }
  mock_resource "azurerm_logic_app_workflow" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-swiftjob-staging/providers/Microsoft.Logic/workflows/logic-mock"
    }
  }
  mock_resource "azurerm_application_insights" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-swiftjob-staging/providers/Microsoft.Insights/components/appi-mock"
    }
  }
  mock_resource "azurerm_monitor_action_group" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-swiftjob-staging/providers/Microsoft.Insights/actionGroups/ag-mock"
    }
  }
  mock_resource "azurerm_logic_app_trigger_http_request" {
    defaults = {
      callback_url = "https://prod-00.germanywestcentral.logic.azure.com:443/workflows/mock/triggers/alert/paths/invoke"
    }
  }
  mock_resource "azurerm_key_vault" {
    defaults = {
      id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-swiftjob-staging/providers/Microsoft.KeyVault/vaults/kv-mock"
      vault_uri = "https://kv-mock.vault.azure.net/"
    }
  }
  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-swiftjob-staging/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-mock"
      principal_id = "00000000-0000-0000-0000-0000000000aa"
      client_id    = "00000000-0000-0000-0000-0000000000bb"
    }
  }
  mock_resource "azurerm_container_app" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-swiftjob-staging/providers/Microsoft.App/containerApps/ca-mock"
    }
  }
}

variables {
  environment                = "staging"
  resource_group_name        = "rg-swiftjob-staging"
  compute_location           = "swedencentral"
  log_analytics_workspace_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-swiftjob-platform/providers/Microsoft.OperationalInsights/workspaces/log-swiftjob-platform"
  identities                 = ["web", "api", "worker"]
  budget_amount              = 5
  budget_start_date          = "2026-10-01T00:00:00Z"
  alert_email                = "owner@example.invalid"
  apps_enabled               = true
  images = {
    api = "ghcr.io/314159dd/example-api@sha256:1111111111111111111111111111111111111111111111111111111111111111"
    web = "ghcr.io/314159dd/example-web@sha256:2222222222222222222222222222222222222222222222222222222222222222"
  }
  registry = { server = "ghcr.io", username = "someone", password_secret = "registry-token" }
  secrets = {
    "registry-token" = { readers = [] }
    "db-key"         = { readers = ["api", "worker"] }
    "session-key"    = { readers = ["api"] }
  }
  apps = {
    api = {
      identity   = "api", image = "api", port = 8080, cpu = 0.5, memory = "1Gi", max_replicas = 2, health_path = "/health"
      env        = { CORS_ORIGINS = "@url:web", PLAIN = "value" }
      secret_env = { DB_KEY = "db-key", SESSION_KEY = "session-key" }
    }
    web = { identity = "web", image = "web", port = 3000, cpu = 0.25, memory = "0.5Gi" }
  }
  jobs = {
    nightly = {
      identity   = "worker", image = "api", command = ["run"], args = ["nightly"], cpu = 0.25, memory = "0.5Gi"
      cron       = "0 3 * * *", enabled = true, timeout_seconds = 600, missed_alert_hours = 26
      idle_alert = { hours = 6, counter = "new" }
      secret_env = { DB_KEY = "db-key" }
    }
    parked = {
      identity   = "worker", image = "api", command = ["run"], cpu = 0.25, memory = "0.5Gi"
      cron       = "0 */4 * * *", enabled = false, timeout_seconds = 600, missed_alert_hours = 6
      idle_alert = { hours = 6, counter = "new" }
    }
    weekly = {
      identity = "worker", image = "api", command = ["run"], cpu = 0.25, memory = "0.5Gi"
      cron     = "0 2 * * 0", enabled = true, timeout_seconds = 600
    }
  }
  alerts = { api_app = "api" }
}

run "names_fit_container_apps_limits" {
  command = apply
  assert {
    condition     = alltrue([for a in azurerm_container_app.this : length(a.name) <= 32]) && alltrue([for j in azurerm_container_app_job.this : length(j.name) <= 32])
    error_message = "container app and job names must be at most 32 characters"
  }
  assert {
    condition     = alltrue([for j in azurerm_container_app_job.this : j.location == var.compute_location])
    error_message = "jobs must be created in compute_location, the region of the Container Apps environment"
  }
}

run "secrets_are_key_vault_references_only" {
  command = apply
  assert {
    condition     = alltrue(flatten([for a in azurerm_container_app.this : [for s in a.secret : s.key_vault_secret_id != null && s.key_vault_secret_id != ""]]))
    error_message = "every app secret must be a Key Vault reference"
  }
}

run "each_identity_reads_only_its_secrets" {
  command = apply
  assert {
    condition     = contains(keys(azurerm_role_assignment.secret_reader), "session-key|api") && !contains(keys(azurerm_role_assignment.secret_reader), "session-key|worker")
    error_message = "session-key must be readable by api only"
  }
  assert {
    condition     = alltrue([for id in ["api", "web", "worker"] : contains(keys(azurerm_role_assignment.secret_reader), "registry-token|${id}")])
    error_message = "every workload identity needs the registry token"
  }
  assert {
    condition     = alltrue([for r in azurerm_role_assignment.secret_reader : strcontains(r.scope, "/secrets/") && r.principal_type == "ServicePrincipal"])
    error_message = "grants are per secret and to service principals"
  }
}

run "apps_and_jobs_wait_for_role_propagation" {
  command = apply
  assert {
    condition     = length(time_sleep.role_propagation) == 1 && time_sleep.role_propagation[0].create_duration == "90s"
    error_message = "one 90 s wait after the secret reader role assignments"
  }
  assert {
    condition     = length(time_sleep.role_propagation[0].triggers) == 1
    error_message = "the wait is re-run only when the set of role assignments changes"
  }
}

run "no_wait_without_grants" {
  command = apply
  variables {
    apps_enabled = false
  }
  assert {
    condition     = length(time_sleep.role_propagation) == 0
    error_message = "no role assignments, no wait"
  }
}

run "wait_must_be_a_duration" {
  command = plan
  variables {
    role_propagation_wait = "soon"
  }
  expect_failures = [var.role_propagation_wait]
}

run "references_resolve" {
  command = apply
  assert {
    condition     = startswith(one([for e in azurerm_container_app.this["api"].template[0].container[0].env : e.value if e.name == "CORS_ORIGINS"]), "https://ca-swiftjob-staging-web.")
    error_message = "@url:web must resolve to the web app URL"
  }
  assert {
    condition     = one([for e in azurerm_container_app.this["api"].template[0].container[0].env : e.value if e.name == "PLAIN"]) == "value"
    error_message = "plain values pass through"
  }
  assert {
    condition     = one([for e in azurerm_container_app_job.this["nightly"].template[0].container[0].env : e.value if e.name == "JOB_NAME"]) == "nightly"
    error_message = "jobs get JOB_NAME"
  }
}

run "disabled_jobs_have_no_schedule" {
  command = apply
  assert {
    condition     = length(azurerm_container_app_job.this["parked"].schedule_trigger_config) == 0 && length(azurerm_container_app_job.this["parked"].manual_trigger_config) == 1
    error_message = "a disabled job must only be startable by hand"
  }
  assert {
    condition     = azurerm_container_app_job.this["nightly"].schedule_trigger_config[0].cron_expression == "0 3 * * *"
    error_message = "an enabled job runs on its schedule"
  }
}

run "missed_alert_only_for_enabled_scheduled_jobs" {
  command = apply
  assert {
    condition     = toset(keys(azurerm_monitor_scheduled_query_rules_alert_v2.job_missed)) == toset(["nightly"])
    error_message = "missed-run alerts exist only for enabled jobs with missed_alert_hours"
  }
}

run "missed_alert_window_is_an_allowed_value" {
  command = apply
  assert {
    condition     = azurerm_monitor_scheduled_query_rules_alert_v2.job_missed["nightly"].window_duration == "P2D"
    error_message = "26 hours must round up to P2D (allowed log alert windows: PT5M to PT6H, P1D, P2D)"
  }
  assert {
    condition     = strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.job_missed["nightly"].criteria[0].query, "ago(26h)")
    error_message = "the query must filter the exact number of hours"
  }
  assert {
    condition     = azurerm_monitor_scheduled_query_rules_alert_v2.job_missed["nightly"].auto_mitigation_enabled == true
    error_message = "missed-run alerts resolve on their own once a run succeeds"
  }
  assert {
    condition     = strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.job_missed["nightly"].criteria[0].query, "job-staging-nightly")
    error_message = "the query must filter on the job resource name"
  }
}

run "idle_alert_only_for_enabled_scheduled_jobs_and_on_the_counter" {
  command = apply
  assert {
    condition     = toset(keys(azurerm_monitor_scheduled_query_rules_alert_v2.job_idle)) == toset(["nightly"])
    error_message = "idle alerts exist only for enabled scheduled jobs with idle_alert"
  }
  assert {
    condition     = azurerm_monitor_scheduled_query_rules_alert_v2.job_idle["nightly"].window_duration == "PT6H"
    error_message = "6 hours is an allowed window as is"
  }
  assert {
    condition     = strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.job_idle["nightly"].criteria[0].query, "ago(6h)") && strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.job_idle["nightly"].criteria[0].query, "status=ok .*[ =]new=[1-9]")
    error_message = "the query must match a successful run with the counter above 0 in the exact hours"
  }
  assert {
    condition     = contains(azurerm_monitor_scheduled_query_rules_alert_v2.job_idle["nightly"].action[0].action_groups, azurerm_monitor_action_group.email.id)
    error_message = "the alert uses the existing e-mail action group"
  }
}

run "auth_orphan_alert_is_hourly_on_the_log_line" {
  command = apply
  assert {
    condition     = azurerm_monitor_scheduled_query_rules_alert_v2.auth_orphan_stale[0].evaluation_frequency == "PT1H" && azurerm_monitor_scheduled_query_rules_alert_v2.auth_orphan_stale[0].window_duration == "P1D"
    error_message = "the orphan alert is evaluated hourly over a one day window"
  }
  assert {
    condition     = strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.auth_orphan_stale[0].criteria[0].query, "AUTH_ORPHAN_STALE count=")
    error_message = "the query must match the backend log line"
  }
  assert {
    condition     = contains(azurerm_monitor_scheduled_query_rules_alert_v2.auth_orphan_stale[0].action[0].action_groups, azurerm_monitor_action_group.email.id)
    error_message = "the alert uses the existing e-mail action group"
  }
}

run "nothing_is_deployed_while_apps_are_disabled" {
  command = apply
  variables {
    apps_enabled = false
  }
  assert {
    condition     = length(azurerm_container_app.this) == 0 && length(azurerm_container_app_job.this) == 0 && length(azurerm_role_assignment.secret_reader) == 0
    error_message = "apps_enabled = false must create no apps, jobs or secret grants"
  }
}

run "secret_without_read_access_is_refused" {
  command = plan
  variables {
    apps = {
      api = { identity = "api", image = "api", port = 8080, cpu = 0.5, memory = "1Gi", secret_env = { DB_KEY = "session-key" } }
      web = { identity = "web", image = "web", port = 3000, cpu = 0.25, memory = "0.5Gi", secret_env = { S = "session-key" } }
    }
  }
  expect_failures = [azurerm_container_app.this]
}

run "tags_are_refused_as_images" {
  command = plan
  variables {
    images = { api = "ghcr.io/314159dd/example-api:latest" }
  }
  expect_failures = [var.images]
}

run "image_key_without_digest_is_refused" {
  command = plan
  variables {
    images = { api = "ghcr.io/314159dd/example-api@sha256:1111111111111111111111111111111111111111111111111111111111111111" }
  }
  expect_failures = [azurerm_container_app.this]
}

run "custom_domains_are_declared_but_not_created_by_default" {
  command = apply
  variables {
    apps = {
      web = { identity = "web", image = "web", port = 3000, cpu = 0.25, memory = "0.5Gi", custom_domains = ["example.test", "www.example.test"] }
    }
    jobs   = {}
    alerts = {}
  }
  assert {
    condition     = length(azurerm_container_app_custom_domain.this) == 0
    error_message = "no custom domain may be created while enable_custom_domains is false"
  }
  assert {
    condition     = join(",", output.custom_domains.web) == "example.test,www.example.test"
    error_message = "declared domains are reported"
  }
}

run "custom_domains_bind_a_managed_certificate_when_enabled" {
  command = apply
  variables {
    enable_custom_domains = true
    apps = {
      web = { identity = "web", image = "web", port = 3000, cpu = 0.25, memory = "0.5Gi", custom_domains = ["example.test", "www.example.test"] }
      api = { identity = "api", image = "api", port = 8080, cpu = 0.5, memory = "1Gi" }
    }
    jobs   = {}
    alerts = {}
  }
  assert {
    condition     = length(azurerm_container_app_custom_domain.this) == 2
    error_message = "one custom domain resource per declared host name, none for an app without the list"
  }
  assert {
    condition     = alltrue([for d in azurerm_container_app_custom_domain.this : d.container_app_environment_certificate_id == null])
    error_message = "no uploaded certificate: Azure issues a managed certificate"
  }
}

run "custom_domain_names_are_validated" {
  command = plan
  variables {
    apps = {
      web = { identity = "web", image = "web", port = 3000, cpu = 0.25, memory = "0.5Gi", custom_domains = ["https://example.test"] }
    }
    jobs   = {}
    alerts = {}
  }
  expect_failures = [var.apps]
}

run "purge_protection_follows_the_variable" {
  command = apply
  variables {
    key_vault_purge_protection = true
  }
  assert {
    condition     = azurerm_key_vault.this.purge_protection_enabled == true
    error_message = "purge protection must be on when requested"
  }
}

run "purge_protection_is_off_by_default" {
  command = apply
  assert {
    condition     = azurerm_key_vault.this.purge_protection_enabled == false
    error_message = "staging and throwaway environments keep purge protection off"
  }
}

run "application_alerts_with_defaults" {
  command = apply
  assert {
    condition     = length(azurerm_monitor_scheduled_query_rules_alert_v2.llm_primary_failures) == 1 && length(azurerm_monitor_scheduled_query_rules_alert_v2.llm_auth_or_credit) == 1 && length(azurerm_monitor_scheduled_query_rules_alert_v2.first_scan_bad) == 1 && length(azurerm_monitor_scheduled_query_rules_alert_v2.ranking_timeout) == 1
    error_message = "one rule each for LLM failures, LLM auth or credit, bad first scans and ranking timeouts"
  }
  assert {
    condition     = length(azurerm_monitor_scheduled_query_rules_alert_v2.route_p95) == 1 && length(azurerm_monitor_scheduled_query_rules_alert_v2.route_5xx) == 1
    error_message = "route latency and error rules exist when an API app is watched"
  }
  assert {
    condition     = azurerm_monitor_scheduled_query_rules_alert_v2.llm_primary_failures[0].criteria[0].threshold == 5 && azurerm_monitor_scheduled_query_rules_alert_v2.llm_primary_failures[0].criteria[0].dimension[0].name == "model"
    error_message = "primary model failures: default 5 per hour, split by model"
  }
  assert {
    condition     = azurerm_monitor_scheduled_query_rules_alert_v2.llm_auth_or_credit[0].evaluation_frequency == "PT5M" && azurerm_monitor_scheduled_query_rules_alert_v2.llm_auth_or_credit[0].severity == 1
    error_message = "401 and 402 are critical and evaluated every 5 minutes"
  }
  assert {
    condition     = azurerm_monitor_scheduled_query_rules_alert_v2.first_scan_bad[0].criteria[0].threshold == 1 && strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.first_scan_bad[0].criteria[0].query, "trigger=onboarding")
    error_message = "first-scan rule reads SCAN_TIMING of onboarding runs"
  }
  assert {
    condition     = alltrue([for r in concat(azurerm_monitor_scheduled_query_rules_alert_v2.llm_primary_failures, azurerm_monitor_scheduled_query_rules_alert_v2.first_scan_bad, azurerm_monitor_scheduled_query_rules_alert_v2.ranking_timeout, azurerm_monitor_scheduled_query_rules_alert_v2.route_p95, azurerm_monitor_scheduled_query_rules_alert_v2.route_5xx) : r.auto_mitigation_enabled && r.evaluation_frequency == "PT15M"])
    error_message = "quiet rules: 15-minute evaluation with auto-mitigation"
  }
  assert {
    condition     = strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.route_p95[0].criteria[0].query, "p95 > case(route == \"scan_events\", 3000, route == \"titles_suggest\", 1500, 10000)")
    error_message = "route p95 limits are wired into the query"
  }
  assert {
    condition     = strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.job_failed[0].criteria[0].query, "!contains \" status=ok \"")
    error_message = "job alert fires for every status other than ok"
  }
}

run "application_alerts_thresholds_and_switch" {
  command = apply
  variables {
    alerts = {
      api_app               = "api"
      llm_failures_per_hour = 9
      route_5xx_threshold   = 4
      route_p95_ms          = { scan_events = 1234 }
    }
  }
  assert {
    condition     = azurerm_monitor_scheduled_query_rules_alert_v2.llm_primary_failures[0].criteria[0].threshold == 9 && azurerm_monitor_scheduled_query_rules_alert_v2.route_5xx[0].criteria[0].threshold == 4
    error_message = "per-environment thresholds are wired through"
  }
  assert {
    condition     = strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.route_p95[0].criteria[0].query, "route == \"scan_events\", 1234")
    error_message = "route limit override reaches the query"
  }
}

run "log_alerts_can_be_switched_off_and_route_alerts_need_an_api_app" {
  command = apply
  variables {
    alerts = { log_alerts = false }
  }
  assert {
    condition     = length(azurerm_monitor_scheduled_query_rules_alert_v2.llm_primary_failures) == 0 && length(azurerm_monitor_scheduled_query_rules_alert_v2.first_scan_bad) == 0 && length(azurerm_monitor_scheduled_query_rules_alert_v2.route_p95) == 0
    error_message = "no application alerts without log_alerts and without a watched API app"
  }
}
