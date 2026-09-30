# Policies added in phase 2 (ADR 3 rollout: DoNotEnforce, compliance review, then enforce).
locals {
  enforce2 = var.enforce_phase2_policies
  sub_id   = "/subscriptions/${var.subscription_id}"
  exempt_rg_ids = [
    for rg in var.network_cost_exempt_resource_groups : "${local.sub_id}/resourceGroups/${rg}"
  ]
  public_network_audits = {
    keyvault = "405c5871-3e91-4644-8a63-58e19d68ff5b"
    storage  = "b2982f36-99f2-4db5-8eff-283140c09693"
    postgres = "5e1de0e3-42cb-4ebc-a86d-61d0c619ca48"
  }
  containerapps_audits = {
    identity = "b874ab2d-72dd-47f1-8cb5-4a306478a4e7"
    https    = "0e80e269-43a4-4ae9-b5bc-178126b8a5cb"
  }
}

data "azurerm_resource_group" "prod" {
  name = "rg-swiftjob-prod" # created empty by scripts/bootstrap.sh
}

# Allowed regions: Germany West Central and global for everything, the Static Web Apps regions for that type only,
# and the compute region for the Container Apps types only (ADR 7).
# Replaces allowed-locations, which allowed eastus2 and westeurope for every type.
resource "azurerm_policy_definition" "allowed_locations" {
  name                = "allowed-locations-swa"
  display_name        = "Allowed locations, with an exception for Static Web Apps"
  policy_type         = "Custom"
  mode                = "Indexed"
  management_group_id = local.root_mg_id
  policy_rule         = file("${path.module}/policy-definitions/allowed-locations.json")
  parameters = jsonencode({
    listOfAllowedLocations = { type = "Array", metadata = { displayName = "Allowed locations" } }
    staticSiteLocations    = { type = "Array", defaultValue = ["eastus2", "westeurope"], metadata = { displayName = "Allowed locations for Static Web Apps" } }
    computeLocations       = { type = "Array", defaultValue = ["westeurope"], metadata = { displayName = "Allowed locations for Container Apps compute" } }
    computeTypes           = { type = "Array", defaultValue = ["Microsoft.App/managedEnvironments", "Microsoft.App/containerApps", "Microsoft.App/jobs"], metadata = { displayName = "Resource types of the Container Apps compute layer" } }
  })
}

resource "azurerm_management_group_policy_assignment" "allowed_locations_v2" {
  name                 = "allowed-locations-v2"
  display_name         = azurerm_policy_definition.allowed_locations.display_name
  management_group_id  = local.root_mg_id
  policy_definition_id = azurerm_policy_definition.allowed_locations.id
  enforce              = local.enforce2
  parameters = jsonencode({
    listOfAllowedLocations = { value = ["germanywestcentral"] }
    staticSiteLocations    = { value = var.static_site_locations }
    computeLocations       = { value = var.compute_locations }
    computeTypes           = { value = var.compute_types }
  })
}

# PostgreSQL only with Entra ID sign-in, before any server exists (plan 03).
resource "azurerm_policy_definition" "deny_postgres_password_auth" {
  name                = "deny-postgres-password-auth"
  display_name        = "PostgreSQL flexible servers must use Entra ID only"
  policy_type         = "Custom"
  mode                = "All"
  management_group_id = local.root_mg_id
  policy_rule         = file("${path.module}/policy-definitions/deny-postgres-password-auth.json")
}

# The assignment name is shorter than the definition name: management group assignment names allow 24 characters.
resource "azurerm_management_group_policy_assignment" "deny_postgres_password_auth" {
  name                 = "deny-pg-password-auth"
  display_name         = azurerm_policy_definition.deny_postgres_password_auth.display_name
  management_group_id  = local.root_mg_id
  policy_definition_id = azurerm_policy_definition.deny_postgres_password_auth.id
  enforce              = local.enforce2
}

# Network features with an hourly price (ADR 6): a VNet environment brings a Standard load balancer and two public
# IPs (about 22 EUR per month), a Dedicated profile brings the environment management fee, a private endpoint costs
# per hour. Allowed only in the throwaway network test groups.
resource "azurerm_policy_definition" "deny_network_cost" {
  name                = "deny-network-cost"
  display_name        = "No VNet Container Apps environments, Dedicated profiles, Standard load balancers or private endpoints"
  policy_type         = "Custom"
  mode                = "All"
  management_group_id = local.root_mg_id
  policy_rule         = file("${path.module}/policy-definitions/deny-network-cost.json")
}

resource "azurerm_management_group_policy_assignment" "deny_network_cost" {
  name                 = "deny-network-cost"
  display_name         = azurerm_policy_definition.deny_network_cost.display_name
  management_group_id  = azurerm_management_group.workloads.id
  policy_definition_id = azurerm_policy_definition.deny_network_cost.id
  enforce              = local.enforce2
  not_scopes           = local.exempt_rg_ids
}

# Public network access: visible deviation in production until the VNet switch (spec 4, variant C).
resource "azurerm_management_group_policy_assignment" "audit_public_network" {
  for_each             = local.public_network_audits
  name                 = "audit-pna-${each.key}"
  display_name         = "Audit public network access: ${each.key}"
  management_group_id  = azurerm_management_group.prod.id
  policy_definition_id = "${local.builtin}/${each.value}"
  enforce              = local.enforce2
  parameters           = jsonencode({ effect = { value = "Audit" } })
}

# In the trial everything sits in one subscription under mg-workloads, so the management group assignment above
# does not reach the production resource group yet. The same audit at resource group scope does.
resource "azurerm_resource_group_policy_assignment" "audit_public_network_prod" {
  for_each             = local.public_network_audits
  name                 = "audit-pna-${each.key}"
  display_name         = "Audit public network access: ${each.key}"
  resource_group_id    = data.azurerm_resource_group.prod.id
  policy_definition_id = "${local.builtin}/${each.value}"
  enforce              = local.enforce2
  parameters           = jsonencode({ effect = { value = "Audit" } })
}

resource "azurerm_management_group_policy_assignment" "audit_containerapps" {
  for_each             = local.containerapps_audits
  name                 = "audit-aca-${each.key}"
  display_name         = "Audit Container Apps: ${each.key}"
  management_group_id  = azurerm_management_group.workloads.id
  policy_definition_id = "${local.builtin}/${each.value}"
  enforce              = local.enforce2
  parameters           = jsonencode({ effect = { value = "Audit" } })
}
