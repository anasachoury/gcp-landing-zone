output "kms_key_ring" {
  description = "Self link of the landing zone key ring."
  value       = google_kms_key_ring.lz.id
}

output "kms_key" {
  description = "Self link of the CMEK-ready key."
  value       = google_kms_crypto_key.cmek.id
}

output "sensitive_change_alert" {
  description = "Name of the break-glass / sensitive-change alert policy."
  value       = google_monitoring_alert_policy.sensitive_org_changes.name
}

output "break_glass_alert" {
  description = "Name of the alert policy that fires on any break-glass account activity."
  value       = google_monitoring_alert_policy.break_glass_activity.name
}

output "scc_findings_topic" {
  description = "Pub/Sub topic streaming high and critical SCC findings (empty when SCC is disabled)."
  value       = var.enable_scc ? google_pubsub_topic.scc_findings[0].name : ""
}

output "scc_findings_dataset" {
  description = "BigQuery dataset holding the continuous SCC findings export (empty when SCC is disabled)."
  value       = var.enable_scc ? google_bigquery_dataset.scc_findings[0].dataset_id : ""
}

output "vpc_sc_perimeter" {
  description = "Name of the VPC-SC perimeter (empty when VPC-SC is disabled)."
  value       = var.enable_vpc_sc ? google_access_context_manager_service_perimeter.production[0].name : ""
}
