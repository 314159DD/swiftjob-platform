# Scheduled work (spec 3, decision 5). One execution runs one command and exits; the image prints a JOB_RESULT
# line that the alerts read. A job with enabled = false gets a manual trigger: it exists, can be started by hand
# (az containerapp job start) and never runs on its own.
# Jobs live in the Container Apps environment, so they use compute_location (ADR 8), not location.
resource "azurerm_container_app_job" "this" {
  for_each                     = var.apps_enabled ? var.jobs : {}
  name                         = "job-${var.environment}-${each.key}"
  location                     = var.compute_location
  resource_group_name          = data.azurerm_resource_group.this.name
  container_app_environment_id = azurerm_container_app_environment.this.id
  workload_profile_name        = "Consumption"
  replica_timeout_in_seconds   = each.value.timeout_seconds
  replica_retry_limit          = each.value.retry_limit
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.this[each.value.identity].id]
  }

  dynamic "schedule_trigger_config" {
    for_each = each.value.enabled && each.value.cron != null ? [each.value.cron] : []
    content {
      cron_expression          = schedule_trigger_config.value
      parallelism              = 1
      replica_completion_count = 1
    }
  }

  dynamic "manual_trigger_config" {
    for_each = each.value.enabled && each.value.cron != null ? [] : [1]
    content {
      parallelism              = 1
      replica_completion_count = 1
    }
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

  template {
    container {
      name    = "main"
      image   = lookup(var.images, each.value.image, each.value.image)
      command = each.value.command
      args    = each.value.args
      cpu     = each.value.cpu
      memory  = each.value.memory
      dynamic "env" {
        for_each = merge(each.value.env, lookup(local.pg_env, each.value.identity, {}), {
          AZURE_CLIENT_ID = azurerm_user_assigned_identity.this[each.value.identity].client_id
          JOB_NAME        = each.key
        })
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
    }
  }

  lifecycle {
    precondition {
      condition     = alltrue([for s in values(each.value.secret_env) : contains(try(var.secrets[s].readers, []), each.value.identity)])
      error_message = "a job references a secret its identity is not listed to read"
    }
    precondition {
      condition     = contains(keys(var.images), each.value.image) || strcontains(each.value.image, "/")
      error_message = "image key has no digest yet"
    }
  }

  depends_on = [azurerm_role_assignment.secret_reader]
}
