#!/usr/bin/env bash
# disable-agent.sh - Disable a Claude Remote Manager agent
# Usage: disable-agent.sh <agent_name>

set -euo pipefail

TEMPLATE_ROOT="$(cd "$(dirname "$0")" && pwd)"
source "${TEMPLATE_ROOT}/core/scripts/platform.sh"

# Load instance ID
REPO_ENV="${TEMPLATE_ROOT}/.env"
if [[ -f "${REPO_ENV}" ]]; then
    CRM_INSTANCE_ID=$(grep '^CRM_INSTANCE_ID=' "${REPO_ENV}" | cut -d= -f2)
fi
CRM_INSTANCE_ID="${CRM_INSTANCE_ID:-default}"
CRM_ROOT="${HOME}/.claude-remote/${CRM_INSTANCE_ID}"

AGENT="${1:?Usage: disable-agent.sh <agent_name>}"
ENABLED_FILE="${CRM_ROOT}/config/enabled-agents.json"

echo "Disabling ${AGENT}..."

if is_macos; then
    # Unload launchd plist
    PLIST="${HOME}/Library/LaunchAgents/com.claude-remote.${CRM_INSTANCE_ID}.${AGENT}.plist"
    if [[ -f "${PLIST}" ]]; then
        launchctl unload "${PLIST}" 2>/dev/null || true
        echo "  launchd: unloaded"
    fi

    # Kill tmux session if running
    TMUX_SESSION="crm-${CRM_INSTANCE_ID}-${AGENT}"
    tmux kill-session -t "${TMUX_SESSION}" 2>/dev/null || true
elif is_windows; then
    PM2_NAME="crm-${CRM_INSTANCE_ID}-${AGENT}"
    pm2 stop "${PM2_NAME}" 2>/dev/null || true
    pm2 delete "${PM2_NAME}" 2>/dev/null || true
    pm2 save 2>/dev/null || true
    echo "  PM2: stopped and removed"
fi

# Update enabled status
if [[ -f "${ENABLED_FILE}" ]]; then
    jq ".\"${AGENT}\".enabled = false" "${ENABLED_FILE}" > "${ENABLED_FILE}.tmp"
    mv "${ENABLED_FILE}.tmp" "${ENABLED_FILE}"
fi

echo "  status: disabled"
echo ""
echo "${AGENT} is now disabled. Its configuration is preserved."
echo "Re-enable with: ./enable-agent.sh ${AGENT}"
