#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <resource-group> <parameters-json>"
  echo "Example: $0 rg-ws-echo infra/main.parameters.example.json"
  exit 1
fi

RESOURCE_GROUP="$1"
PARAMETERS_FILE="$2"

az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file infra/main.bicep \
  --parameters "@$PARAMETERS_FILE"
