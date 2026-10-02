terraform {
  required_version = "~> 1.16"
  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.10"
    }
  }
}
