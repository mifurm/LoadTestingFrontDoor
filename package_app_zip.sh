#!/usr/bin/env bash
set -euo pipefail

OUT_ZIP="${1:-appservice-package.zip}"
STAGE_DIR=".dist/appservice-package"

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

cp -R backend "$STAGE_DIR/backend"
cp requirements.txt "$STAGE_DIR/requirements.txt"

(
  cd "$STAGE_DIR"
  rm -f "$OLDPWD/$OUT_ZIP"
  zip -r "$OLDPWD/$OUT_ZIP" backend requirements.txt >/dev/null
)

echo "Created zip package: $OUT_ZIP"
