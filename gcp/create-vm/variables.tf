variable "prefix" {
  type        = string
  description = "prefix for the resources"
  default     = "abhi"
}

variable "owner" {
  type        = string
  description = "this should be the name of the person (owner) who is excuting this script"
}

variable "project_id" {
  description = "Google Cloud Project ID"
}

variable "region" {
  description = "Region for resources"
}

variable "zone" {
  description = "Zone for the VMs"
}

variable "zones" {
  type        = list(string)
  description = "Zones for the VMs"
}

variable "subnet_cidr" {
  description = "CIDR range for the subnet"
}

variable "tcp_ports" {
  description = "List of TCP ports to allow"
}

variable "image" {
  description = "The image to use for the VM instances"
  type        = string
}

variable "disk_size" {
  description = "size of boot disk"
  default     = 20
}

variable "disk_type" {
  description = "Disk type for boot disk"
}

variable "machine_type" {
  description = "machine type to use for jump server"
  type        = string
  default     = "e2-medium"
}
