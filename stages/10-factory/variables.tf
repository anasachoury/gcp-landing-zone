# Every stage declares the same core interface so CI and the Makefile can
# pass one uniform set of variables regardless of stage. org_id is declared
# for uniformity; folder placement comes from the 01-org stage outputs.

variable "org_id" {
  description = "Google Cloud organization id (unused by this stage; part of the uniform stage interface)."
  type        = string
  default     = ""
}

variable "billing_account" {
  description = "Billing account id attached to every factory project."
  type        = string
}

variable "prefix" {
  description = "Short prefix for resource names."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,14}$", var.prefix))
    error_message = "prefix must be 2-15 characters: lowercase letters, digits, hyphens; must start with a letter."
  }
}

variable "state_bucket" {
  description = "Terraform state bucket (used to read the 01-org and 02-networking outputs)."
  type        = string
}

variable "currency" {
  description = "Currency code for project budgets."
  type        = string
  default     = "USD"
}
