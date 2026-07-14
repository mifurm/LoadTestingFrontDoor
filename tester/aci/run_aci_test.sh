#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <resource-group> <parameters-json> <container-group-name>"
  echo "Example: $0 rg-ws-echo tester/aci/infra/main.parameters.example.json afd-ws-test-runner"
  exit 1
fi

RESOURCE_GROUP="$1"
PARAMETERS_FILE="$2"
CONTAINER_GROUP_NAME="$3"

bash tester/aci/deploy_aci_test.sh "$RESOURCE_GROUP" "$PARAMETERS_FILE" >/dev/null

echo "Deployment submitted. Waiting for container group to complete..."

while true; do
  STATE="$(az container show -g "$RESOURCE_GROUP" -n "$CONTAINER_GROUP_NAME" --query 'instanceView.state' -o tsv)"
  echo "Current state: $STATE"

  if [[ "$STATE" == "Succeeded" || "$STATE" == "Failed" || "$STATE" == "Stopped" || "$STATE" == "Terminated" ]]; then
    break
  fi

  sleep 10
done

echo "\n=== Container logs ==="
az container logs -g "$RESOURCE_GROUP" -n "$CONTAINER_GROUP_NAME"

echo "\n=== Container status ==="
az container show -g "$RESOURCE_GROUP" -n "$CONTAINER_GROUP_NAME" --query '{state:instanceView.state,events:containers[0].instanceView.events}' -o json

echo "\nCleaning up container group..."
az container delete -g "$RESOURCE_GROUP" -n "$CONTAINER_GROUP_NAME" --yes >/dev/null

echo "Done."
