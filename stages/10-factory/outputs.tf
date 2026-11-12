output "project_ids" {
  description = "Map of '<app>-<environment>' to project id."
  value       = { for k, p in google_project.projects : k => p.project_id }
}

output "project_numbers" {
  description = "Map of '<app>-<environment>' to project number."
  value       = { for k, p in google_project.projects : k => p.number }
}

output "service_account_emails" {
  description = "Map of '<app>-<env>#<sa id>' to service account email."
  value       = { for k, sa in google_service_account.project_sas : k => sa.email }
}
