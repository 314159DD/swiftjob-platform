data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

data "azurerm_client_config" "current" {}

locals {
  name      = "swiftjob-${var.environment}"
  env_short = lookup({ staging = "stg", prod = "prd", nettest = "net" }, var.environment, substr(var.environment, 0, 3))
  suffix    = substr(sha1("${data.azurerm_resource_group.this.id}${var.name_salt}"), 0, 6)
  tags = {
    project = "swiftjob"
    env     = var.environment
    owner   = "steven"
  }
  arm = "https://management.azure.com"
}
