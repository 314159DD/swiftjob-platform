locals {
  app_fqdn = { for k, _ in var.apps : k => "ca-${local.name}-${k}.${azurerm_container_app_environment.this.default_domain}" }
  refs = merge(
    { for k, f in local.app_fqdn : "@url:${k}" => "https://${f}" },
    {
      "@appinsights" = azurerm_application_insights.this.connection_string
      "@keyvault"    = azurerm_key_vault.this.vault_uri
      "@blob"        = azurerm_storage_account.this.primary_blob_endpoint
    }
  )
}

resource "azurerm_container_app" "this" {
  for_each                     = var.apps_enabled ? var.apps : {}
  name                         = "ca-${local.name}-${each.key}"
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = data.azurerm_resource_group.this.name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.this[each.value.identity].id]
  }

  dynamic "registry" {
    for_each = var.registry != null && contains(keys(var.images), each.value.image) ? [var.registry] : []
    content {
      server               = registry.value.server
      username             = registry.value.username
      password_secret_name = registry.value.password_secret
    }
  }

  dynamic "secret" {
    for_each = toset(concat(values(each.value.secret_env),
    var.registry != null && contains(keys(var.images), each.value.image) ? [var.registry.password_secret] : []))
    content {
      name                = secret.value
      key_vault_secret_id = local.secret_uri[secret.value]
      identity            = azurerm_user_assigned_identity.this[each.value.identity].id
    }
  }

  ingress {
    external_enabled           = true
    target_port                = each.value.port
    transport                  = "auto"
    allow_insecure_connections = false
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = each.value.min_replicas
    max_replicas = each.value.max_replicas
    container {
      name   = each.key
      image  = lookup(var.images, each.value.image, each.value.image)
      cpu    = each.value.cpu
      memory = each.value.memory
      dynamic "env" {
        for_each = merge(each.value.env, { AZURE_CLIENT_ID = azurerm_user_assigned_identity.this[each.value.identity].client_id })
        content {
          name  = env.key
          value = lookup(local.refs, env.value, env.value)
        }
      }
      dynamic "env" {
        for_each = each.value.secret_env
        content {
          name        = env.key
          secret_name = env.value
        }
      }
      dynamic "startup_probe" {
        for_each = each.value.health_path == null ? [] : [each.value.health_path]
        content {
          transport               = "HTTP"
          port                    = each.value.port
          path                    = startup_probe.value
          initial_delay           = 30
          interval_seconds        = 10
          failure_count_threshold = 10 # provider maximum; about 130 seconds for a cold start
        }
      }
      dynamic "liveness_probe" {
        for_each = each.value.health_path == null ? [] : [each.value.health_path]
        content {
          transport               = "HTTP"
          port                    = each.value.port
          path                    = liveness_probe.value
          interval_seconds        = 30
          failure_count_threshold = 3
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition     = alltrue([for s in values(each.value.secret_env) : contains(try(var.secrets[s].readers, []), each.value.identity)])
      error_message = "an app references a secret its identity is not listed to read"
    }
    precondition {
      condition     = contains(keys(var.images), each.value.image) || strcontains(each.value.image, "/")
      error_message = "image key has no digest yet"
    }
  }

  depends_on = [azurerm_role_assignment.secret_reader]
}
