#!/usr/bin/env bash
set -euo pipefail

TEMPLATE_NAME="PXE-Template"
NODES=("k8s-master-1" "k8s-worker-1" "k8s-worker-2")
UTM_DOCS="$HOME/Library/Containers/com.utmapp.UTM/Data/Documents"
MAAS_VM_NAME="maas-controller"

generate_mac() {
  printf '52:54:%02x:%02x:%02x:%02x\n' \
    $((RANDOM % 256)) $((RANDOM % 256)) \
    $((RANDOM % 256)) $((RANDOM % 256))
}

set_mac() {
  local config="$1"
  local mac="$2"
  python3 - "$config" "$mac" <<'PYEOF'
import sys, plistlib
config_path, mac = sys.argv[1], sys.argv[2]
with open(config_path, 'rb') as f:
    plist = plistlib.load(f)
networks = plist.get('Network', [])
if not networks:
    print("ERROR: No Network entry"); sys.exit(1)
networks[0]['MacAddress'] = mac
plist['Network'] = networks
with open(config_path, 'wb') as f:
    plistlib.dump(plist, f)
print(f"  MAC {mac} written.")
PYEOF
}

echo "Provisioning local virtual hardware..."

# Step 1 — Clone all VMs while UTM is running
for NODE in "${NODES[@]}"; do
  if utmctl list | grep -q "$NODE"; then
    echo "  -> $NODE already exists, skipping clone."
  else
    echo "  -> Cloning $NODE from $TEMPLATE_NAME..."
    utmctl clone "$TEMPLATE_NAME" --name "$NODE"
    
    # AUTOMATION FIX: Delete the cloned UEFI state.
    # This forces the VM to rescan hardware and respect the PXE bootindex.
    rm -f "$UTM_DOCS/${NODE}.utm/Data/efi_vars"*
    
    sleep 2
  fi
done

# Step 2 — Record which VMs were running before we quit UTM
# so we can restore their state (especially maas-controller) after relaunch
echo "  -> Recording running VMs before UTM restart..."
RUNNING_VMS=$(timeout 5 utmctl list 2>/dev/null | grep "started" | awk '{print $1}' || true)
echo "  -> Currently running: $RUNNING_VMS"

# Step 3 — Quit UTM to release in-memory config cache
echo "  -> Quitting UTM to release config cache..."
osascript -e 'tell application "UTM" to quit'
sleep 5

# Step 4 — Edit each cloned VM's plist while UTM is offline
for NODE in "${NODES[@]}"; do
  CONFIG="$UTM_DOCS/${NODE}.utm/config.plist"
  if [[ ! -f "$CONFIG" ]]; then
    echo "  ERROR: $CONFIG not found"; exit 1
  fi
  MAC=$(generate_mac)
  echo "  -> Injecting MAC $MAC into $NODE (UTM offline)..."
  set_mac "$CONFIG" "$MAC"
done

# Step 5 — Relaunch UTM
echo "  -> Relaunching UTM..."
open -a UTM
sleep 6

echo "  -> Waking up MAAS Controller (maas-controller)..."
utmctl start "maas-controller"


echo "  -> Waiting 30s for MAAS network services to settle..."
sleep 30


for NODE in "${NODES[@]}"; do
  echo "  -> Powering on $NODE..."
  utmctl start "$NODE"
  sleep 2
done

# Dismiss any security dialogs
for i in $(seq 1 5); do
  osascript \
    -e 'tell application "System Events" to tell process "UTM"' \
    -e '  if exists button "OK" of window 1 then click button "OK" of window 1' \
    -e 'end tell' 2>/dev/null || true
  sleep 1
done

# Step 6 — Restart any VMs that were running before (e.g. maas-controller)
# This ensures MAAS comes back up automatically
if [[ -n "$RUNNING_VMS" ]]; then
  echo "  -> Restoring previously running VMs..."
  while IFS= read -r vm; do
    # Skip the k8s nodes — we'll start them fresh below
    if [[ "$vm" == k8s-* ]]; then
      continue
    fi
    echo "  -> Restarting $vm..."
    utmctl start "$vm" 2>/dev/null || true
    sleep 2
  done <<< "$RUNNING_VMS"

  # Wait for MAAS controller to come back up
  echo "  -> Waiting for MAAS controller (192.168.65.2) to be reachable..."
  for i in $(seq 1 24); do
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no ubuntu@192.168.65.2 "true" 2>/dev/null; then
      echo "  -> MAAS controller is up."
      break
    fi
    echo "  -> Not reachable yet, waiting 10s... ($((i*10))s elapsed)"
    sleep 10
  done
fi

# Step 7 — Start the k8s VMs
echo "  -> Waking up MAAS Controller ($MAAS_VM_NAME)..."
utmctl start "$MAAS_VM_NAME"
sleep 5

for NODE in "${NODES[@]}"; do
  echo "  -> Powering on $NODE..."
  utmctl start "$NODE"
  sleep 2
done

echo ""
echo "✅ VMs booting with unique MACs. MAAS controller restored. Monitor MAAS UI for 3 distinct entries."