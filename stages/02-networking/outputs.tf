output "host_project_id" {
  description = "Shared VPC host project id."
  value       = google_project.host.project_id
}

output "host_project_number" {
  description = "Shared VPC host project number."
  value       = google_project.host.number
}

output "network_id" {
  description = "Self link of the shared VPC network."
  value       = google_compute_network.vpc.id
}

output "subnet_self_links" {
  description = "Map of '<region>/<name>' to subnet self link."
  value       = { for k, s in google_compute_subnetwork.subnets : k => s.id }
}

output "regions" {
  description = "Regions with subnets in this VPC."
  value       = local.subnet_regions
}
