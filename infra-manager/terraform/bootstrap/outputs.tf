output "infrastructure_manager_service_account" {
  value = google_service_account.im_exec.email
}

output "cloud_run_adapter_service_account" {
  value = google_service_account.adapter.email
}
