# PostgreSQL flexible server, Entra ID sign-in only (spec 3, ADR 6, ADR 9). No database is created here: the
# migration job creates it with its own owner role and maps the workload identities to roles.
locals {
  pg_enabled = var.postgres != null
  pg_users   = local.pg_enabled ? toset(concat(var.postgres.users, [var.postgres.admin_identity])) : toset([])
  pg_env = {
    for id in local.pg_users : id => {
      PGHOST        = azurerm_postgresql_flexible_server.this[0].fqdn
      PGPORT        = "5432"
      PGDATABASE    = var.postgres.database
      PGUSER        = azurerm_user_assigned_identity.this[id].name
      PGSSLMODE     = "verify-full"
      PGSSLROOTCERT = "system"
    }
  }
  pg_refs = { for id, mi in azurerm_user_assigned_identity.this : "@principal:${id}" => "${mi.name}|${mi.principal_id}" }
}

resource "azurerm_postgresql_flexible_server" "this" {
  #checkov:skip=CKV_AZURE_136:No geo-redundant backup before revenue; 7 days of local backups (ADR 9)
  #checkov:skip=CKV2_AZURE_57:No private endpoint before revenue (ADR 6); private endpoints are denied by policy
  count                         = local.pg_enabled ? 1 : 0
  name                          = "psql-${local.name}-${local.suffix}"
  resource_group_name           = data.azurerm_resource_group.this.name
  location                      = var.postgres.location
  version                       = var.postgres.version
  sku_name                      = var.postgres.sku_name
  storage_mb                    = var.postgres.storage_mb
  storage_tier                  = "P4"
  auto_grow_enabled             = false
  backup_retention_days         = 7
  geo_redundant_backup_enabled  = false
  public_network_access_enabled = true # ADR 6: identity is the boundary until the VNet switch
  tags                          = local.tags

  # Always sent on create and restore: the Entra-only policy fails closed without it (ADR 5).
  authentication {
    active_directory_auth_enabled = true
    password_auth_enabled         = false
    tenant_id                     = data.azurerm_client_config.current.tenant_id
  }

  lifecycle {
    ignore_changes = [zone] # Azure picks a zone; a change would recreate the server
  }
}

# Azure changes one administrator at a time; the owner entry waits for the migration identity.
resource "azurerm_postgresql_flexible_server_active_directory_administrator" "migrate" {
  count               = local.pg_enabled ? 1 : 0
  server_name         = azurerm_postgresql_flexible_server.this[0].name
  resource_group_name = data.azurerm_resource_group.this.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  object_id           = azurerm_user_assigned_identity.this[var.postgres.admin_identity].principal_id
  principal_name      = azurerm_user_assigned_identity.this[var.postgres.admin_identity].name
  principal_type      = "ServicePrincipal"
}

resource "azurerm_postgresql_flexible_server_active_directory_administrator" "owner" {
  count               = local.pg_enabled && try(var.postgres.owner_admin, null) != null ? 1 : 0
  server_name         = azurerm_postgresql_flexible_server.this[0].name
  resource_group_name = data.azurerm_resource_group.this.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  object_id           = var.postgres.owner_admin.object_id
  principal_name      = var.postgres.owner_admin.principal_name
  principal_type      = var.postgres.owner_admin.principal_type
  depends_on          = [azurerm_postgresql_flexible_server_active_directory_administrator.migrate]
}

resource "azurerm_postgresql_flexible_server_configuration" "tls" {
  for_each  = local.pg_enabled ? { require_secure_transport = "on", ssl_min_protocol_version = "TLSv1.2" } : {}
  name      = each.key
  server_id = azurerm_postgresql_flexible_server.this[0].id
  value     = each.value
}

# Consumption Container Apps without a VNet have no stable outbound address (ADR 9); the token is the boundary.
resource "azurerm_postgresql_flexible_server_firewall_rule" "azure" {
  count            = local.pg_enabled ? 1 : 0
  name             = "allow-azure-services"
  server_id        = azurerm_postgresql_flexible_server.this[0].id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

# Spec 6: CPU, storage and connections of the database, to the e-mail action group.
locals {
  pg_alerts = local.pg_enabled ? {
    cpu         = { metric = "cpu_percent", threshold = 80, text = "CPU above 80 % for 15 minutes." }
    storage     = { metric = "storage_percent", threshold = 80, text = "Storage above 80 %." }
    connections = { metric = "active_connections", threshold = var.postgres.alert_connections, text = "Active connections above ${var.postgres.alert_connections}." }
  } : {}
}

resource "azurerm_monitor_metric_alert" "pg" {
  for_each            = local.pg_alerts
  name                = "alert-${local.name}-pg-${each.key}"
  resource_group_name = data.azurerm_resource_group.this.name
  scopes              = [azurerm_postgresql_flexible_server.this[0].id]
  description         = each.value.text
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"
  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = each.value.metric
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = each.value.threshold
  }
  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
  tags = local.tags
}
