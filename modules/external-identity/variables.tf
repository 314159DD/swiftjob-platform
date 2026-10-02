variable "environment" {
  type = string
}

variable "web_base_url" {
  description = "Public HTTPS base URL of the web app, without a trailing slash."
  type        = string
  validation {
    condition     = can(regex("^https://[^/]+$", var.web_base_url))
    error_message = "web_base_url must be https://host without a path."
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
