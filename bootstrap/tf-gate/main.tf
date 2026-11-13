provider "github" {
  owner = var.github_owner
  # Classic PAT (repo scope) or fine-grained token with Environments
  # read/write permission on this repository. Used only while the gate is
  # created or changed; never committed anywhere (see bootstrap/README.md).
  token = var.github_token
}

# The environment API wants numeric IDs; resolve them from logins/slugs so
# the bootstrap command stays human-readable.
data "github_user" "reviewers" {
  for_each = toset(var.reviewer_users)
  username = each.key
}

data "github_team" "reviewers" {
  for_each = toset(var.reviewer_teams)
  slug     = each.key
}

locals {
  reviewer_user_ids = [for u in data.github_user.reviewers : tonumber(u.id)]
  reviewer_team_ids = [for t in data.github_team.reviewers : tonumber(t.id)]
}

resource "github_repository_environment" "landing_zone" {
  repository  = var.github_repo
  environment = var.environment

  # The two-human rule: whoever pushed to main cannot approve the apply
  # themselves. Solo operators MUST set prevent_self_review = false (or add
  # a second human), otherwise applies wait for an approval that can never
  # come.
  prevent_self_review = var.prevent_self_review

  # Repository admins wait for review like everyone else.
  can_admins_bypass = var.can_admins_bypass

  wait_timer = var.wait_timer

  # Always emitted (with empty lists when a side is unused) so this resource
  # is the source of truth: removing a reviewer here removes it on GitHub.
  reviewers {
    users = local.reviewer_user_ids
    teams = local.reviewer_team_ids
  }

  # Optional: further restrict which branches may deploy. Off by default —
  # enable protected_branches = true once branch protection exists on main,
  # otherwise deploys from unprotected branches are blocked by GitHub.
  dynamic "deployment_branch_policy" {
    for_each = length(keys(var.deployment_branch_policy)) > 0 ? [var.deployment_branch_policy] : []
    content {
      protected_branches     = deployment_branch_policy.value.protected_branches
      custom_branch_policies = deployment_branch_policy.value.custom_branch_policies
    }
  }

  lifecycle {
    precondition {
      condition     = length(local.reviewer_user_ids) + length(local.reviewer_team_ids) > 0
      error_message = "At least one reviewer (user or team) is required: the landing-zone environment must gate applies. Solo operator? Set yourself as the reviewer and pass prevent_self_review = false."
    }
  }
}
