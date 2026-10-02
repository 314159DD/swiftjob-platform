variable "environment" {
  type = string
}

variable "web_base_url" {
  description = "Public HTTPS base URL of the web app, without a trailing slash."
  type        = string
  validation {
    condition     = can(regex("^https://[a-z0-9]([a-z0-9.-]*[a-z0-9])?$", var.web_base_url))
    error_message = "web_base_url must be https://host (lowercase, no path, port, user info or wildcard)."
  }
}

variable "admin_role_id" {
  description = "Fixed UUID of the Admin app role (kept stable across applies)."
  type        = string
}

variable "scope_id" {
  description = "Fixed UUID of the api.access scope."
  type        = string
}

variable "owner_client_id" {
  description = "Client id of the apply identity (tf-identity-staging); it owns the registrations regardless of who runs the plan."
  type        = string
}
