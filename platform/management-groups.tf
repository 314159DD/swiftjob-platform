# The root management group is created by the bootstrap (the first management group in a tenant can need
# elevated access) and adopted here, so Terraform owns everything below it.
import {
  to = azurerm_management_group.root
  id = "/providers/Microsoft.Management/managementGroups/${var.root_management_group_name}"
}

resource "azurerm_management_group" "root" {
  name         = var.root_management_group_name
  display_name = "SwiftJob"
}

resource "azurerm_management_group" "platform" {
  name                       = "mg-platform"
  display_name               = "Platform"
  parent_management_group_id = azurerm_management_group.root.id
}

resource "azurerm_management_group" "workloads" {
  name                       = "mg-workloads"
  display_name               = "Workloads"
  parent_management_group_id = azurerm_management_group.root.id

  # The subscription is moved in by the owner (scripts/move-subscription.sh). Moving subscriptions is a rare,
  # privileged act and deliberately not a pipeline permission.
  lifecycle {
    ignore_changes = [subscription_ids]
  }
}

resource "azurerm_management_group" "prod" {
  name                       = "mg-prod"
  display_name               = "Production"
  parent_management_group_id = azurerm_management_group.workloads.id
}

resource "azurerm_management_group" "nonprod" {
  name                       = "mg-nonprod"
  display_name               = "Non-production"
  parent_management_group_id = azurerm_management_group.workloads.id
}

resource "azurerm_management_group" "sandbox" {
  name                       = "mg-sandbox"
  display_name               = "Sandbox"
  parent_management_group_id = azurerm_management_group.root.id
}
