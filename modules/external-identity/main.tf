data "azuread_application_published_app_ids" "well_known" {}

data "azuread_service_principal" "graph" {
  client_id = data.azuread_application_published_app_ids.well_known.result["MicrosoftGraph"]
}

# The owner is the apply identity looked up by client id, not the signed-in caller: the read-only plan job and the apply
# job must propose the same owners, otherwise every plan after the first apply shows a diff.
data "azuread_service_principal" "deployer" {
  client_id = var.owner_client_id
}

locals {
  owners = [data.azuread_service_principal.deployer.object_id] # Application.ReadWrite.OwnedBy: the pipeline owns what it creates
}

resource "azuread_application" "api" {
  display_name     = "api-${var.environment}"
  owners           = local.owners
  sign_in_audience = "AzureADMyOrg"

  api {
    requested_access_token_version = 2
    oauth2_permission_scope {
      id                         = var.scope_id
      value                      = "api.access"
      type                       = "User"
      admin_consent_display_name = "Use the API"
      admin_consent_description  = "Lets the web app call the API for the signed-in user."
      user_consent_display_name  = "Use the API"
      user_consent_description   = "Lets the web app call the API for you."
      enabled                    = true
    }
  }

  app_role {
    id                   = var.admin_role_id
    value                = "Admin"
    display_name         = "Admin"
    description          = "Operators of the service."
    allowed_member_types = ["User"]
    enabled              = true
  }

  optional_claims {
    access_token { name = "email" }
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [identifier_uris]
  }
}

resource "azuread_application_identifier_uri" "api" {
  application_id = azuread_application.api.id
  identifier_uri = "api://${azuread_application.api.client_id}"
}

resource "azuread_service_principal" "api" {
  client_id                    = azuread_application.api.client_id
  owners                       = local.owners
  app_role_assignment_required = false
}

resource "azuread_application" "web" {
  display_name     = "web-${var.environment}"
  owners           = local.owners
  sign_in_audience = "AzureADMyOrg"

  web {
    # The callback receives the auth code; /auth/signed-out is the post_logout_redirect_uri (Entra honours it only when
    # registered). It is a route handler that drops the query and redirects to /, so a code sent there is never shown.
    redirect_uris = ["${var.web_base_url}/auth/callback", "${var.web_base_url}/auth/signed-out"]
    implicit_grant {
      access_token_issuance_enabled = false
      id_token_issuance_enabled     = false
    }
  }

  required_resource_access {
    resource_app_id = data.azuread_service_principal.graph.client_id
    resource_access {
      id   = data.azuread_service_principal.graph.oauth2_permission_scope_ids["openid"]
      type = "Scope"
    }
    resource_access {
      id   = data.azuread_service_principal.graph.oauth2_permission_scope_ids["offline_access"]
      type = "Scope"
    }
    resource_access {
      id   = data.azuread_service_principal.graph.oauth2_permission_scope_ids["profile"]
      type = "Scope"
    }
    resource_access {
      id   = data.azuread_service_principal.graph.oauth2_permission_scope_ids["email"]
      type = "Scope"
    }
  }

  required_resource_access {
    resource_app_id = azuread_application.api.client_id
    resource_access {
      id   = var.scope_id
      type = "Scope"
    }
  }

  lifecycle { prevent_destroy = true }
}

resource "azuread_service_principal" "web" {
  client_id = azuread_application.web.client_id
  owners    = local.owners
}

resource "azuread_application" "deleter" {
  display_name     = "deleter-${var.environment}"
  owners           = local.owners
  sign_in_audience = "AzureADMyOrg"

  required_resource_access {
    resource_app_id = data.azuread_service_principal.graph.client_id
    resource_access {
      id   = data.azuread_service_principal.graph.app_role_ids["User.ReadWrite.All"]
      type = "Role"
    }
    resource_access {
      id   = data.azuread_service_principal.graph.app_role_ids["User.DeleteRestore.All"]
      type = "Role"
    }
  }

  lifecycle { prevent_destroy = true }
}

resource "azuread_service_principal" "deleter" {
  client_id = azuread_application.deleter.client_id
  owners    = local.owners
}
