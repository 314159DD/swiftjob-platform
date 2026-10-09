# The external (customer identity) tenant is a separate directory. The job's GitHub OIDC token is exchanged there by a
# federated credential on tf-identity-plan (read) or tf-identity-prod (write); no secret is involved.
provider "azuread" {
  tenant_id = var.external_tenant_id
  client_id = var.identity_role == "apply" ? var.tf_identity_client_id : var.tf_identity_plan_client_id
  use_oidc  = true
}
