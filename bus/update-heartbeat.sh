#!/usr/bin/env bash
# update-heartbeat.sh - Update this agent's heartbeat (per-agent file)
# Usage: update-heartbeat.sh [current_task]

set -euo pipefail

BOS_ROOT="${BOS_ROOT:-${HOME}/.business-os}"
BOS_AGENT_NAME="$(basename "$(pwd)")"
ME="${BOS_AGENT_NAME}"
TEMPLATE_ROOT="${BOS_TEMPLATE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

CURRENT_TASK="${1:-idle}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Read loop interval from config (from crons array, heartbeat entry)
CONFIG_FILE="${TEMPLATE_ROOT}/agents/${ME}/config.json"
LOOP_INTERVAL=$(jq -r '.crons[] | select(.name == "heartbeat") | .interval // "4h"' "${CONFIG_FILE}" 2>/dev/null || echo "4h")

# Write to per-agent heartbeat file
HEARTBEAT_DIR="${BOS_ROOT}/state/heartbeat"
mkdir -p "${HEARTBEAT_DIR}"

TMP="${HEARTBEAT_DIR}/${ME}.json.tmp"
FINAL="${HEARTBEAT_DIR}/${ME}.json"

jq -n -c \
    --arg ts "${TIMESTAMP}" \
    --arg task "${CURRENT_TASK}" \
    --arg interval "${LOOP_INTERVAL}" \
    --arg status "healthy" \
    '{last_heartbeat:$ts, status:$status, current_task:$task, loop_interval:$interval}' \
    > "${TMP}" && mv "${TMP}" "${FINAL}"
