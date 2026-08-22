resource "google_service_account" "im_exec" {
  project      = var.project_id
  account_id   = var.im_exec_account_id
  display_name = "Infrastructure Manager Colab execution"
}

resource "google_service_account" "adapter" {
  project      = var.project_id
  account_id   = var.adapter_account_id
  display_name = "Cloud Run Infrastructure Manager adapter"
}

locals {
  # Reference/PoC roles. In production, replace broad admin roles with a custom
  # role constrained to the exact Colab/BigQuery/GCS resources and projects.
  im_exec_roles = toset([
    "roles/config.agent",
    "roles/aiplatform.admin",
    "roles/bigquery.admin",
    "roles/storage.admin",
    "roles/compute.networkViewer",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.securityAdmin",
    "roles/resourcemanager.projectIamAdmin",
    "roles/serviceusage.serviceUsageAdmin"
  ])
}

resource "google_project_iam_member" "im_exec_roles" {
  for_each = local.im_exec_roles

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.im_exec.email}"
}

resource "google_project_iam_member" "adapter_config_admin" {
  project = var.project_id
  role    = "roles/config.admin"
  member  = "serviceAccount:${google_service_account.adapter.email}"
}

# Cloud Run adapter asks Infrastructure Manager to execute Terraform as im_exec.
resource "google_service_account_iam_member" "adapter_act_as_im_exec" {
  service_account_id = google_service_account.im_exec.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.adapter.email}"
}
