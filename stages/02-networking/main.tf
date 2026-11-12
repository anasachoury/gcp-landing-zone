provider "google" {}

# Folders and the central logging project come from stage 01-org.
data "terraform_remote_state" "org" {
  backend = "gcs"
  config = {
    bucket = var.state_bucket
    prefix = "landing-zone/01-org"
  }
}

locals {
  catalog = yamldecode(file("${path.module}/../../catalogs/networks.yaml"))

  groups       = yamldecode(file("${path.module}/../../catalogs/groups.yaml")).groups
  group_emails = { for g in local.groups : g.id => g.email }

  subnet_regions = distinct([for s in local.catalog.subnets : s.region])
  subnets_map    = { for s in local.catalog.subnets : "${s.region}/${s.name}" => s }
  nat_regions    = try(local.catalog.nat.enabled, true) ? local.subnet_regions : []
}

# --- Shared VPC host project -------------------------------------------------

resource "google_project" "host" {
  name            = "${var.prefix}-net-host"
  project_id      = "${var.prefix}-net-host"
  billing_account = var.billing_account
  folder_id       = data.terraform_remote_state.org.outputs.folder_names["common"]
  deletion_policy = "PREVENT"
  labels = {
    managed_by = "terraform"
    stage      = "02-networking"
  }
}

resource "google_project_service" "host_services" {
  for_each           = toset(["compute.googleapis.com", "dns.googleapis.com"])
  project            = google_project.host.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_compute_shared_vpc_host_project" "host" {
  project    = google_project.host.project_id
  depends_on = [google_project_service.host_services]
}

# Convention: the network-admins group id from catalogs/groups.yaml gets
# project-level network admin on the host project.
resource "google_project_iam_member" "network_admins" {
  project = google_project.host.project_id
  role    = "roles/compute.networkAdmin"
  member  = "group:${local.group_emails["network-admins"]}"
}

# --- VPC, subnets ------------------------------------------------------------

resource "google_compute_network" "vpc" {
  name                    = local.catalog.vpc.name
  description             = try(local.catalog.vpc.description, null)
  project                 = google_project.host.project_id
  auto_create_subnetworks = false
  routing_mode            = try(local.catalog.vpc.routing_mode, "REGIONAL")
  depends_on              = [google_project_service.host_services]
}

resource "google_compute_subnetwork" "subnets" {
  for_each = local.subnets_map

  project                  = google_project.host.project_id
  region                   = each.value.region
  name                     = each.value.name
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = each.value.ip_cidr_range
  private_ip_google_access = true

  dynamic "secondary_ip_range" {
    for_each = try(each.value.secondary_ranges, [])
    content {
      range_name    = secondary_ip_range.value.range_name
      ip_cidr_range = secondary_ip_range.value.ip_cidr_range
    }
  }

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }

  depends_on = [google_project_service.host_services]
}

# --- Egress (Cloud NAT) ------------------------------------------------------

resource "google_compute_router" "routers" {
  for_each = toset(local.nat_regions)

  name    = "${var.prefix}-router-${each.value}"
  project = google_project.host.project_id
  region  = each.value
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  for_each = toset(local.nat_regions)

  name    = "${var.prefix}-nat-${each.value}"
  project = google_project.host.project_id
  region  = each.value
  router  = google_compute_router.routers[each.value].name

  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# --- Private DNS -------------------------------------------------------------

resource "google_dns_managed_zone" "private" {
  count = try(local.catalog.dns.private_zone, null) != null ? 1 : 0

  name        = local.catalog.dns.private_zone.name
  project     = google_project.host.project_id
  dns_name    = local.catalog.dns.private_zone.dns_name
  description = "Private zone for the shared VPC"
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.vpc.id
    }
  }

  depends_on = [google_project_service.host_services]
}

# --- Hierarchical firewall policy ---------------------------------------------
# Org-level rules attached to the VPC. Baseline: no public SSH/RDP (IAP only),
# everything allowed from internal ranges. Egress is intentionally left open;
# tighten with deny rules once your egress requirements are known.

resource "google_compute_firewall_policy" "org" {
  parent      = "organizations/${var.org_id}"
  short_name  = "${var.prefix}-ingress"
  description = "Baseline ingress rules for the shared VPC"
}

resource "google_compute_firewall_policy_rule" "iap_ssh" {
  firewall_policy = google_compute_firewall_policy.org.id
  priority        = 1000
  action          = "allow"
  direction       = "INGRESS"
  description     = "SSH via IAP (gcloud compute ssh)"

  match {
    src_ip_ranges = ["35.235.240.0/20"]
    layer4_configs {
      ip_protocol = "tcp"
      ports       = ["22"]
    }
  }
}

resource "google_compute_firewall_policy_rule" "iap_rdp" {
  firewall_policy = google_compute_firewall_policy.org.id
  priority        = 1010
  action          = "allow"
  direction       = "INGRESS"
  description     = "RDP via IAP"

  match {
    src_ip_ranges = ["35.235.240.0/20"]
    layer4_configs {
      ip_protocol = "tcp"
      ports       = ["3389"]
    }
  }
}

resource "google_compute_firewall_policy_rule" "deny_public_ssh_rdp" {
  firewall_policy = google_compute_firewall_policy.org.id
  priority        = 1100
  action          = "deny"
  direction       = "INGRESS"
  description     = "Deny public SSH/RDP"
  enable_logging  = true

  match {
    src_ip_ranges = ["0.0.0.0/0"]
    layer4_configs {
      ip_protocol = "tcp"
      ports       = ["22", "3389"]
    }
  }
}

resource "google_compute_firewall_policy_rule" "allow_internal" {
  firewall_policy = google_compute_firewall_policy.org.id
  priority        = 2000
  action          = "allow"
  direction       = "INGRESS"
  description     = "Allow ingress from internal ranges"

  match {
    src_ip_ranges = local.catalog.internal_source_ranges
    layer4_configs {
      ip_protocol = "all"
    }
  }
}

resource "google_compute_firewall_policy_association" "vpc" {
  name              = "${var.prefix}-vpc-ingress"
  firewall_policy   = google_compute_firewall_policy.org.id
  attachment_target = google_compute_network.vpc.id
}
