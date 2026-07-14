#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <resource-group> <web-app-name> [zip-path]"
  echo "Example: $0 rg-ws-echo websocket-echo-demo-12345 appservice-package.zip"
  exit 1
fi

RESOURCE_GROUP="$1"
WEB_APP_NAME="$2"
ZIP_PATH="${3:-appservice-package.zip}"

if [[ ! -f "$ZIP_PATH" ]]; then
  echo "Zip package not found: $ZIP_PATH"
  echo "Build it first with: ./package_app_zip.sh"
  exit 1
fi

az webapp config set \
  --resource-group "$RESOURCE_GROUP" \
  --name "$WEB_APP_NAME" \
  --startup-file "uvicorn backend.app:app --host 0.0.0.0 --port 8000" \
  --web-sockets-enabled true >/dev/null

az webapp config appsettings set \
  --resource-group "$RESOURCE_GROUP" \
  --name "$WEB_APP_NAME" \
  --settings SCM_DO_BUILD_DURING_DEPLOYMENT=1 ENABLE_ORYX_BUILD=true >/dev/null

az webapp deploy \
  --resource-group "$RESOURCE_GROUP" \
  --name "$WEB_APP_NAME" \
  --src-path "$ZIP_PATH" \
  --type zip

echo "Deployment submitted for app '$WEB_APP_NAME' from '$ZIP_PATH'."
