# Provider Configuration
terraform {
  required_providers {
    null = {
      source = "hashicorp/null"
      #version = "~> 3.2"
    }
    time = {
      source = "hashicorp/time"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# VPC Configuration
resource "google_compute_network" "vpc" {
  name                    = "${var.prefix}-vpc"
  auto_create_subnetworks = false
}

# Subnetwork Configuration
resource "google_compute_subnetwork" "subnet" {
  name          = "${var.prefix}-subnet"
  network       = google_compute_network.vpc.name
  ip_cidr_range = var.subnet_cidr
  region        = var.region
}

# Firewall for TCP Traffic
resource "google_compute_firewall" "tcp_firewall" {
  name    = "${var.prefix}-tcp-firewall"
  network = google_compute_network.vpc.name
  allow {
    protocol = "tcp"
    ports    = var.tcp_ports
  }
  source_ranges = ["0.0.0.0/0"]
}

# Firewall for ICMP Traffic
resource "google_compute_firewall" "allow_icmp" {
  name    = "${var.prefix}-icmp-firewall"
  network = google_compute_network.vpc.name
  allow {
    protocol = "icmp"
  }
  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "allow_egress" {
  name      = "${var.prefix}-allow-egress"
  network   = google_compute_network.vpc.name
  direction = "EGRESS"
  priority  = 1000

  destination_ranges = ["0.0.0.0/0"]

  allow {
    protocol = "all" # Allow all protocols (TCP, UDP, ICMP, etc.)
  }
}

# External Static IPs
resource "google_compute_address" "static_ips_testvm" {
  name     = "${var.prefix}-piptestvm"
  region   = var.region
  depends_on = [ google_compute_network.vpc]
}

# Internal Static IPs
resource "google_compute_address" "internal_ips_testvm" {
  name        = "${var.prefix}-internal-iptestvm"
  region      = var.region
  address_type = "INTERNAL"
  subnetwork   = google_compute_subnetwork.subnet.name
  depends_on = [ google_compute_network.vpc]
}

resource "google_compute_instance" "testvm" {
    name         = "${var.prefix}-testvm"
    machine_type = var.machine_type
    zone         = var.zones[0]

    boot_disk {
        initialize_params {
            image = var.image
            size  = var.disk_size
            type  = var.disk_type
        }
    }

    network_interface {
        network    = google_compute_network.vpc.name
        subnetwork = google_compute_subnetwork.subnet.name
        network_ip = google_compute_address.internal_ips_testvm.address
        access_config {
            nat_ip = google_compute_address.static_ips_testvm.address
        }
    }

    labels = {
      "environment" = "poc"
      "owner"        = var.owner
      "skip_deletion"   = "yes"
    }
    metadata_startup_script = file("${path.module}/test_vm.sh")
}


output "test_vm_details" {
  value = {
    internal_ip    = google_compute_instance.testvm.network_interface[0].network_ip
    external_ip    = google_compute_instance.testvm.network_interface[0].access_config[0].nat_ip
    vm_name        = google_compute_instance.testvm.name
  }

  depends_on = [
    google_compute_instance.testvm
  ]
}