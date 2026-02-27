#!/usr/bin/env bash
set -euo pipefail

MAAS_CONTROLLER=$1
MAAS_PROFILE=$2
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/02-machines"
UTM_DATA="$HOME/Library/Containers/com.utmapp.UTM/Data/Documents"
NODES=(k8s-master-1 k8s-worker-1 k8s-worker-2)

# ---------------------------------------------------------------------------
# Helper: get node status from MAAS
# ---------------------------------------------------------------------------
node_status() {
  ssh "$MAAS_CONTROLLER" "maas $MAAS_PROFILE machines read | jq -r '.[] | select(.hostname == \"$1\") | .status_name'"
}

# ---------------------------------------------------------------------------
# Helper: find the qcow2 disk for a VM (UUID varies per clone)
# ---------------------------------------------------------------------------
find_disk() {
  local vm="$1"
  find "$UTM_DATA/${vm}.utm/Data" -name "*.qcow2" 2>/dev/null | head -1
}

# ---------------------------------------------------------------------------
# Step 0 — Verify MAAS controller is reachable
# ---------------------------------------------------------------------------
echo "==> Verifying MAAS controller is reachable..."
MAX_MAAS_WAIT=60
MAAS_ELAPSED=0
until ssh -o ConnectTimeout=5 "$MAAS_CONTROLLER" "true" 2>/dev/null; do
  if [[ $MAAS_ELAPSED -ge $MAX_MAAS_WAIT ]]; then
    echo "  ERROR: Cannot SSH to MAAS controller after ${MAX_MAAS_WAIT}s."
    exit 1
  fi
  echo "  -> Waiting for MAAS controller... (${MAAS_ELAPSED}s)"
  sleep 5
  MAAS_ELAPSED=$((MAAS_ELAPSED + 5))
done
echo "  -> MAAS controller reachable."

# ---------------------------------------------------------------------------
# Step 1 — Check which nodes need deploying
# ---------------------------------------------------------------------------
echo "==> Checking current node states in MAAS..."
NODES_TO_DEPLOY=()
for vm in "${NODES[@]}"; do
  STATUS=$(node_status "$vm")
  echo "  -> $vm: $STATUS"
  if [[ "$STATUS" == "Deployed" ]]; then
    echo "  -> $vm already deployed — skipping."
  else
    NODES_TO_DEPLOY+=("$vm")
  fi
done

