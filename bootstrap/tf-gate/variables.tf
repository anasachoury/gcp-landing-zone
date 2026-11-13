variable "github_owner" {
  description = "GitHub owner (user or organization) of the pipeline repository."
  type        = string
}

variable "github_repo" {
  description = "Name of the repository that runs the landing zone pipelines."
  type        = string
}

variable "github_token" {
  description = <<-EOT
    Token used to configure the environment: a classic PAT with repo scope,
    or a fine-grained token with Environments read/write on this repository.
    Passing it as an environment variable (TF_VAR_github_token) avoids
    leaving it in shell history.
  EOT
  type        = string
  sensitive   = true
}

variable "environment" {
  description = "Name of the deployment environment the apply job uses (deploy.yml)."
  type        = string
  default     = "landing-zone"
}

variable "reviewer_users" {
  description = <<-EOT
    GitHub usernames (logins) who may approve applies. At least one reviewer
    (user or team) is required. Reviewers need at least read access to the
    repository; a team is preferable for organizations so membership, not
    this Terraform, manages who is on call.
  EOT
  type        = list(string)
  default     = []
}

variable "reviewer_teams" {
  description = "GitHub team slugs (within the repository owner) who may approve applies."
  type        = list(string)
  default     = []
}

variable "prevent_self_review" {
  description = <<-EOT
    When true, the person who pushed cannot approve the apply — this is what
    makes the gate a two-human rule. Leave true for teams. A solo operator
    must set it to false (with themselves as reviewer), accepting a
    one-human click-through gate, or applies will wait forever.
  EOT
  type        = bool
  default     = true
}

variable "can_admins_bypass" {
  description = "Whether repository admins may bypass the environment protections. Keep false: the gate is meaningless if the people with push access can skip it."
  type        = bool
  default     = false
}

variable "wait_timer" {
  description = "Minutes the apply waits before reviewers may approve (0-43200). Optional cool-down window."
  type        = number
  default     = 0
}

variable "deployment_branch_policy" {
  description = <<-EOT
    Optional restriction on which branches may deploy: set
    { protected_branches = true } once branch protection exists on main
    (the apply job only runs on main anyway). Default {} = no restriction.
  EOT
  type = object({
    protected_branches     = optional(bool, true)
    custom_branch_policies = optional(bool, false)
  })
  default = {}
}
