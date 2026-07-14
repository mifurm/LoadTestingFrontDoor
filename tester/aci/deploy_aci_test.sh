#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <resource-group> <parameters-json> [deployment-name]"
  echo "Example: $0 rg-ws-echo tester/aci/infra/main.parameters.example.json aci-test-run-1"
  exit 1
fi

RESOURCE_GROUP="$1"
PARAMETERS_FILE="$2"
DEPLOYMENT_NAME="${3:-aci-test-$(date +%s)-$RANDOM}"

MAX_ATTEMPTS=3
ATTEMPT=1

while [[ "$ATTEMPT" -le "$MAX_ATTEMPTS" ]]; do
  if OUTPUT=$(az deployment group create \
    --name "$DEPLOYMENT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --template-file tester/aci/infra/main.bicep \
    --parameters "@$PARAMETERS_FILE" 2>&1); then
    echo "$OUTPUT"
    exit 0
  fi

  if grep -q "RegistryErrorResponse" <<< "$OUTPUT" && [[ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]]; then
    BACKOFF=$((ATTEMPT * 15))
    echo "Attempt $ATTEMPT failed with RegistryErrorResponse. Retrying in ${BACKOFF}s..." >&2
    sleep "$BACKOFF"
    ATTEMPT=$((ATTEMPT + 1))
    continue
  fi

  echo "$OUTPUT" >&2
  exit 1
done
