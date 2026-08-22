locals {
  required_services = toset([
    "aiplatform.googleapis.com",
    "bigquery.googleapis.com",
    "compute.googleapis.com",
    "dataform.googleapis.com",
    "iam.googleapis.com",
    "storage.googleapis.com",
    "serviceusage.googleapis.com"
  ])
}

resource "google_project_service" "required" {
  for_each = local.required_services

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# Reuse the existing corporate VPC. The foundation intentionally does not create
# a new network so Colab runtimes can stay on the same private data-lake path.
data "google_compute_network" "existing" {
  project = var.network_project_id
  name    = var.network_name

  depends_on = [google_project_service.required]
}

data "google_compute_subnetwork" "existing" {
  project = var.network_project_id
  region  = var.region
  name    = var.subnetwork_name

  depends_on = [google_project_service.required]
}

# Fail early when a private-only runtime is expected but the selected subnet
# is not the intended one. Private Google Access itself is not modified here
# because the subnet can be shared by other production workloads.
check "runtime_network" {
  assert {
    condition     = data.google_compute_network.existing.id != "" && data.google_compute_subnetwork.existing.id != ""
    error_message = "Colab runtime VPC/subnet could not be resolved. Check Shared VPC host project, region and names."
  }
}
