variable "subscription_id" {
  description = "The subscription that holds the platform resources and the budget."
  type        = string
}

variable "location" {
  description = "Region for platform resources."
  type        = string
  default     = "germanywestcentral"
}

variable "root_management_group_name" {
  description = "Management group created by scripts/bootstrap.sh and imported here."
  type        = string
  default     = "mg-swiftjob"
}

variable "log_daily_quota_gb" {
  description = "Hard daily ingestion cap of the central workspace. Beyond 5 GB a month every GB is billed."
  type        = number
  default     = 0.1
}

variable "budget_amount" {
  description = "Monthly safety-net budget for the whole subscription, in the billing currency (EUR)."
  type        = number
  default     = 25
}

variable "budget_start_date" {
  description = "First day of the budget period, RFC 3339. Must be the first of a month."
  type        = string
  default     = "2026-10-01T00:00:00Z"
}

variable "budget_alert_email" {
  description = "Recipient of budget alerts. Comes from a repository secret."
  type        = string
  sensitive   = true
}
