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
}

variables {
  environment                = "staging"
  resource_group_name        = "rg-swiftjob-staging"
  log_analytics_workspace_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-swiftjob-platform/providers/Microsoft.OperationalInsights/workspaces/log-swiftjob-platform"
  identities                 = ["web", "api", "job-a", "job-b"]
  blob_containers = {
    files = { access = { api = "Storage Blob Data Contributor", job-b = "Storage Blob Data Reader" } }
  }
  telemetry_publishers = ["api", "job-b"]
  budget_amount        = 5
  budget_start_date    = "2026-10-01T00:00:00Z"
  alert_email          = "owner@example.invalid"
}

run "names_fit_azure_limits" {
  command = apply
  assert {
    condition     = length(azurerm_key_vault.this.name) <= 24 && length(azurerm_storage_account.this.name) <= 24
    error_message = "Key Vault and storage account names must be at most 24 characters"
  }
  assert {
    condition     = can(regex("^[a-z0-9]+$", azurerm_storage_account.this.name))
    error_message = "storage account names are lowercase letters and digits only"
  }
}

run "one_identity_per_workload" {
  command = apply
  assert {
    condition     = length(azurerm_user_assigned_identity.this) == 4
    error_message = "expected one identity per listed workload"
  }
}

run "blob_access_is_per_container_and_identity" {
  command = apply
  assert {
    condition     = length(azurerm_role_assignment.blob) == 2
    error_message = "expected exactly the two configured blob grants"
  }
  assert {
    condition     = azurerm_role_assignment.blob["files-job-b"].role_definition_name == "Storage Blob Data Reader"
    error_message = "job-b must only read"
  }
  assert {
    condition     = endswith(azurerm_role_assignment.blob["files-api"].scope, "/blobServices/default/containers/files")
    error_message = "blob grants must be scoped to the container, never the account"
  }
}

run "every_role_assignment_names_service_principal" {
  command = apply
  assert {
    condition = alltrue(concat(
      [for r in azurerm_role_assignment.blob : r.principal_type == "ServicePrincipal"],
      [for r in azurerm_role_assignment.telemetry : r.principal_type == "ServicePrincipal"],
      [azurerm_role_assignment.killswitch.principal_type == "ServicePrincipal"],
    ))
    error_message = "the ABAC condition of tf-staging only allows grants to service principals"
  }
}

run "no_keys_no_public_blobs" {
  command = apply
  assert {
    condition     = azurerm_storage_account.this.shared_access_key_enabled == false && azurerm_storage_account.this.allow_nested_items_to_be_public == false
    error_message = "storage must not allow shared keys or public blobs"
  }
  assert {
    condition     = azurerm_key_vault.this.rbac_authorization_enabled == true
    error_message = "Key Vault must use RBAC"
  }
}

run "unknown_identity_in_blob_access_fails" {
  command = plan
  variables {
    blob_containers = { files = { access = { nobody = "Storage Blob Data Reader" } } }
  }
  expect_failures = [var.blob_containers]
}

run "only_data_roles_for_blobs" {
  command = plan
  variables {
    blob_containers = { files = { access = { api = "Owner" } } }
  }
  expect_failures = [var.blob_containers]
}
