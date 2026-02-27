#!/usr/bin/env bash
set -euo pipefail

NODES=("k8s-master-1" "k8s-worker-1" "k8s-worker-2")

echo "==> Stopping all k8s VMs..."
for vm in "${NODES[@]}"; do
  echo "  -> Stopping $vm..."
  utmctl stop "$vm" >/dev/null 2>&1 || true
done

echo "  -> Waiting 10s for VMs to fully stop..."
sleep 10

# Verify all stopped
for vm in "${NODES[@]}"; do
  STATUS=$(utmctl list 2>/dev/null | grep "$vm" | awk '{print $2}')
  echo "  -> $vm: ${STATUS:-not found}"
done

echo "==> Starting all k8s VMs..."
for vm in "${NODES[@]}"; do
  echo "  -> Starting $vm..."
  STARTED=false
  for attempt in 1 2 3 4 5; do
    if utmctl start "$vm" 2>/dev/null; then
      STARTED=true
      break
    fi
    echo "    Attempt $attempt failed, retrying in 5s..."
    sleep 5
  done

  if [[ "$STARTED" == "false" ]]; then
    echo "  ERROR: Failed to start $vm after 5 attempts"
    exit 1
  fi

  sleep 3
  STATUS=$(utmctl list 2>/dev/null | grep "$vm" | awk '{print $2}')
  echo "  -> $vm status: ${STATUS:-unknown}"
done

echo "==> All k8s VMs started."