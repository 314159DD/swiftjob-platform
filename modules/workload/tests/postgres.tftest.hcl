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
  mock_resource "azurerm_postgresql_flexible_server" {
    defaults = {
      id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-swiftjob-staging/providers/Microsoft.DBforPostgreSQL/flexibleServers/psql-mock"
      fqdn = "psql-mock.postgres.database.azure.com"
    }
  }
}

variables {
  environment                = "staging"
  resource_group_name        = "rg-swiftjob-staging"
  compute_location           = "swedencentral"
  log_analytics_workspace_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-swiftjob-platform/providers/Microsoft.OperationalInsights/workspaces/log-swiftjob-platform"
  identities                 = ["web", "api", "worker", "migrate"]
  budget_amount              = 5
  budget_start_date          = "2026-10-01T00:00:00Z"
  alert_email                = "owner@example.invalid"
  apps_enabled               = true
  postgres = {
    location       = "swedencentral"
    database       = "appdb"
    admin_identity = "migrate"
    owner_admin    = { object_id = "00000000-0000-0000-0000-0000000000cc", principal_name = "owner@example.invalid" }
    users          = ["api", "worker"]
  }
  apps = {
    api = { identity = "api", image = "mcr.microsoft.com/k8se/quickstart:latest", port = 80, cpu = 0.25, memory = "0.5Gi" }
    web = { identity = "web", image = "mcr.microsoft.com/k8se/quickstart:latest", port = 80, cpu = 0.25, memory = "0.5Gi" }
  }
  jobs = {
    db-migrate = {
      identity        = "migrate", image = "mcr.microsoft.com/k8se/quickstart:latest", command = ["run"], cpu = 0.25, memory = "0.5Gi"
      timeout_seconds = 600, env = { PRINCIPAL_REF = "@principal:api" }
    }
  }
}

run "password_sign_in_is_off" {
  command = apply
  assert {
    condition     = azurerm_postgresql_flexible_server.this[0].authentication[0].password_auth_enabled == false && azurerm_postgresql_flexible_server.this[0].authentication[0].active_directory_auth_enabled == true
    error_message = "the server must allow Entra ID sign-in only"
  }
  assert {
    condition     = azurerm_postgresql_flexible_server.this[0].sku_name == "B_Standard_B1ms" && azurerm_postgresql_flexible_server.this[0].storage_mb == 32768 && azurerm_postgresql_flexible_server.this[0].location == "swedencentral"
    error_message = "B1ms, 32 GB, database region"
  }
  assert {
    condition     = azurerm_postgresql_flexible_server.this[0].geo_redundant_backup_enabled == false && azurerm_postgresql_flexible_server.this[0].auto_grow_enabled == false && azurerm_postgresql_flexible_server.this[0].backup_retention_days == 7
    error_message = "no geo backup, no auto-grow, 7 days of backups"
  }
}

run "two_entra_administrators" {
  command = apply
  assert {
    condition     = azurerm_postgresql_flexible_server_active_directory_administrator.migrate[0].principal_type == "ServicePrincipal" && azurerm_postgresql_flexible_server_active_directory_administrator.migrate[0].principal_name == "id-swiftjob-staging-migrate"
    error_message = "the migration identity is an administrator under its resource name"
  }
  assert {
    condition     = azurerm_postgresql_flexible_server_active_directory_administrator.owner[0].principal_type == "User"
    error_message = "the owner is the second administrator"
  }
}

run "tls_and_firewall" {
  command = apply
  assert {
    condition     = azurerm_postgresql_flexible_server_configuration.tls["require_secure_transport"].value == "on" && azurerm_postgresql_flexible_server_configuration.tls["ssl_min_protocol_version"].value == "TLSv1.2"
    error_message = "TLS must be required, 1.2 at least"
  }
  assert {
    condition     = length(azurerm_postgresql_flexible_server_firewall_rule.azure) == 1 && azurerm_postgresql_flexible_server_firewall_rule.azure[0].start_ip_address == "0.0.0.0" && azurerm_postgresql_flexible_server_firewall_rule.azure[0].end_ip_address == "0.0.0.0"
    error_message = "one firewall rule, Azure services only"
  }
}

run "connection_settings_only_for_database_users" {
  command = apply
  assert {
    condition     = one([for e in azurerm_container_app.this["api"].template[0].container[0].env : e.value if e.name == "PGUSER"]) == "id-swiftjob-staging-api"
    error_message = "the API connects under its identity name"
  }
  assert {
    condition     = one([for e in azurerm_container_app.this["api"].template[0].container[0].env : e.value if e.name == "PGSSLMODE"]) == "verify-full"
    error_message = "clients verify the server certificate"
  }
  assert {
    condition     = length([for e in azurerm_container_app.this["web"].template[0].container[0].env : e if startswith(e.name, "PG")]) == 0
    error_message = "the web app has no database settings"
  }
  assert {
    condition     = one([for e in azurerm_container_app_job.this["db-migrate"].template[0].container[0].env : e.value if e.name == "PGUSER"]) == "id-swiftjob-staging-migrate"
    error_message = "the migration job connects as the administrator identity"
  }
}

run "principal_reference_resolves" {
  command = apply
  assert {
    condition     = one([for e in azurerm_container_app_job.this["db-migrate"].template[0].container[0].env : e.value if e.name == "PRINCIPAL_REF"]) == "id-swiftjob-staging-api|00000000-0000-0000-0000-0000000000aa"
    error_message = "@principal:<identity> resolves to name|object id"
  }
}

run "database_alerts" {
  command = apply
  assert {
    condition     = length(azurerm_monitor_metric_alert.pg) == 3 && azurerm_monitor_metric_alert.pg["connections"].criteria[0].threshold == 28 && azurerm_monitor_metric_alert.pg["cpu"].window_size == "PT15M"
    error_message = "three database alerts, connections at 80 % of 35 user connections, CPU over 15 minutes"
  }
  assert {
    condition     = alltrue([for a in azurerm_monitor_metric_alert.pg : a.criteria[0].metric_namespace == "Microsoft.DBforPostgreSQL/flexibleServers"])
    error_message = "alerts watch the database server"
  }
}

run "no_server_without_postgres" {
  command = apply
  variables {
    postgres = null
    jobs     = {}
  }
  assert {
    condition     = length(azurerm_postgresql_flexible_server.this) == 0 && length(azurerm_monitor_metric_alert.pg) == 0 && length([for e in azurerm_container_app.this["api"].template[0].container[0].env : e if startswith(e.name, "PG")]) == 0
    error_message = "postgres = null creates no server and injects nothing"
  }
}

run "large_sku_is_refused" {
  command = plan
  variables {
    postgres = { location = "swedencentral", database = "appdb", admin_identity = "migrate", users = ["api"], sku_name = "GP_Standard_D2s_v3" }
  }
  expect_failures = [var.postgres]
}

run "unknown_identity_is_refused" {
  command = plan
  variables {
    postgres = { location = "swedencentral", database = "appdb", admin_identity = "migrate", users = ["nobody"] }
  }
  expect_failures = [var.postgres]
}
