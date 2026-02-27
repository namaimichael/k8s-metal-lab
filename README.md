# 🚀 K8s Metal Lab: Zero-Touch Bare-Metal Kubernetes

![Kubernetes](https://img.shields.io/badge/kubernetes-%23326ce5.svg?style=for-the-badge&logo=kubernetes&logoColor=white)
![Terraform](https://img.shields.io/badge/terraform-%235835CC.svg?style=for-the-badge&logo=terraform&logoColor=white)
![Ansible](https://img.shields.io/badge/ansible-%231A1918.svg?style=for-the-badge&logo=ansible&logoColor=white)
![ArgoCD](https://img.shields.io/badge/ArgoCD-%23EF7B4D.svg?style=for-the-badge&logo=argo&logoColor=white)
![Ubuntu](https://img.shields.io/badge/Ubuntu-E95420?style=for-the-badge&logo=ubuntu&logoColor=white)

A fully automated, zero-touch pipeline that provisions a production-ready Kubernetes cluster from "bare metal" (macOS UTM VMs) to a fully managed GitOps state using a single command: `make all`.

## Architecture & Tech Stack

This project bridges the gap between local development constraints and enterprise production standards. It utilizes a highly decoupled, multi-stage pipeline to simulate a physical data center environment:

* **Hypervisor:** Apple Silicon / UTM (ARM64)
* **Bare Metal Provisioning:** Canonical MAAS (Metal As A Service)
* **Infrastructure as Code (IaC):** Terraform
* **Configuration Management:** Ansible
* **GitOps & Delivery:** ArgoCD
* **Storage (CSI):** Longhorn (Utilizing dedicated `/dev/sdb` virtual disks)
* **Networking & Ingress:** Calico CNI, MetalLB, Ingress-NGINX
* **Certificate Management:** Cert-Manager (Let's Encrypt DNS-01 via DuckDNS)
* **Fleet Management:** Spectro Cloud Palette Integration

## The Zero-Touch Pipeline

The deployment is orchestrated via a monolithic `Makefile` that handles state transitions across four distinct phases:

### Phase 1: Infrastructure & Discovery (`make vms` & `make provision`)
1. Wipes previous state and configures MAAS DHCP/VLANs via Ansible.
2. Interacts with the UTM hypervisor CLI to dynamically clone and boot raw VMs with injected MAC addresses.
3. Forces VMs to PXE boot, allowing MAAS to enlist, commission, and prepare the hardware.

### Phase 2: OS Deployment (`make deploy`)
Once MAAS reports all nodes as `Ready`, **Terraform** takes over to allocate the machines and deploy Ubuntu 24.04 LTS natively, injecting SSH keys for passwordless automation.

### Phase 3: Cluster Bootstrap (`make configure`)
**Ansible** connects to the freshly deployed OS to:
1. Format secondary drives (`/dev/sdb`) for Longhorn distributed storage.
2. Initialize the Kubernetes Control Plane (`kubeadm`) and join worker nodes.
3. Install foundational addons (MetalLB, NGINX).

### Phase 4: The GitOps Handover
Ansible securely injects API credentials into Kubernetes Secrets, installs **ArgoCD**, and applies a declarative "App-of-Apps" root manifest. Ansible then retires, and ArgoCD takes continuous control of the cluster state, deploying Longhorn, Cert-Manager, and enterprise agents.

## Usage

### Prerequisites
* macOS (Apple Silicon) with [UTM](https://mac.getutm.app/) installed.
* A running MAAS Controller VM (`192.168.65.2`).
* Terraform, Ansible, and `jq` installed locally.
* A `.env` file containing the required API keys and tokens.

### Deployment
Bring up the entire stack, from hardware allocation to GitOps synchronization:
```bash
make all
```

## Teardown 

Cleanly release MAAS nodes, destroy Terraform state, and power down hypervisor VMs:
```bash
make clean
```

## 🧠 Engineering Objectives
This environment was developed to provide a reproducible, production-like bare-metal lab for testing infrastructure changes, GitOps workflows, and storage configurations before they are deployed to physical data centers.

By treating local VMs as raw MAC addresses through MAAS, this pipeline forces strict adherence to IaC principles and eliminates reliance on "cloud provider magic buttons"—ensuring our platform engineering practices are robust, portable, and fully declarative.