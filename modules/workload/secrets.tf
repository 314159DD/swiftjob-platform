# Container apps read Key Vault secrets through their identity (spec 3, decision 3). Each identity gets
# Key Vault Secrets User on exactly the secrets it is listed for, at secret scope. The registry token goes to
# every identity that runs an app or a job. The secrets must exist before this runs (scripts/load-secrets.sh).
locals {
  workload_identities = toset(concat([for a in values(var.apps) : a.identity], [for j in values(var.jobs) : j.identity]))
  secret_grants = merge(
    { for pair in flatten([for s, v in var.secrets : [for r in v.readers : { key = "${s}|${r}", secret = s, identity = r }]]) : pair.key => pair },
    var.registry == null ? {} : { for id in local.workload_identities : "${var.registry.password_secret}|${id}" => { key = "${var.registry.password_secret}|${id}", secret = var.registry.password_secret, identity = id } }
  )
  secret_uri = { for s in keys(var.secrets) : s => "${azurerm_key_vault.this.vault_uri}secrets/${s}" } # versionless: rotation needs no deploy
}

resource "azurerm_role_assignment" "secret_reader" {
  for_each             = var.apps_enabled ? local.secret_grants : {}
  scope                = "${azurerm_key_vault.this.id}/secrets/${each.value.secret}"
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.this[each.value.identity].principal_id
  principal_type       = "ServicePrincipal"
}
