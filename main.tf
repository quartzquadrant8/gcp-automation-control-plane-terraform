# gcp-automation-control-plane-terraform/main.tf

# -------------------------------------------------------------
# VPC Network for Control Plane (can reuse existing or create new)
# -------------------------------------------------------------
resource "google_compute_network" "control_plane_vpc" {
  project                 = var.gcp_project_id
  name                    = "control-plane-vpc"
  auto_create_subnetworks = true # Simpler for this initial setup
  routing_mode            = "REGIONAL"
}

resource "google_compute_firewall" "allow_ssh_control_plane" {
  project     = var.gcp_project_id
  name        = "allow-ssh-control-plane"
  network     = google_compute_network.control_plane_vpc.name
  description = "Allow SSH to control plane VMs."

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["0.0.0.0/0"] # WARNING: Restrict this to your actual source IPs!
  target_tags   = ["control-plane-vm"]
}

# -------------------------------------------------------------
# Terraform Control VM
# -------------------------------------------------------------
resource "google_compute_instance" "terraform_control_vm" {
  project      = var.gcp_project_id
  zone         = var.gcp_zone
  name         = "terraform-control-vm"
  machine_type = var.vm_machine_type
  tags         = ["control-plane-vm", "ssh-access"]

  boot_disk {
    initialize_params {
      image = "projects/debian-cloud/global/images/debian-12-bookworm-v20240708" # Debian is common for tools
      size  = 30 # GB
    }
  }

  network_interface {
    network = google_compute_network.control_plane_vpc.name
    access_config {} # Assign an ephemeral external IP
  }

  metadata = {
    # This injects the SSH public key for the 'admin_user'
    # The 'admin_user' is hardcoded in the startup script for simplicity.
    ssh-keys = "admin_user:${var.gcp_ssh_public_key}"
  }

  # Startup script to install Terraform, Git, gcloud CLI
  metadata_startup_script = <<-EOT
    #!/bin/bash
    sudo apt update -y
    sudo apt install -y curl gnupg software-properties-common git

    # Install gcloud CLI
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee -a /etc/apt/sources.list.d/google-cloud-sdk.list
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg add -
    sudo apt update -y
    sudo apt install -y google-cloud-cli

    # Install Terraform
    curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
    sudo apt update -y
    sudo apt install -y terraform

    # Create the 'admin_user' and grant passwordless sudo for automation ease in lab
    # IMPORTANT: 'admin_user' is a hardcoded username here for simplicity.
    # For production, define usernames more robustly (e.g., via Cloud Identity, Ansible users module).
    if ! id "admin_user" &>/dev/null; then
        sudo useradd -m -s /bin/bash admin_user
    fi
    echo "admin_user ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/admin_user_nopasswd
    sudo chmod 0440 /etc/sudoers.d/admin_user_nopasswd
    sudo chown root:root /etc/sudoers.d/admin_user_nopasswd

    # Configure SSH for 'admin_user'
    sudo mkdir -p /home/admin_user/.ssh
    echo "${var.gcp_ssh_public_key}" | sudo tee /home/admin_user/.ssh/authorized_keys
    sudo chown -R admin_user:admin_user /home/admin_user/.ssh
    sudo chmod 700 /home/admin_user/.ssh
    sudo chmod 600 /home/admin_user/.ssh/authorized_keys

    # Authenticate gcloud (necessary if not using service account)
    # This assumes you will manually run 'gcloud auth login' from this VM
    # For automated builds, use a service account attached to the VM.
  EOT
}

# -------------------------------------------------------------
# Ansible Control VM
# -------------------------------------------------------------
resource "google_compute_instance" "ansible_control_vm" {
  project      = var.gcp_project_id
  zone         = var.gcp_zone
  name         = "ansible-control-vm"
  machine_type = var.vm_machine_type
  tags         = ["control-plane-vm", "ssh-access"]

  boot_disk {
    initialize_params {
      image = "projects/rocky-linux-cloud/global/images/rocky-linux-9" # Rocky for Ansible
      size  = 30 # GB
    }
  }

  network_interface {
    network = google_compute_network.control_plane_vpc.name
    access_config {} # Assign an ephemeral external IP
  }

  metadata = {
    # This injects the SSH public key for the 'ansible_admin' user.
    # The 'ansible_admin' is hardcoded in the startup script for simplicity.
    ssh-keys = "ansible_admin:${var.gcp_ssh_public_key}"
  }

  # Startup script to install Ansible, Docker, Git, gcloud CLI
  metadata_startup_script = <<-EOT
    #!/bin/bash
    sudo dnf update -y
    sudo dnf install -y python3 python3-pip git curl gnupg2

    # Install Ansible via pipx (isolated environment)
    python3 -m pip install --user pipx
    python3 -m pipx ensurepath
    pipx install ansible

    # Install Docker (manual steps like before, or via Ansible post-creation)
    sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo systemctl enable docker --now

    # Create the 'ansible_admin' user and grant passwordless sudo for automation ease in lab
    # IMPORTANT: 'ansible_admin' is a hardcoded username here for simplicity.
    # For production, define usernames more robustly.
    if ! id "ansible_admin" &>/dev/null; then
        sudo useradd -m -s /bin/bash ansible_admin
    fi
    echo "ansible_admin ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/ansible_admin_nopasswd
    sudo chmod 0440 /etc/sudoers.d/ansible_admin_nopasswd
    sudo chown root:root /etc/sudoers.d/ansible_admin_nopasswd

    # Add ansible_admin to docker group
    sudo usermod -aG docker ansible_admin

    # Configure SSH for 'ansible_admin'
    sudo mkdir -p /home/ansible_admin/.ssh
    echo "${var.gcp_ssh_public_key}" | sudo tee /home/ansible_admin/.ssh/authorized_keys
    sudo chown -R ansible_admin:ansible_admin /home/ansible_admin/.ssh
    sudo chmod 700 /home/ansible_admin/.ssh
    sudo chmod 600 /home/ansible_admin/.ssh/authorized_keys

    # Generate SSH key for Ansible to use FROM this VM to others (if not providing one explicitly)
    # The public key from this generation will be needed for the vpn-bridge-vm metadata!
    # Ensure this runs as the ansible_admin user.
    sudo -H -u ansible_admin bash -c "if [ ! -f ~/.ssh/id_rsa ]; then ssh-keygen -t rsa -b 4096 -N '' -f ~/.ssh/id_rsa; fi"

    # Install gcloud CLI
    sudo tee -a /etc/yum.repos.d/google-cloud-sdk.repo << EOM
    [google-cloud-sdk]
    name=Google Cloud SDK
    baseurl=https://packages.cloud.google.com/yum/repos/cloud-sdk-el9-x86_64
    enabled=1
    gpgcheck=1
    repo_gpgcheck=0
    gpgkey=https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
    EOM
    sudo dnf install -y google-cloud-cli

    # Authenticate gcloud (necessary if not using service account)
    # For automated builds, use a service account attached to the VM.
  EOT
}

# -------------------------------------------------------------
# Outputs to retrieve IPs for SSH access
# -------------------------------------------------------------
output "terraform_control_vm_external_ip" {
  value = google_compute_instance.terraform_control_vm.network_interface[0].access_config[0].nat_ip
}

output "ansible_control_vm_external_ip" {
  value = google_compute_instance.ansible_control_vm.network_interface[0].access_config[0].nat_ip
}
