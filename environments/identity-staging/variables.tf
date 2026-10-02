# Values come from the private configuration (staging/identity.auto.tfvars) and the workflow (identity_role).
variable "external_tenant_id" {
  type = string
}

variable "tf_identity_client_id" {
  description = "Client id of the identity that may change app registrations (apply job)."
  type        = string
}

variable "tf_identity_plan_client_id" {
  description = "Client id of the read-only identity (plan job)."
  type        = string
}

variable "identity_role" {
  description = "plan or apply: selects which of the two identities the provider signs in as."
  type        = string
  validation {
    condition     = contains(["plan", "apply"], var.identity_role)
    error_message = "identity_role must be plan or apply."
  }
}

variable "web_base_url" {
  type = string
}

variable "admin_role_id" {
  type = string
}

variable "scope_id" {
  type = string
}
