locals {
  raw_task_slug = trim(replace(lower(var.task_id), "/[^a-z0-9-]/", "-"), "-")
  task_slug     = trim(substr(local.raw_task_slug != "" ? local.raw_task_slug : "data-model-task", 0, 40), "-")
  group_label   = substr(replace(lower(var.group), "/[^a-z0-9_-]/", "_"), 0, 63)

  team_users = [for u in split(",", var.team_users_csv) : trimspace(lower(u)) if trimspace(u) != ""]
  task_users = distinct(compact(concat([trimspace(lower(var.request_user))], local.team_users)))

  runtime_template_name = trim(substr("rtpl-${local.task_slug}", 0, 63), "-")
  workspace_bucket_name = trim(substr("${lower(var.target_project_id)}-${local.task_slug}-colab", 0, 63), "-")
  task_sa_account_id     = trim(substr("colab-${local.task_slug}", 0, 30), "-")

  request_user_dataset_role = {
    viewer = "roles/bigquery.dataViewer"
    editor = "roles/bigquery.dataEditor"
    owner  = "roles/bigquery.dataOwner"
  }[lower(var.bigquery_role)]

  common_labels = {
    managed_by = "infra-manager"
    task_id    = substr(replace(local.task_slug, "-", "_"), 0, 63)
    task_group = local.group_label
  }
}

data "google_compute_network" "runtime" {
  project = var.network_project_id
  name    = var.network_name
}

data "google_compute_subnetwork" "runtime" {
  project = var.network_project_id
  region  = var.colab_location
  name    = var.subnetwork_name
}

resource "google_bigquery_dataset" "task" {
  project                    = var.target_project_id
  dataset_id                 = var.dataset_id
  friendly_name              = var.task_name
  description                = "Colab Enterprise data-model workspace dataset for ${var.task_id}"
  location                   = var.bq_location
  delete_contents_on_destroy = var.allow_destroy_data
  labels                     = local.common_labels
}

resource "google_storage_bucket" "workspace" {
  project                     = var.target_project_id
  name                        = local.workspace_bucket_name
  location                    = var.storage_location
  uniform_bucket_level_access = true
  force_destroy               = var.allow_destroy_data

  labels = local.common_labels

  versioning {
    enabled = true
  }
}

# Optional non-interactive identity for scheduled/batch notebook execution.
# Interactive Colab runtimes use end-user credentials by default.
resource "google_service_account" "task" {
  project      = var.target_project_id
  account_id   = local.task_sa_account_id
  display_name = "Colab task ${var.task_id}"
  description  = "Task service account for scheduled/non-interactive execution; no JSON key is created"
}

resource "google_project_iam_member" "task_sa_bq_job_user" {
  project = var.target_project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.task.email}"
}

resource "google_bigquery_dataset_iam_member" "task_sa_dataset_editor" {
  project    = var.target_project_id
  dataset_id = google_bigquery_dataset.task.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.task.email}"
}

resource "google_storage_bucket_iam_member" "task_sa_workspace" {
  bucket = google_storage_bucket.workspace.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.task.email}"
}

# Approved humans receive only task data access in the data project.
resource "google_project_iam_member" "user_bq_job_user" {
  for_each = toset(local.task_users)

  project = var.target_project_id
  role    = "roles/bigquery.jobUser"
  member  = "user:${each.value}"
}

resource "google_bigquery_dataset_iam_member" "user_dataset" {
  for_each = toset(local.task_users)

  project    = var.target_project_id
  dataset_id = google_bigquery_dataset.task.dataset_id
  role       = local.request_user_dataset_role
  member     = "user:${each.value}"
}

resource "google_storage_bucket_iam_member" "user_workspace" {
  for_each = toset(local.task_users)

  bucket = google_storage_bucket.workspace.name
  role   = "roles/storage.objectUser"
  member = "user:${each.value}"
}

# Colab UI/runtime permissions live in the shared Colab project.
resource "google_project_iam_member" "user_colab" {
  for_each = toset(local.task_users)

  project = var.colab_project_id
  role    = "roles/aiplatform.colabEnterpriseUser"
  member  = "user:${each.value}"
}

resource "google_colab_runtime_template" "task" {
  project      = var.colab_project_id
  location     = var.colab_location
  name         = local.runtime_template_name
  display_name = "${var.task_name} runtime template"
  description  = "Managed Colab Enterprise runtime template for task ${var.task_id}"

  machine_spec {
    machine_type      = var.machine_type
    accelerator_type  = var.accelerator_type != "" ? var.accelerator_type : null
    accelerator_count = var.accelerator_type != "" ? var.accelerator_count : null
  }

  data_persistent_disk_spec {
    disk_type    = var.disk_type
    disk_size_gb = var.disk_size_gb
  }

  network_spec {
    enable_internet_access = var.enable_internet_access
    network                = data.google_compute_network.runtime.id
    subnetwork             = data.google_compute_subnetwork.runtime.id
  }

  idle_shutdown_config {
    idle_timeout = "${var.idle_shutdown_minutes * 60}s"
  }

  euc_config {
    euc_disabled = !var.enable_end_user_credentials
  }

  shielded_vm_config {
    enable_secure_boot = true
  }

  network_tags = ["colab-enterprise", local.task_slug]
  labels       = local.common_labels

  dynamic "encryption_spec" {
    for_each = var.kms_key_name != "" ? [1] : []
    content {
      kms_key_name = var.kms_key_name
    }
  }

  software_config {
    env {
      name  = "DATA_MODEL_TASK_ID"
      value = var.task_id
    }

    env {
      name  = "DATA_MODEL_DATASET"
      value = "${var.target_project_id}.${google_bigquery_dataset.task.dataset_id}"
    }

    env {
      name  = "DATA_MODEL_WORKSPACE_BUCKET"
      value = "gs://${google_storage_bucket.workspace.name}"
    }

    dynamic "post_startup_script_config" {
      for_each = var.startup_script_url != "" ? [1] : []
      content {
        post_startup_script_url      = var.startup_script_url
        post_startup_script_behavior = "RUN_ONCE"
      }
    }

    colab_image {
      release_name = var.colab_release_name
    }
  }
}

data "google_iam_policy" "runtime_template_users" {
  binding {
    role    = "roles/aiplatform.notebookRuntimeUser"
    members = [for email in local.task_users : "user:${email}"]
  }
}

resource "google_colab_runtime_template_iam_policy" "task_users" {
  project          = var.colab_project_id
  location         = var.colab_location
  runtime_template = google_colab_runtime_template.task.name
  policy_data      = data.google_iam_policy.runtime_template_users.policy_data
}

# One assigned runtime per approved user. Default STOPPED prevents always-on compute cost.
resource "google_colab_runtime" "user" {
  for_each = toset(local.task_users)

  project      = var.colab_project_id
  location     = var.colab_location
  name         = trim(substr("rt-${local.task_slug}-${substr(sha1(each.value), 0, 8)}", 0, 63), "-")
  display_name = "${var.task_name} - ${each.value}"
  description  = "Assigned Colab runtime for ${each.value}, task ${var.task_id}"
  runtime_user = each.value

  notebook_runtime_template_ref {
    notebook_runtime_template = google_colab_runtime_template.task.id
  }

  desired_state = upper(var.runtime_desired_state)
  auto_upgrade  = true

  depends_on = [
    google_colab_runtime_template_iam_policy.task_users,
    google_project_iam_member.user_colab,
    google_project_iam_member.user_bq_job_user,
    google_bigquery_dataset_iam_member.user_dataset,
    google_storage_bucket_iam_member.user_workspace
  ]
}
