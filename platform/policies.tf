# Guardrails for everything below mg-swiftjob. Rolled out with enforce_policies = false first: compliance is
# evaluated and visible in Azure Policy, nothing is denied. Enforced once the report is clean (ADR 0003).
locals {
  root_mg_id    = azurerm_management_group.root.id
  enforce       = var.enforce_policies
  builtin       = "/providers/Microsoft.Authorization/policyDefinitions"
  no_sandbox    = [azurerm_management_group.sandbox.id]
  required_tags = ["project", "env", "owner"]
}

resource "azurerm_management_group_policy_assignment" "allowed_locations" {
  name                 = "allowed-locations"
  display_name         = "Allowed locations"
  management_group_id  = local.root_mg_id
  policy_definition_id = "${local.builtin}/e56962a6-4747-49cd-b67b-bf8b01975c4c"
  enforce              = local.enforce
  parameters           = jsonencode({ listOfAllowedLocations = { value = var.allowed_locations } })
}

resource "azurerm_management_group_policy_assignment" "allowed_rg_locations" {
  name                 = "allowed-rg-locations"
  display_name         = "Allowed locations for resource groups"
  management_group_id  = local.root_mg_id
  policy_definition_id = "${local.builtin}/e765b5de-1225-4ba3-bd56-1ac6695af988"
  enforce              = local.enforce
  parameters           = jsonencode({ listOfAllowedLocations = { value = var.allowed_locations } })
}

resource "azurerm_management_group_policy_assignment" "require_rg_tag" {
  for_each             = toset(local.required_tags)
  name                 = "require-rg-tag-${each.key}"
  display_name         = "Resource groups need the tag ${each.key}"
  management_group_id  = local.root_mg_id
  policy_definition_id = "${local.builtin}/96670d01-0a4d-4649-9c89-2d3abc0a5025"
  enforce              = local.enforce
  parameters           = jsonencode({ tagName = { value = each.key } })
  # Container Apps creates the infrastructure resource group of a VNet environment itself, without tags.
  not_scopes = ["/subscriptions/${var.subscription_id}/resourceGroups/rg-swiftjob-nettest-infra"]
}

resource "azurerm_management_group_policy_assignment" "deny_storage_shared_key" {
  name                 = "deny-storage-shared-key"
  display_name         = "Storage accounts must not allow shared key access"
  management_group_id  = local.root_mg_id
  policy_definition_id = "${local.builtin}/8c6a50c6-9ffd-4ae7-986f-5fa6111f9a54"
  enforce              = local.enforce
  parameters           = jsonencode({ effect = { value = "Deny" } })
}

resource "azurerm_management_group_policy_assignment" "deny_keyvault_access_policies" {
  name                 = "deny-kv-access-policies"
  display_name         = "Key vaults must use the RBAC permission model"
  management_group_id  = local.root_mg_id
  policy_definition_id = "${local.builtin}/12d4fa5e-1f9f-4c21-97a9-b99b3c6611b5"
  enforce              = local.enforce
  parameters           = jsonencode({ effect = { value = "Deny" } })
}

resource "azurerm_management_group_policy_assignment" "deny_costly_types" {
  name                 = "deny-costly-types"
  display_name         = "No resource types with high fixed monthly cost"
  management_group_id  = local.root_mg_id
  policy_definition_id = "${local.builtin}/6c112d4e-5bc7-47ae-a041-ea2d9dccd749"
  enforce              = local.enforce
  not_scopes           = local.no_sandbox
  parameters = jsonencode({
    effect = { value = "Deny" }
    listOfResourceTypesNotAllowed = { value = [
      "Microsoft.Network/azureFirewalls",
      "Microsoft.Network/applicationGateways",
      "Microsoft.Network/bastionHosts",
      "Microsoft.Network/virtualNetworkGateways",
      "Microsoft.Network/natGateways",
      "Microsoft.Network/expressRouteCircuits",
      "Microsoft.ContainerService/managedClusters",
      "Microsoft.Compute/virtualMachineScaleSets",
    ] }
  })
}

resource "azurerm_management_group_policy_assignment" "allowed_vm_sizes" {
  name                 = "allowed-vm-sizes"
  display_name         = "Only small burstable VM sizes"
  management_group_id  = local.root_mg_id
  policy_definition_id = "${local.builtin}/cccc23c7-8427-4f53-ad12-b6a63eb452b3"
  enforce              = local.enforce
  not_scopes           = local.no_sandbox
  parameters = jsonencode({ listOfAllowedSKUs = { value = [
    "Standard_B1s", "Standard_B1ms", "Standard_B2s", "Standard_B2ms", "Standard_B2als_v2", "Standard_B2ats_v2",
  ] } })
}

resource "azurerm_policy_definition" "deny_costly_skus" {
  name                = "deny-costly-skus"
  display_name        = "No expensive SKUs (Front Door Premium, API Management above Developer, large PostgreSQL)"
  policy_type         = "Custom"
  mode                = "All"
  management_group_id = local.root_mg_id
  policy_rule         = file("${path.module}/policy-definitions/deny-expensive-skus.json")
}

resource "azurerm_management_group_policy_assignment" "deny_costly_skus" {
  name                 = "deny-costly-skus"
  display_name         = azurerm_policy_definition.deny_costly_skus.display_name
  management_group_id  = local.root_mg_id
  policy_definition_id = azurerm_policy_definition.deny_costly_skus.id
  enforce              = local.enforce
  not_scopes           = local.no_sandbox
}

# Diagnostics go to the central workspace automatically. DeployIfNotExists needs an identity that may
# write diagnostic settings; tf-platform may grant exactly these two roles (ABAC condition, bootstrap).
locals {
  diagnostics = {
    keyvault = "6b359d8f-f88d-4052-aa7c-32015963ecc1"
    postgres = "cdd1dbc6-0004-4fcd-afd7-b67550de37ff"
  }
  diagnostics_roles = {
    log_analytics_contributor = "92aaf0da-9dab-42b6-94a3-d43ce8d16293"
    monitoring_contributor    = "749f88d5-cbae-40b8-bcfc-e573ddc772fa"
  }
}

resource "azurerm_management_group_policy_assignment" "diagnostics" {
  for_each             = local.diagnostics
  name                 = "diag-${each.key}"
  display_name         = "Send ${each.key} audit logs to the central workspace"
  management_group_id  = local.root_mg_id
  policy_definition_id = "${local.builtin}/${each.value}"
  enforce              = local.enforce
  location             = var.location
  identity {
    type = "SystemAssigned"
  }
  parameters = jsonencode({
    logAnalytics  = { value = azurerm_log_analytics_workspace.central.id }
    categoryGroup = { value = "audit" }
    effect        = { value = "DeployIfNotExists" }
  })
}

resource "azurerm_role_assignment" "diagnostics" {
  for_each = {
    for pair in setproduct(keys(local.diagnostics), keys(local.diagnostics_roles)) :
    "${pair[0]}-${pair[1]}" => { assignment = pair[0], role = local.diagnostics_roles[pair[1]] }
  }
  scope              = local.root_mg_id
  role_definition_id = "/providers/Microsoft.Authorization/roleDefinitions/${each.value.role}"
  principal_id       = azurerm_management_group_policy_assignment.diagnostics[each.value.assignment].identity[0].principal_id
  principal_type     = "ServicePrincipal"
}
