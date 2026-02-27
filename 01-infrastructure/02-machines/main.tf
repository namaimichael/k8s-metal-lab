terraform {
  required_providers {
    maas = {
      source  = "canonical/maas"
      version = "~> 2.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

variable "maas_api_key" {}
variable "maas_url" {}
variable "distro_series" {
  default = "noble"
}
variable "ssh_public_key_path" {
  default = "~/.ssh/id_ed25519.pub"
}
variable "ssh_private_key_path" {
  default = "~/.ssh/id_ed25519"
}

provider "maas" {
  api_version = "2.0"
  api_key     = var.maas_api_key
  api_url     = var.maas_url
}

# ---------------------------------------------------------------------------
# Fetch the "Ready" machines
# ---------------------------------------------------------------------------

data "maas_machine" "master"  { hostname = "k8s-master-1" }
data "maas_machine" "worker1" { hostname = "k8s-worker-1" }
data "maas_machine" "worker2" { hostname = "k8s-worker-2" }

# ---------------------------------------------------------------------------
# Deploy the OS — sequentially, one node at a time
# master first, then worker1, then worker2
# ---------------------------------------------------------------------------

resource "maas_instance" "deploy_master" {
  allocate_params {
    hostname = data.maas_machine.master.hostname
  }

  deploy_params {
    distro_series = var.distro_series
  }

  timeouts {
    create = "40m"
  }
}

resource "maas_instance" "deploy_worker1" {
  depends_on = [maas_instance.deploy_master]

  allocate_params {
    hostname = data.maas_machine.worker1.hostname
  }

  deploy_params {
    distro_series = var.distro_series
  }

  timeouts {
    create = "40m"
  }
}

resource "maas_instance" "deploy_worker2" {
  depends_on = [maas_instance.deploy_worker1]

  allocate_params {
    hostname = data.maas_machine.worker2.hostname
  }

  deploy_params {
    distro_series = var.distro_series
  }

  timeouts {
    create = "20m"
  }
}

# ---------------------------------------------------------------------------
# Ansible inventory — includes private key path for passwordless SSH
# ---------------------------------------------------------------------------

resource "local_file" "ansible_inventory" {
  filename        = "../../02-configuration/inventory/hosts.ini"
  file_permission = "0644"

  content = <<-INVENTORY
    # Do not edit manually — re-run `make deploy` to regenerate.

    [control_plane]
    ${data.maas_machine.master.hostname} ansible_host=${tolist(maas_instance.deploy_master.ip_addresses)[0]} ansible_user=ubuntu ansible_ssh_private_key_file=${pathexpand(var.ssh_private_key_path)}

    [workers]
    ${data.maas_machine.worker1.hostname} ansible_host=${tolist(maas_instance.deploy_worker1.ip_addresses)[0]} ansible_user=ubuntu ansible_ssh_private_key_file=${pathexpand(var.ssh_private_key_path)}
    ${data.maas_machine.worker2.hostname} ansible_host=${tolist(maas_instance.deploy_worker2.ip_addresses)[0]} ansible_user=ubuntu ansible_ssh_private_key_file=${pathexpand(var.ssh_private_key_path)}

    [k8s_cluster:children]
    control_plane
    workers
  INVENTORY
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "master_ip" {
  value = tolist(maas_instance.deploy_master.ip_addresses)[0]
}

output "worker1_ip" {
  value = tolist(maas_instance.deploy_worker1.ip_addresses)[0]
}

output "worker2_ip" {
  value = tolist(maas_instance.deploy_worker2.ip_addresses)[0]
}