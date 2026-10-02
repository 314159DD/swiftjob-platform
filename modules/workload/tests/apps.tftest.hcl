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
      secret_env = { DB_KEY = "db-key" }
    }
    parked = {
      identity = "worker", image = "api", command = ["run"], cpu = 0.25, memory = "0.5Gi"
      cron     = "0 */4 * * *", enabled = false, timeout_seconds = 600, missed_alert_hours = 6
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

run "federated_identity_reads_only_its_secrets" {
  command = apply
  variables {
    identities = ["web", "api", "worker", "synthetic"]
    secrets = {
      "registry-token" = { readers = [] }
      "db-key"         = { readers = ["api", "worker"] }
      "session-key"    = { readers = ["api"] }
      "synth-login"    = { readers = ["synthetic"] }
    }
    github_federations = { synthetic = ["repo:owner/repo:ref:refs/heads/main"] }
  }
  assert {
    condition     = length(azurerm_federated_identity_credential.github) == 1
    error_message = "one federated credential per subject"
  }
  assert {
    condition = alltrue([for c in azurerm_federated_identity_credential.github :
      c.issuer == "https://token.actions.githubusercontent.com" && c.audience == tolist(["api://AzureADTokenExchange"]) &&
    c.subject == "repo:owner/repo:ref:refs/heads/main"])
    error_message = "GitHub issuer, the token exchange audience and the exact subject"
  }
  assert {
    condition     = [for k in keys(azurerm_role_assignment.secret_reader) : k if endswith(k, "|synthetic")] == ["synth-login|synthetic"]
    error_message = "the federated identity reads its own secret and nothing else (no registry token, it runs no app or job)"
  }
}

run "app_identity_cannot_be_federated" {
  command = plan
  variables {
    github_federations = { api = ["repo:owner/repo:ref:refs/heads/main"] }
  }
  expect_failures = [var.github_federations]
}

run "job_identity_cannot_be_federated" {
  command = plan
  variables {
    github_federations = { worker = ["repo:owner/repo:ref:refs/heads/main"] }
  }
  expect_failures = [var.github_federations]
}

run "pull_request_subject_is_refused" {
  command = plan
  variables {
    identities         = ["web", "api", "worker", "synthetic"]
    github_federations = { synthetic = ["repo:owner/repo:pull_request"] }
  }
  expect_failures = [var.github_federations]
}

run "wildcard_subject_is_refused" {
  command = plan
  variables {
    identities         = ["web", "api", "worker", "synthetic"]
    github_federations = { synthetic = ["repo:owner/repo:ref:refs/heads/*"] }
  }
  expect_failures = [var.github_federations]
}

run "immutable_subject_is_accepted" {
  command = plan
  variables {
    identities         = ["web", "api", "worker", "synthetic"]
    github_federations = { synthetic = ["repo:owner@1234/repo@5678:ref:refs/heads/main"] }
  }
  assert {
    condition     = length(azurerm_federated_identity_credential.github) == 1
    error_message = "the immutable subject format (owner and repository ids) is a valid subject"
  }
}
