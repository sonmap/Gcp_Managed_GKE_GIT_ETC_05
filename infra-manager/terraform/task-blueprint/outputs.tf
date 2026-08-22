output "task_users" {
  description = "Approved users assigned to this task"
  value       = local.task_users
}

output "runtime_template" {
  description = "Colab Enterprise runtime template resource"
  value       = google_colab_runtime_template.task.id
}

output "user_runtimes" {
  description = "Per-user Colab Enterprise runtime resource IDs"
  value       = { for email, runtime in google_colab_runtime.user : email => runtime.id }
}

output "bigquery_dataset" {
  value = "${var.target_project_id}.${google_bigquery_dataset.task.dataset_id}"
}

output "workspace_bucket" {
  value = "gs://${google_storage_bucket.workspace.name}"
}

output "task_service_account" {
  description = "Service account reserved for scheduled/non-interactive notebook execution"
  value       = google_service_account.task.email
}

output "network" {
  value = data.google_compute_network.runtime.id
}

output "subnetwork" {
  value = data.google_compute_subnetwork.runtime.id
}
