terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 7.5, < 8.0"
    }
  }
}

provider "google" {
  project = var.colab_project_id
  region  = var.colab_location
}
