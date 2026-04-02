#!/usr/bin/env bash
# enable-agent.sh - Enable a Claude Remote Manager agent
# Usage: enable-agent.sh <agent_name> [--restart]

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

AGENT="${1:?Usage: enable-agent.sh <agent_name> [--restart]}"
RESTART=false
[[ "${2:-}" == "--restart" ]] && RESTART=true

AGENT_DIR="${TEMPLATE_ROOT}/agents/${AGENT}"
ENABLED_FILE="${CRM_ROOT}/config/enabled-agents.json"

# Validate agent directory exists
if [[ ! -d "${AGENT_DIR}" ]]; then
    echo "ERROR: Unknown agent '${AGENT}' - no directory at ${AGENT_DIR}"
    echo "Available agents:"
    for d in "${TEMPLATE_ROOT}/agents"/*/; do
        name=$(basename "$d")
        [[ "${name}" == "agent-template" ]] && continue
        echo "  ${name}"
    done
    exit 1
fi

# Check if already enabled (unless restarting)
if [[ "${RESTART}" != "true" ]]; then
    IS_ENABLED=$(jq -r ".\"${AGENT}\".enabled" "${ENABLED_FILE}" 2>/dev/null || echo "false")
    if [[ "${IS_ENABLED}" == "true" ]]; then
        echo "${AGENT} is already enabled."
        echo "Use --restart to restart it, or ./disable-agent.sh ${AGENT} first."
        exit 0
    fi
fi

echo "========================================="
echo "  Enabling: ${AGENT}"
echo "========================================="
echo ""

if [[ "${RESTART}" == "true" ]]; then
    echo "Restarting ${AGENT}..."

    # Reset crash counter
    rm -f "${CRM_ROOT}/logs/${AGENT}/.crash_count_today"

    if is_macos; then
        # Reload launchd
        PLIST="${HOME}/Library/LaunchAgents/com.claude-remote.${CRM_INSTANCE_ID}.${AGENT}.plist"
        if [[ -f "${PLIST}" ]]; then
            launchctl unload "${PLIST}" 2>/dev/null || true
            launchctl load "${PLIST}"
            echo "${AGENT} restarted."
        else
            echo "No launchd plist found. Running full setup..."
            "${TEMPLATE_ROOT}/core/scripts/generate-launchd.sh" "${AGENT}"
        fi
    elif is_windows; then
        PM2_NAME="crm-${CRM_INSTANCE_ID}-${AGENT}"
        if pm2 jlist 2>/dev/null | jq -e ".[] | select(.name == \"${PM2_NAME}\")" >/dev/null 2>&1; then
            pm2 restart "${PM2_NAME}"
            echo "${AGENT} restarted."
        else
            echo "No PM2 process found. Running full setup..."
            "${TEMPLATE_ROOT}/core/scripts/generate-pm2.sh" "${AGENT}"
        fi
    fi
    exit 0
fi

# Set environment for the agent
export CRM_AGENT_NAME="${AGENT}"
export CRM_INSTANCE_ID="${CRM_INSTANCE_ID}"
export CRM_ROOT="${CRM_ROOT}"
export CRM_TEMPLATE_ROOT="${TEMPLATE_ROOT}"

# Ensure all scripts are executable
chmod +x "${TEMPLATE_ROOT}/"*.sh 2>/dev/null || true
chmod +x "${TEMPLATE_ROOT}/core/scripts/"*.sh 2>/dev/null || true
chmod +x "${TEMPLATE_ROOT}/core/bus/"*.sh 2>/dev/null || true

# Create per-agent state directories
mkdir -p "${CRM_ROOT}/inbox/${AGENT}"
mkdir -p "${CRM_ROOT}/outbox/${AGENT}"
mkdir -p "${CRM_ROOT}/processed/${AGENT}"
mkdir -p "${CRM_ROOT}/inflight/${AGENT}"
mkdir -p "${CRM_ROOT}/logs/${AGENT}"

# Generate and load service (platform-gated)
echo ""
if is_macos; then
    echo "Setting up persistence with launchd..."
    "${TEMPLATE_ROOT}/core/scripts/generate-launchd.sh" "${AGENT}"
elif is_windows; then
    echo "Setting up persistence with PM2..."
    "${TEMPLATE_ROOT}/core/scripts/generate-pm2.sh" "${AGENT}"
fi

# Update enabled status
jq ".\"${AGENT}\".enabled = true | .\"${AGENT}\".status = \"configured\"" "${ENABLED_FILE}" > "${ENABLED_FILE}.tmp"
mv "${ENABLED_FILE}.tmp" "${ENABLED_FILE}"

echo ""
echo "========================================="
echo "  ${AGENT} is now LIVE"
echo "========================================="
echo ""
if is_macos; then
    echo "  launchd: loaded (auto-restarts on crash)"
    echo "  tmux: attach with: tmux attach -t crm-${CRM_INSTANCE_ID}-${AGENT}"
elif is_windows; then
    echo "  PM2: running (auto-restarts on crash)"
    echo "  Logs: pm2 logs crm-${CRM_INSTANCE_ID}-${AGENT}"
fi
echo ""
echo "  Test it: Send a message to the agent's Telegram bot"
echo ""
