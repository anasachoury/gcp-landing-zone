output "folder_ids" {
  description = "Map of folder catalog name to numeric folder id."
  value       = { for name, f in google_folder.folders : name => f.folder_id }
}

output "folder_names" {
  description = "Map of folder catalog name to folder resource name (folders/<id>)."
  value       = { for name, f in google_folder.folders : name => f.name }
}

output "logging_project_id" {
  description = "Central logging project id."
  value       = google_project.logging.project_id
}

output "logging_project_number" {
  description = "Central logging project number."
  value       = google_project.logging.number
}

output "group_emails" {
  description = "Map of group id to group email."
  value       = local.group_emails
}

output "admin_group_email" {
  description = "Email of the admin group (essential contacts, budget alerts)."
  value       = local.admin_email
}
