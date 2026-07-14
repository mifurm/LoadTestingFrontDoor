#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <wss-url> [connections] [duration]"
  echo "Example: $0 wss://afd-ws-echo-endpoint.z01.azurefd.net/ws/echo 500 60"
  exit 1
fi

URL="$1"
CONNECTIONS="${2:-200}"
DURATION="${3:-30}"

if [[ ! -d ".venv" ]]; then
  python3 -m venv .venv
fi

source .venv/bin/activate

if ! python -c "import websockets" >/dev/null 2>&1; then
  pip install --upgrade pip
  pip install -r requirements.txt
fi

python tester/afd_ws_limit_test.py \
  --url "$URL" \
  --connections "$CONNECTIONS" \
  --duration "$DURATION" \
  --ramp-delay 0.01 \
  --send-interval 0.5 \
  --message-size 128
