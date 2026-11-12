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
