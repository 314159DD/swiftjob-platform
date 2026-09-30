# Automatic stop for runaway cost, as in the A1 project (ADR 4 there):
#   budget at 100 % actual spend -> action group -> Logic App (managed identity) -> POST .../stop on every
#   container app in this resource group. The database and the jobs stay.
# The Logic App lists the apps at run time, so it needs no change when apps are added.
# Re-enable after investigating: az containerapp start (or POST .../start) per app.
locals {
  aca_api = "2024-03-01"
}

resource "azurerm_logic_app_workflow" "killswitch" {
  name                = "logic-${local.name}-killswitch"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.this.name
  identity {
    type = "SystemAssigned"
  }
  tags = local.tags
}

resource "azurerm_logic_app_trigger_http_request" "alert" {
  name         = "alert"
  logic_app_id = azurerm_logic_app_workflow.killswitch.id
  schema       = jsonencode({})
}

resource "azurerm_logic_app_action_custom" "stop" {
  name         = "unlessResolved"
  logic_app_id = azurerm_logic_app_workflow.killswitch.id
  # Action groups also call the Logic App when an alert resolves; only act when it is not "Resolved" (A1 finding).
  body = jsonencode({
    type = "If"
    expression = {
      and = [{ not = { equals = ["@coalesce(triggerBody()?['data']?['essentials']?['monitorCondition'], '')", "Resolved"] } }]
    }
    actions = {
      listApps = {
        type = "Http"
        inputs = {
          method         = "GET"
          uri            = "${local.arm}${data.azurerm_resource_group.this.id}/providers/Microsoft.App/containerApps?api-version=${local.aca_api}"
          authentication = { type = "ManagedServiceIdentity", audience = "${local.arm}/" }
        }
      }
      stopEach = {
        type     = "Foreach"
        foreach  = "@body('listApps')?['value']"
        runAfter = { listApps = ["Succeeded"] }
        actions = {
          stop = {
            type = "Http"
            inputs = {
              method         = "POST"
              uri            = "@{concat('${local.arm}', items('stopEach')?['id'], '/stop?api-version=${local.aca_api}')}"
              authentication = { type = "ManagedServiceIdentity", audience = "${local.arm}/" }
            }
          }
        }
      }
    }
    else = { actions = {} }
  })
}

resource "azurerm_role_assignment" "killswitch" {
  scope                = data.azurerm_resource_group.this.id
  role_definition_name = "swiftjob-containerapp-stopper" # custom role from scripts/bootstrap.sh
  principal_id         = azurerm_logic_app_workflow.killswitch.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_monitor_action_group" "killswitch" {
  name                = "ag-${local.name}-killswitch"
  resource_group_name = data.azurerm_resource_group.this.name
  short_name          = "sj${local.env_short}kill"
  location            = "global"
  email_receiver {
    name                    = "owner"
    email_address           = var.alert_email
    use_common_alert_schema = true
  }
  logic_app_receiver {
    name                    = "stop-container-apps"
    resource_id             = azurerm_logic_app_workflow.killswitch.id
    callback_url            = azurerm_logic_app_trigger_http_request.alert.callback_url # trigger URL, not the workflow URL (A1 finding)
    use_common_alert_schema = true
  }
  tags = local.tags
}

resource "azurerm_consumption_budget_resource_group" "this" {
  name              = "budget-${local.name}"
  resource_group_id = data.azurerm_resource_group.this.id
  amount            = var.budget_amount
  time_grain        = "Monthly"
  time_period {
    start_date = var.budget_start_date
  }
  notification {
    enabled        = true
    threshold      = 50
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [var.alert_email]
  }
  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [var.alert_email]
  }
  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = [var.alert_email]
  }
  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThanOrEqualTo"
    threshold_type = "Actual"
    contact_emails = [var.alert_email]
    contact_groups = [azurerm_monitor_action_group.killswitch.id]
  }
}
