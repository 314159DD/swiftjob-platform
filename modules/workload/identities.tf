# One identity per workload (spec 3, decision 2): each gets only the data roles it needs.
resource "azurerm_user_assigned_identity" "this" {
  for_each            = toset(var.identities)
  name                = "id-${local.name}-${each.key}"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.this.name
  tags                = local.tags
}
