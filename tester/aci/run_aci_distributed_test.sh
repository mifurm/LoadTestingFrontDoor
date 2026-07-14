#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 5 ]]; then
  echo "Usage: $0 <resource-group> <base-parameters-json> <group-prefix> <groups-count> <connections-per-group> [cleanup:true|false]"
  echo "Example: $0 rg-ws-echo tester/aci/infra/main.parameters.example.json afd-ws-dist 4 500 true"
  exit 1
fi

RESOURCE_GROUP="$1"
BASE_PARAMETERS_FILE="$2"
GROUP_PREFIX="$3"
GROUPS_COUNT="$4"
CONNECTIONS_PER_GROUP="$5"
CLEANUP="${6:-true}"

if [[ ! -f "$BASE_PARAMETERS_FILE" ]]; then
  echo "Base parameters file not found: $BASE_PARAMETERS_FILE"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "This script requires 'jq'. Install it first (for example: brew install jq)."
  exit 1
fi

RUN_ID="$(date +%Y%m%d_%H%M%S)"
WORK_DIR="tester/aci/.runs/$RUN_ID"
mkdir -p "$WORK_DIR"

echo "Run ID: $RUN_ID"
echo "Work directory: $WORK_DIR"

declare -a GROUP_NAMES=()
declare -a PARAM_FILES=()
declare -a DEPLOY_LOG_FILES=()

for i in $(seq 1 "$GROUPS_COUNT"); do
  GROUP_NAME="${GROUP_PREFIX}-${RUN_ID}-${i}"
  PARAM_FILE="$WORK_DIR/params-$i.json"

  jq \
    --arg groupName "$GROUP_NAME" \
    --argjson connections "$CONNECTIONS_PER_GROUP" \
    '.parameters.containerGroupName.value = $groupName | .parameters.connections.value = $connections' \
    "$BASE_PARAMETERS_FILE" > "$PARAM_FILE"

  GROUP_NAMES+=("$GROUP_NAME")
  PARAM_FILES+=("$PARAM_FILE")
  DEPLOY_LOG_FILES+=("$WORK_DIR/deploy-$i.log")
done

echo "Deploying $GROUPS_COUNT ACI container groups in parallel..."
declare -a DEPLOY_PIDS=()
for i in $(seq 1 "$GROUPS_COUNT"); do
  GROUP_NAME="${GROUP_NAMES[$((i-1))]}"
  DEPLOYMENT_NAME="${GROUP_NAME}-deploy"
  (
    bash tester/aci/deploy_aci_test.sh "$RESOURCE_GROUP" "${PARAM_FILES[$((i-1))]}" "$DEPLOYMENT_NAME"
  ) >"${DEPLOY_LOG_FILES[$((i-1))]}" 2>&1 &
  DEPLOY_PIDS+=("$!")
done

DEPLOY_FAILED=0
for pid in "${DEPLOY_PIDS[@]}"; do
  if ! wait "$pid"; then
    DEPLOY_FAILED=$((DEPLOY_FAILED + 1))
  fi
done

echo "All deployments submitted and completed."

declare -a ACTIVE_GROUPS=()
declare -a MISSING_GROUPS=()

for group in "${GROUP_NAMES[@]}"; do
  if az container show -g "$RESOURCE_GROUP" -n "$group" >/dev/null 2>&1; then
    ACTIVE_GROUPS+=("$group")
  else
    MISSING_GROUPS+=("$group")
  fi
done

