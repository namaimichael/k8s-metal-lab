include .env
export $(shell sed 's/=.*//' .env)

.PHONY: network vms provision release deploy configure clean clean-maas all

# ---------------------------------------------------------------------------
# Phase 0 — MAAS cleanup
# ---------------------------------------------------------------------------

clean-maas:
	@echo "==> [Cleanup] Wiping MAAS Network Configuration..."
	ansible-playbook -i 00-bootstrap/inventory.ini 01-infrastructure/maas-clean.yml

# ---------------------------------------------------------------------------
# Phase 1 — Network configuration
# ---------------------------------------------------------------------------

network: clean-maas
	@echo "==> [Phase 1] Configuring MAAS via Ansible..."
	ansible-playbook -i 00-bootstrap/inventory.ini 01-infrastructure/maas-config.yml

# ---------------------------------------------------------------------------
# Phase 1.5 — VM creation
# Clones VMs from PXE-Template with unique MACs and starts them.
# Nodes will PXE boot and appear as "New" in MAAS automatically.
# ---------------------------------------------------------------------------

vms:
	@echo "==> [Phase 1.5] Creating and booting UTM VMs..."
	./01-infrastructure/create-vms.sh

# ---------------------------------------------------------------------------
# Phase 1.75 — Commissioning
# Sets power type, renames nodes, triggers commissioning, then power cycles
# VMs via UTM to kick off the PXE commissioning boot.
# ---------------------------------------------------------------------------

provision:
	@echo "==> [Automation] Waiting for MAAS SSH & Starting Commissioning..."
	ansible-playbook -i 00-bootstrap/inventory.ini 01-infrastructure/maas-provision-nodes.yml
	@echo "==> [Phase 1.75] Power cycling VMs to trigger PXE commissioning..."
	./01-infrastructure/power-cycle.sh
	@echo "==> Waiting for all nodes to reach Ready state (~5 mins)..."
	./01-infrastructure/wait-ready.sh $(MAAS_CONTROLLER) $(MAAS_PROFILE)

# ---------------------------------------------------------------------------
# Phase 2 — OS deployment
# Uploads SSH key, releases any non-Ready nodes back to Ready,
# waits for Ready state, then runs Terraform.
# ---------------------------------------------------------------------------

release:
	@echo "==> [Pre-deploy] Uploading SSH key to MAAS..."
	-ssh $(MAAS_CONTROLLER) "maas $(MAAS_PROFILE) sshkeys create key='$(shell cat $(TF_VAR_ssh_public_key_path))'" || true
	@echo "==> [Pre-deploy] Releasing any non-Ready k8s nodes..."
	@ssh $(MAAS_CONTROLLER) 'maas $(MAAS_PROFILE) machines read | jq -r ".[] | select(.hostname | test(\"^k8s-\")) | select(.status_name != \"Ready\") | .system_id" | xargs -r -I{} maas $(MAAS_PROFILE) machine release {}' || true
	@echo "==> [Pre-deploy] Waiting for all nodes to reach Ready state..."
	./01-infrastructure/wait-ready.sh $(MAAS_CONTROLLER) $(MAAS_PROFILE)

deploy: release
	@echo "==> [Phase 2] Deploying Ubuntu OS via Terraform..."
	./01-infrastructure/deploy-nodes.sh $(MAAS_CONTROLLER) $(MAAS_PROFILE)

# ---------------------------------------------------------------------------
# Phase 3 — Kubernetes configuration
# ---------------------------------------------------------------------------

configure:
	@echo "==> [Phase 3] Running Ansible Configuration..."
	cd 02-configuration && \
		ansible-playbook -i inventory/hosts.ini playbooks/site.yml

# ---------------------------------------------------------------------------
# Full stack
# ---------------------------------------------------------------------------

all: network vms provision deploy configure
	@echo "==> [Done] Full cluster deployment complete."

# ---------------------------------------------------------------------------
# Teardown — deletes nodes from MAAS, stops+deletes VMs in UTM, clears state
# ---------------------------------------------------------------------------

clean:
	@echo "==> [Teardown] Deleting k8s machines from MAAS..."
	@ssh $(MAAS_CONTROLLER) 'maas $(MAAS_PROFILE) machines read | jq -r ".[] | select(.hostname | test(\"^k8s-\")) | .system_id" | xargs -r -I{} maas $(MAAS_PROFILE) machine delete {}' || true
	@echo "==> [Teardown] Stopping and deleting VMs in UTM..."
	@for vm in k8s-master-1 k8s-worker-1 k8s-worker-2; do \
		echo "  -> Stopping $$vm..."; \
		utmctl stop "$$vm" >/dev/null 2>&1 || true; \
		sleep 2; \
		echo "  -> Deleting $$vm..."; \
		utmctl delete "$$vm" >/dev/null 2>&1 || true; \
	done
	@echo "==> [Teardown] Destroying Terraform state..."
	cd 01-infrastructure/02-machines && terraform destroy -auto-approve || true
	@echo "==> [Teardown] Clearing Terraform state files..."
	rm -f 01-infrastructure/02-machines/terraform.tfstate
	rm -f 01-infrastructure/02-machines/terraform.tfstate.*.backup
	rm -f 01-infrastructure/02-machines/terraform.tfstate.backup