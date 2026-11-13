output "environment_name" {
  description = "The gated environment name (for deploy.yml)."
  value       = github_repository_environment.landing_zone.environment
}

output "reviewers" {
  description = "Configured reviewers: user logins and team slugs."
  value = {
    users = var.reviewer_users
    teams = var.reviewer_teams
  }
}
