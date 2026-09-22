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

# Redis 7.22+ adds cluster API, gRPC, gossip and authentication ports.
# Permit these only between Redis nodes, without widening public ingress.
resource "google_compute_firewall" "redis_internal" {
  name        = "${var.prefix}-redis-internal"
  network     = google_compute_network.vpc.name
  source_tags = ["${var.prefix}-redis"]
  target_tags = ["${var.prefix}-redis"]
  allow {
    protocol = "tcp"
    ports    = ["3333-3355"]
  }
}

# Firewall for UDP Traffic
resource "google_compute_firewall" "udp_firewall" {
  name    = "${var.prefix}-udp-firewall"
  network = google_compute_network.vpc.name
  allow {
    protocol = "udp"
    ports    = var.udp_ports
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


# The jump server has no external address; NAT lets it install API tools.
# resource "google_compute_router" "jump_egress" {
#   name    = "${var.prefix}-jump-router"
#   network = google_compute_network.vpc.id
#   region  = var.region
# }

# resource "google_compute_router_nat" "jump_egress" {
#   name                               = "${var.prefix}-jump-nat"
#   router                             = google_compute_router.jump_egress.name
#   region                             = var.region
#   nat_ip_allocate_option             = "AUTO_ONLY"
#   source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
#   subnetwork {
#     name                    = google_compute_subnetwork.subnet.id
#     source_ip_ranges_to_nat = ["PRIMARY_IP_RANGE"]
#   }
# }

# Create public external static IP for jump-server
resource "google_compute_address" "static_ips_js" {
  name   = "${var.prefix}-js-pip"
  region = var.region
}

# Create public external static IPs
resource "google_compute_address" "static_ips" {
  count  = var.node_count_primary
  name   = "${var.prefix}-${count.index}-pip"
  region = var.region
}


# Internal Static IPs
resource "google_compute_address" "internal_ips" {
  count        = var.node_count_primary
  name         = "${var.prefix}-${count.index}-internal-ip"
  region       = var.region
  address_type = "INTERNAL"
  subnetwork   = google_compute_subnetwork.subnet.name
}

locals {
  install_template_vars = {
    redis_tar_file_location = var.redis_tar_file_location
    cluster_admin_username  = var.cluster_admin_username
    cluster_admin_password  = var.cluster_admin_password
  }
}

# Virtual Machine Instances
resource "google_compute_instance" "redis_vms" {
  depends_on = [
    google_compute_firewall.tcp_firewall,
    google_compute_firewall.udp_firewall,
    google_compute_firewall.redis_internal,
    google_compute_firewall.allow_egress,
  ]
  count        = var.node_count_primary
  name         = "${var.prefix}-vm-${count.index}"
  zone         = var.zones[(count.index) % length(var.zones)]
  machine_type = var.asymmetric_cluster && var.node_count_primary >= 3 && count.index == var.node_count_primary - 1 ? var.machine_type_lastnode : var.machine_type 
  tags         = ["${var.prefix}-redis"]

  # Boot disk configuration
  boot_disk {
    initialize_params {
      image = var.asymmetric_cluster && var.node_count_primary >= 3 && count.index == var.node_count_primary - 1 ? var.image_lastnode : var.image
      size  = var.asymmetric_cluster && var.node_count_primary >= 3 && count.index == var.node_count_primary - 1 ? var.disk_size_lastnode : var.disk_size
      type  = var.asymmetric_cluster && var.node_count_primary >= 3 && count.index == var.node_count_primary - 1 ? var.disk_type_lastnode : var.disk_type
    }
  }

  # Network Interfaces
  network_interface {
    network    = google_compute_network.vpc.name
    subnetwork = google_compute_subnetwork.subnet.name
    network_ip = google_compute_address.internal_ips[count.index].address

    access_config {
      nat_ip = google_compute_address.static_ips[count.index].address
    }
  }

  labels = {
    "environment"   = "poc"
    "owner"         = var.owner
    "skip_deletion" = "yes"
  }

  metadata = {
    "startup-script" = templatefile("${path.module}/install.sh",
      merge(
        local.install_template_vars, { node_internal_ip = google_compute_address.internal_ips[count.index].address }
      )
    )
  }

  # Hostname Configuration
  hostname = "${var.prefix}-${count.index}.${var.cluster_name}"

}

# Jump server VM for creating the Redis cluster and joining the nodes to the cluster
resource "google_compute_instance" "jump_server" {
  # VM creation does not wait for Redis installation; configure.sh polls it.
  depends_on   = [google_compute_instance.redis_vms]
  name         = "${var.prefix}-vm-js"
  zone         = var.zones[0 % length(var.zones)]
  machine_type = var.js_machine_type

  # Boot disk configuration
  boot_disk {
    initialize_params {
      image = var.image
      size  = var.disk_size
      type  = var.disk_type
    }
  }

  # Network Interfaces
  network_interface {
    network    = google_compute_network.vpc.name
    subnetwork = google_compute_subnetwork.subnet.name
    access_config {
      nat_ip = google_compute_address.static_ips_js.address
    }
  }

  labels = {
    "environment"   = "poc"
    "owner"         = var.owner
    "skip_deletion" = "yes"
  }

  metadata = {
    "startup-script" = templatefile(
      "${path.module}/configure.sh",
      merge(
        local.install_template_vars, {
          no_of_nodes_per_cluster  = var.node_count_primary,
          cluster_name             = var.cluster_name,
          node_external_ips_joined = join(" ", google_compute_instance.redis_vms[*].network_interface[0].access_config[0].nat_ip),
          node_internal_ips_joined = join(" ", google_compute_instance.redis_vms[*].network_interface[0].network_ip)
      })
    )
  }

  # Hostname Configuration
  hostname = "${var.prefix}-js.${var.cluster_name}"
}

# Output VM Details
output "vm_details" {
  value = merge(
    {
      for idx in range(length(google_compute_instance.redis_vms)) :
      idx => {
        internal_ip = google_compute_instance.redis_vms[idx].network_interface[0].network_ip
        external_ip = google_compute_instance.redis_vms[idx].network_interface[0].access_config[0].nat_ip
        vm_name     = google_compute_instance.redis_vms[idx].name
      }
    }
  )
}

output "node_ips" {
  value = { for k, v in google_compute_address.static_ips : k => v.address }
}

# Output Redis Cluster login details
output "Redis_cluster_info" {
  value = {
    admin    = var.cluster_admin_username
    password = var.cluster_admin_password
  }
}
