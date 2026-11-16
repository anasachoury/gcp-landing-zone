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

output "break_glass_accounts" {
  description = "Emergency accounts watched by the break-glass alerting in stage 03-security."
  value       = yamldecode(file("${path.module}/../../catalogs/groups.yaml")).break_glass.accounts
}

output "log_buckets" {
  description = "Map of audit log bucket id to its resource name."
  value       = { for id, b in google_logging_project_bucket_config.buckets : id => b.name }
}

output "audit_bigquery_dataset" {
  description = "BigQuery dataset receiving the audit log export (empty when the export is disabled)."
  value       = local.export_bq ? google_bigquery_dataset.audit_export[0].dataset_id : ""
}

output "audit_pubsub_topic" {
  description = "Pub/Sub topic receiving the streaming audit feed (empty when the export is disabled)."
  value       = local.export_pubsub ? google_pubsub_topic.audit_feed[0].name : ""
}

output "tag_value_ids" {
  description = "Map of '<key>/<value>' to tag value id, for binding tags to projects."
  value       = { for k, v in google_tags_tag_value.values : k => v.id }
}
