# One identity per workload (spec 3, decision 2): each gets only the data roles it needs.
resource "azurerm_user_assigned_identity" "this" {
  for_each            = toset(var.identities)
  name                = "id-${local.name}-${each.key}"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.this.name
  tags                = local.tags
}

# A GitHub Actions workflow outside Azure may sign in as an identity through OIDC (no stored credential), for
# example the daily synthetic login test that reads its test account from Key Vault (plan 04 Task 15). Only an
# identity that runs no app or job and holds no data role may be federated (see the variable's validation), so a
# workflow can reach Key Vault secrets listed for it and nothing else. Credentials of one identity are written one
# after the other: Azure refuses concurrent writes of federated credentials on the same identity.
locals {
  github_federations = { for pair in flatten([for id, subjects in var.github_federations : [for s in subjects : { key = "${id}|${s}", identity = id, subject = s }]]) : pair.key => pair }
}

resource "azurerm_federated_identity_credential" "github" {
  for_each                  = local.github_federations
  name                      = "github-${substr(sha1(each.value.subject), 0, 12)}"
  user_assigned_identity_id = azurerm_user_assigned_identity.this[each.value.identity].id
  issuer                    = "https://token.actions.githubusercontent.com"
  audience                  = ["api://AzureADTokenExchange"]
  subject                   = each.value.subject
}