if [[ ${#NODES_TO_DEPLOY[@]} -eq 0 ]]; then
  echo "==> All nodes already deployed. Regenerating inventory..."
  cd "$TF_DIR"
  terraform init -reconfigure > /dev/null
  terraform apply -auto-approve
  exit 0
fi

echo "==> Nodes to deploy: ${NODES_TO_DEPLOY[*]}"

# ---------------------------------------------------------------------------
# Step 2 — Wipe disks for nodes that need deploying
# Dynamically finds the qcow2 — no hardcoded UUID
# ---------------------------------------------------------------------------
echo "==> Wiping VM disks and NVRAM for nodes that need deploying..."
for vm in "${NODES_TO_DEPLOY[@]}"; do
  echo "  -> Stopping, wiping disk, and resetting UEFI for $vm..."
  utmctl stop "$vm" >/dev/null 2>&1 || true
  sleep 2

  # Dynamically find the qcow2 disk
  DISK=$(find "$UTM_DATA/${vm}.utm/Data" -name "*.qcow2" 2>/dev/null | head -1)
  if [[ -z "$DISK" ]]; then
    echo "  ERROR: No qcow2 disk found for $vm"
    exit 1
  fi
  echo "  -> Wiping $DISK..."
  qemu-img create -f qcow2 "$DISK" 20G

  # Reset UEFI vars so it falls back to network boot
  rm -f "$UTM_DATA/${vm}.utm/Data/efi_vars"*
done
# ---------------------------------------------------------------------------
# Step 3 — Initialise Terraform and clear stale state
# ---------------------------------------------------------------------------
echo "==> Initialising Terraform..."
cd "$TF_DIR"
terraform init -reconfigure > /dev/null

echo "==> Clearing stale Terraform state..."
tainted=$(terraform state list 2>/dev/null | grep "maas_instance" || true)
if [[ -n "$tainted" ]]; then
  while IFS= read -r resource; do
    terraform untaint "$resource" 2>/dev/null || true
  done <<< "$tainted"
fi

for resource in maas_instance.deploy_master maas_instance.deploy_worker1 maas_instance.deploy_worker2 local_file.ansible_inventory; do
  if terraform state show "$resource" > /dev/null 2>&1; then
    SYS_ID=$(terraform state show "$resource" 2>/dev/null | grep '^\s*id\s*=' | awk '{print $3}' | tr -d '"' || true)
    if [[ -n "$SYS_ID" ]]; then
      EXISTS=$(ssh "$MAAS_CONTROLLER" "maas $MAAS_PROFILE machine read $SYS_ID 2>/dev/null | jq -r '.system_id // empty'" || true)
      if [[ -z "$EXISTS" ]]; then
        echo "  -> Removing stale state: $resource"
        terraform state rm "$resource" 2>/dev/null || true
      fi
    fi
  fi
done

# ---------------------------------------------------------------------------
# Step 4 — Stop nodes before Terraform runs
# ---------------------------------------------------------------------------
echo "==> Ensuring nodes are stopped..."
for vm in "${NODES_TO_DEPLOY[@]}"; do
  utmctl stop "$vm" >/dev/null 2>&1 || true
done
sleep 3

# ---------------------------------------------------------------------------
# Step 5 — Run Terraform in background
# ---------------------------------------------------------------------------
echo "==> Triggering MAAS deploy via Terraform (background)..."
terraform apply -auto-approve &
TF_PID=$!

# ---------------------------------------------------------------------------
# Step 6 — Poll MAAS and start each VM when it enters Deploying state
# ---------------------------------------------------------------------------
echo "==> Monitoring MAAS — starting VMs as they enter Deploying state..."
STARTED=()
MAX_WAIT=2400
ELAPSED=0

while [[ ${#STARTED[@]} -lt ${#NODES_TO_DEPLOY[@]} && $ELAPSED -lt $MAX_WAIT ]]; do
  for vm in "${NODES_TO_DEPLOY[@]}"; do
    if [[ " ${STARTED[*]} " == *" $vm "* ]]; then
      continue
    fi
    STATUS=$(node_status "$vm")
    if [[ "$STATUS" == "Deploying" ]]; then
      echo "  -> $vm is Deploying — starting VM..."
      for attempt in 1 2 3 4 5; do
        if utmctl start "$vm" 2>/dev/null; then
          break
        fi
        echo "  -> Attempt $attempt failed, retrying in 3s..."
        sleep 3
      done
      STARTED+=("$vm")
    fi
  done
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

# ---------------------------------------------------------------------------
# Step 7 — Wait for Terraform
# ---------------------------------------------------------------------------
echo "==> Waiting for Terraform to complete..."
wait $TF_PID
echo "==> Deploy complete."

# ---------------------------------------------------------------------------
# Step 8 — Trust SSH host keys for all deployed nodes
# ---------------------------------------------------------------------------
echo "==> Trusting SSH host keys for deployed nodes..."
sleep 10  # give sshd a moment to start after deployment
IPS=$(ssh "$MAAS_CONTROLLER" "maas $MAAS_PROFILE machines read | \
  jq -r '.[] | select(.hostname | test(\"^k8s-\")) | .ip_addresses[] | select(test(\"^[0-9]\"))'" 2>/dev/null)

for ip in $IPS; do
  echo "  -> Adding host key for $ip..."
  ssh-keyscan -H "$ip" 2>/dev/null >> ~/.ssh/known_hosts
done

# Deduplicate known_hosts
sort -u ~/.ssh/known_hosts -o ~/.ssh/known_hosts
echo "  -> SSH host keys trusted."