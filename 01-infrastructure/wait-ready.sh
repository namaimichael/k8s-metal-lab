#!/usr/bin/env bash
set -euo pipefail

MAAS_CONTROLLER=${1:-ubuntu@192.168.65.2}
MAAS_PROFILE=${2:-admin}

echo "Polling until all nodes are Ready..."
while true; do
  READY=$(ssh "$MAAS_CONTROLLER" "maas $MAAS_PROFILE machines read | jq -e '[.[] | select(.hostname | test(\"^k8s-\")) | .status_name] | length > 0 and all(. == \"Ready\")'" 2>/dev/null || echo "false")
  if [[ "$READY" == "true" ]]; then
    echo "All nodes Ready!"
    break
  fi
  echo "  ... not ready yet, waiting 10s"
  sleep 10
done