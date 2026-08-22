output "colab_project_id" {
  value = var.project_id
}

output "colab_region" {
  value = var.region
}

output "network" {
  value = data.google_compute_network.existing.id
}

output "subnetwork" {
  value = data.google_compute_subnetwork.existing.id
}

output "enabled_services" {
  value = sort(tolist(local.required_services))
}
