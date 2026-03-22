#!/usr/bin/env bash
# disable-agent.sh - Disable a Claude Remote Manager agent
# Usage: disable-agent.sh <agent_name>

set -euo pipefail

TEMPLATE_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Load instance ID
REPO_ENV="${TEMPLATE_ROOT}/.env"
if [[ -f "${REPO_ENV}" ]]; then
    BOS_INSTANCE_ID=$(grep '^BOS_INSTANCE_ID=' "${REPO_ENV}" | cut -d= -f2)
fi
BOS_INSTANCE_ID="${BOS_INSTANCE_ID:-default}"
BOS_ROOT="${HOME}/.business-os/${BOS_INSTANCE_ID}"

AGENT="${1:?Usage: disable-agent.sh <agent_name>}"
ENABLED_FILE="${BOS_ROOT}/config/enabled-agents.json"

echo "Disabling ${AGENT}..."

# Unload launchd plist
PLIST="${HOME}/Library/LaunchAgents/com.business-os.${BOS_INSTANCE_ID}.${AGENT}.plist"
if [[ -f "${PLIST}" ]]; then
    launchctl unload "${PLIST}" 2>/dev/null || true
    echo "  launchd: unloaded"
fi

# Kill tmux session if running
TMUX_SESSION="bos-${BOS_INSTANCE_ID}-${AGENT}"
tmux kill-session -t "${TMUX_SESSION}" 2>/dev/null || true

# Update enabled status
if [[ -f "${ENABLED_FILE}" ]]; then
    jq ".\"${AGENT}\".enabled = false" "${ENABLED_FILE}" > "${ENABLED_FILE}.tmp"
    mv "${ENABLED_FILE}.tmp" "${ENABLED_FILE}"
fi

echo "  status: disabled"
echo ""
echo "${AGENT} is now disabled. Its configuration is preserved."
echo "Re-enable with: ./enable-agent.sh ${AGENT}"
