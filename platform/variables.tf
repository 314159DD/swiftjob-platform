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
