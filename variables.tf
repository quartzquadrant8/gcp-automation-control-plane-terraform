# gcp-automation-control-plane-terraform/variables.tf
variable "gcp_project_id" {
  description = "Your Google Cloud Project ID"
  type        = string
}

variable "gcp_region" {
  description = "Google Cloud region for resources"
  type        = string
  default     = "us-central1"
}

variable "gcp_zone" {
  description = "Google Cloud zone for control plane VMs"
  type        = string
  default     = "us-central1-a"
}

variable "gcp_ssh_public_key" {
  description = "Your SSH public key for initial access to control plane VMs"
  type        = string
  sensitive   = true
}

variable "vm_machine_type" {
  description = "Machine type for Terraform and Ansible control plane VMs"
  type        = string
  default     = "e2-medium" # Good for development/control nodes
}