if [[ ${#MISSING_GROUPS[@]} -gt 0 ]]; then
  echo "Warning: ${#MISSING_GROUPS[@]} container groups were not created:"
  for group in "${MISSING_GROUPS[@]}"; do
    echo "  - $group"
  done
fi

if [[ ${#ACTIVE_GROUPS[@]} -eq 0 ]]; then
  echo "No container groups were created successfully."
  echo "Deployment logs are in: $WORK_DIR"
  if [[ "$DEPLOY_FAILED" -gt 0 ]]; then
    echo "Failed deployment count: $DEPLOY_FAILED"
  fi
  exit 1
fi

echo "Waiting for all container groups to finish..."
for group in "${ACTIVE_GROUPS[@]}"; do
  while true; do
    STATE="$(az container show -g "$RESOURCE_GROUP" -n "$group" --query 'instanceView.state' -o tsv)"
    echo "[$group] state=$STATE"

    if [[ "$STATE" == "Succeeded" || "$STATE" == "Failed" || "$STATE" == "Stopped" || "$STATE" == "Terminated" ]]; then
      break
    fi

    sleep 10
  done
done

echo "Collecting logs and parsing summaries..."

TOTAL_TARGET=0
TOTAL_CONNECT_OK=0
TOTAL_CONNECT_FAIL=0
TOTAL_SENDS_OK=0
TOTAL_ECHO_OK=0
TOTAL_ECHO_MISMATCH=0
TOTAL_RECV_FAIL=0
TOTAL_DISCONNECTS=0
TOTAL_DURATION=0
LAT_WEIGHTED_SUM=0
P95_WEIGHTED_SUM=0
LAT_WEIGHT=0

declare -a ERROR_KEYS=()
declare -a ERROR_VALUES=()

add_error_count() {
  local key="$1"
  local value="$2"
  local i
  for i in "${!ERROR_KEYS[@]}"; do
    if [[ "${ERROR_KEYS[$i]}" == "$key" ]]; then
      ERROR_VALUES[$i]=$((ERROR_VALUES[$i] + value))
      return
    fi
  done
  ERROR_KEYS+=("$key")
  ERROR_VALUES+=("$value")
}

for group in "${ACTIVE_GROUPS[@]}"; do
  LOG_FILE="$WORK_DIR/$group.log"
  az container logs -g "$RESOURCE_GROUP" -n "$group" > "$LOG_FILE"

  target="$(grep -E '^target_connections=' "$LOG_FILE" | tail -1 | cut -d'=' -f2 || echo 0)"
  connect_ok="$(grep -E '^connect_ok=' "$LOG_FILE" | tail -1 | cut -d'=' -f2 || echo 0)"
  connect_fail="$(grep -E '^connect_fail=' "$LOG_FILE" | tail -1 | cut -d'=' -f2 || echo 0)"
  sends_ok="$(grep -E '^sends_ok=' "$LOG_FILE" | tail -1 | cut -d'=' -f2 || echo 0)"
  echo_ok="$(grep -E '^echo_ok=' "$LOG_FILE" | tail -1 | cut -d'=' -f2 || echo 0)"
  echo_mismatch="$(grep -E '^echo_mismatch=' "$LOG_FILE" | tail -1 | cut -d'=' -f2 || echo 0)"
  recv_fail="$(grep -E '^recv_fail=' "$LOG_FILE" | tail -1 | cut -d'=' -f2 || echo 0)"
  disconnects="$(grep -E '^disconnects=' "$LOG_FILE" | tail -1 | cut -d'=' -f2 || echo 0)"
  duration_s="$(grep -E '^duration_s=' "$LOG_FILE" | tail -1 | cut -d'=' -f2 || echo 0)"
  p50="$(grep -E '^latency_p50_ms=' "$LOG_FILE" | tail -1 | cut -d'=' -f2 || echo 0)"
  p95="$(grep -E '^latency_p95_ms=' "$LOG_FILE" | tail -1 | cut -d'=' -f2 || echo 0)"

  TOTAL_TARGET=$((TOTAL_TARGET + target))
  TOTAL_CONNECT_OK=$((TOTAL_CONNECT_OK + connect_ok))
  TOTAL_CONNECT_FAIL=$((TOTAL_CONNECT_FAIL + connect_fail))
  TOTAL_SENDS_OK=$((TOTAL_SENDS_OK + sends_ok))
  TOTAL_ECHO_OK=$((TOTAL_ECHO_OK + echo_ok))
  TOTAL_ECHO_MISMATCH=$((TOTAL_ECHO_MISMATCH + echo_mismatch))
  TOTAL_RECV_FAIL=$((TOTAL_RECV_FAIL + recv_fail))
  TOTAL_DISCONNECTS=$((TOTAL_DISCONNECTS + disconnects))

  TOTAL_DURATION=$(awk -v a="$TOTAL_DURATION" -v b="$duration_s" 'BEGIN { printf "%.4f", a + b }')

  weight="$echo_ok"
  if [[ "$weight" -gt 0 ]]; then
    LAT_WEIGHTED_SUM=$(awk -v a="$LAT_WEIGHTED_SUM" -v p="$p50" -v w="$weight" 'BEGIN { printf "%.6f", a + (p * w) }')
    P95_WEIGHTED_SUM=$(awk -v a="$P95_WEIGHTED_SUM" -v p="$p95" -v w="$weight" 'BEGIN { printf "%.6f", a + (p * w) }')
    LAT_WEIGHT=$((LAT_WEIGHT + weight))
  fi

  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]+([^:]+):[[:space:]]+([0-9]+)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      add_error_count "$key" "$value"
    fi
  done < "$LOG_FILE"

done

if [[ "$LAT_WEIGHT" -gt 0 ]]; then
  AGG_P50=$(awk -v s="$LAT_WEIGHTED_SUM" -v w="$LAT_WEIGHT" 'BEGIN { printf "%.2f", s / w }')
  AGG_P95=$(awk -v s="$P95_WEIGHTED_SUM" -v w="$LAT_WEIGHT" 'BEGIN { printf "%.2f", s / w }')
else
  AGG_P50="0.00"
  AGG_P95="0.00"
fi

AVG_DURATION=$(awk -v t="$TOTAL_DURATION" -v n="${#ACTIVE_GROUPS[@]}" 'BEGIN { printf "%.2f", (n > 0 ? t / n : 0) }')

echo
echo "Distributed AFD WebSocket test summary"
echo "run_id=$RUN_ID"
echo "groups_requested=$GROUPS_COUNT"
echo "groups_created=${#ACTIVE_GROUPS[@]}"
echo "connections_per_group=$CONNECTIONS_PER_GROUP"
echo "target_connections_total=$TOTAL_TARGET"
echo "avg_group_duration_s=$AVG_DURATION"
echo "connect_ok_total=$TOTAL_CONNECT_OK"
echo "connect_fail_total=$TOTAL_CONNECT_FAIL"
echo "sends_ok_total=$TOTAL_SENDS_OK"
echo "echo_ok_total=$TOTAL_ECHO_OK"
echo "echo_mismatch_total=$TOTAL_ECHO_MISMATCH"
echo "recv_fail_total=$TOTAL_RECV_FAIL"
echo "disconnects_total=$TOTAL_DISCONNECTS"
echo "latency_p50_ms_weighted=$AGG_P50"
echo "latency_p95_ms_weighted=$AGG_P95"

if [[ ${#ERROR_KEYS[@]} -gt 0 ]]; then
  echo "errors="
  for i in "${!ERROR_KEYS[@]}"; do
    echo "  ${ERROR_KEYS[$i]}: ${ERROR_VALUES[$i]}"
  done | sort
fi

REPORT_FILE="$WORK_DIR/aggregate-summary.txt"
{
  echo "Distributed AFD WebSocket test summary"
  echo "run_id=$RUN_ID"
  echo "groups_requested=$GROUPS_COUNT"
  echo "groups_created=${#ACTIVE_GROUPS[@]}"
  echo "connections_per_group=$CONNECTIONS_PER_GROUP"
  echo "target_connections_total=$TOTAL_TARGET"
  echo "avg_group_duration_s=$AVG_DURATION"
  echo "connect_ok_total=$TOTAL_CONNECT_OK"
  echo "connect_fail_total=$TOTAL_CONNECT_FAIL"
  echo "sends_ok_total=$TOTAL_SENDS_OK"
  echo "echo_ok_total=$TOTAL_ECHO_OK"
  echo "echo_mismatch_total=$TOTAL_ECHO_MISMATCH"
  echo "recv_fail_total=$TOTAL_RECV_FAIL"
  echo "disconnects_total=$TOTAL_DISCONNECTS"
  echo "latency_p50_ms_weighted=$AGG_P50"
  echo "latency_p95_ms_weighted=$AGG_P95"
  if [[ ${#ERROR_KEYS[@]} -gt 0 ]]; then
    echo "errors="
    for i in "${!ERROR_KEYS[@]}"; do
      echo "  ${ERROR_KEYS[$i]}: ${ERROR_VALUES[$i]}"
    done | sort
  fi
} > "$REPORT_FILE"

echo "Aggregate report saved to: $REPORT_FILE"

if [[ "$CLEANUP" == "true" ]]; then
  echo "Cleaning up container groups..."
  for group in "${ACTIVE_GROUPS[@]}"; do
    az container delete -g "$RESOURCE_GROUP" -n "$group" --yes >/dev/null &
  done
  wait
  echo "Cleanup complete."
else
  echo "Cleanup skipped (cleanup=false)."
fi
