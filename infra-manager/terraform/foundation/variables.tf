variable "project_id" {
  description = "Shared project that hosts Colab Enterprise runtimes"
  type        = string
  default     = "dev-com-334508"
}

variable "region" {
  description = "Colab Enterprise region"
  type        = string
  default     = "asia-northeast3"
}

variable "network_project_id" {
  description = "Project that owns the existing runtime VPC/subnet"
  type        = string
  default     = "dev-com-334508"
}

variable "network_name" {
  description = "Existing VPC name"
  type        = string
  default     = "managed02-dev-vpc"
}

variable "subnetwork_name" {
  description = "Existing subnet name"
  type        = string
  default     = "managed02-dev-subnet"
}
