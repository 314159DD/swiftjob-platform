mock_provider "azuread" {
  mock_data "azuread_application_published_app_ids" { defaults = { result = { MicrosoftGraph = "00000003-0000-0000-c000-000000000000" } } }
  mock_data "azuread_service_principal" {
    defaults = {
      app_role_ids                = { "User.ReadWrite.All" = "741f803b-c850-494e-b5df-cde7c675a1ca", "User.DeleteRestore.All" = "eccc023d-eccf-4e7b-9683-8813ab36cecc" }
      oauth2_permission_scope_ids = { openid = "37f7f235-527c-4136-accd-4a02d197296e", offline_access = "7427e0e9-2fba-42fe-b0c0-848c9e6a8182", profile = "14dad69e-099b-42c9-810b-d002981feec1", email = "64a6cdd6-aab1-4aaf-94b8-3cc8405e90d0" }
    }
  }
}

override_data {
  target = data.azuread_service_principal.deployer
  values = { object_id = "00000000-0000-0000-0000-0000000000aa" }
}

variables {
  owner_client_id = "00000000-0000-0000-0000-0000000000bb"
  environment     = "staging"
  web_base_url    = "https://web.example.test"
  admin_role_id   = "11111111-2222-3333-4444-555555555555"
  scope_id        = "66666666-7777-8888-9999-000000000000"
}

run "api_issues_v2_tokens_with_scope_and_role" {
  command = plan
  assert {
    condition     = azuread_application.api.api[0].requested_access_token_version == 2
    error_message = "the API must receive v2 access tokens (aud = client id)"
  }
  assert {
    condition     = one([for s in azuread_application.api.api[0].oauth2_permission_scope : s.value]) == "api.access"
    error_message = "exactly one delegated scope api.access"
  }
  assert {
    condition     = one([for r in azuread_application.api.app_role : r.value]) == "Admin" && one([for r in azuread_application.api.app_role : r.allowed_member_types]) == toset(["User"])
    error_message = "one user-assignable app role Admin"
  }
  assert {
    condition     = contains([for c in azuread_application.api.optional_claims[0].access_token : c.name], "email")
    error_message = "the API access token carries the email claim (display only)"
  }
}

run "web_has_exactly_the_callback_and_signed_out_uris" {
  command = plan
  assert {
    condition     = toset(azuread_application.web.web[0].redirect_uris) == toset(["https://web.example.test/auth/callback", "https://web.example.test/auth/signed-out"])
    error_message = "exactly two redirect URIs: the callback and the post-logout landing (post_logout_redirect_uri must be registered)"
  }
  assert {
    condition     = azuread_application.web.web[0].logout_url == null
    error_message = "no front-channel logout URL (a cross-site iframe GET would not carry the Lax cookies anyway)"
  }
  assert {
    condition     = azuread_application.web.web[0].implicit_grant[0].access_token_issuance_enabled == false && azuread_application.web.web[0].implicit_grant[0].id_token_issuance_enabled == false
    error_message = "no implicit grant"
  }
}

run "deleter_has_only_the_two_graph_roles" {
  command = plan
  assert {
    condition     = length(azuread_application.deleter.required_resource_access) == 1 && length(one(azuread_application.deleter.required_resource_access).resource_access) == 2
    error_message = "deleter: Graph User.ReadWrite.All and User.DeleteRestore.All only"
  }
}

run "rejects_http_base_url" {
  command = plan
  variables { web_base_url = "http://web.example.test" }
  expect_failures = [var.web_base_url]
}

run "owners_are_the_deployer_not_the_caller" {
  command = plan
  assert {
    condition     = azuread_application.api.owners == toset(["00000000-0000-0000-0000-0000000000aa"]) && azuread_application.web.owners == toset(["00000000-0000-0000-0000-0000000000aa"]) && azuread_application.deleter.owners == toset(["00000000-0000-0000-0000-0000000000aa"])
    error_message = "all three apps are owned by the deployer service principal looked up by client id"
  }
}

run "rejects_wildcard_host" {
  command = plan
  variables { web_base_url = "https://*.example.test" }
  expect_failures = [var.web_base_url]
}

run "rejects_port" {
  command = plan
  variables { web_base_url = "https://web.example.test:8443" }
  expect_failures = [var.web_base_url]
}
