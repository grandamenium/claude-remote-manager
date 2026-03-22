#!/usr/bin/env bash
# enable-agent.sh - Enable a Claude Remote Manager agent
# Usage: enable-agent.sh <agent_name> [--restart]

set -euo pipefail

TEMPLATE_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Load instance ID
REPO_ENV="${TEMPLATE_ROOT}/.env"
if [[ -f "${REPO_ENV}" ]]; then
    BOS_INSTANCE_ID=$(grep '^BOS_INSTANCE_ID=' "${REPO_ENV}" | cut -d= -f2)
fi
BOS_INSTANCE_ID="${BOS_INSTANCE_ID:-default}"
BOS_ROOT="${HOME}/.business-os/${BOS_INSTANCE_ID}"

AGENT="${1:?Usage: enable-agent.sh <agent_name> [--restart]}"
RESTART=false
[[ "${2:-}" == "--restart" ]] && RESTART=true

AGENT_DIR="${TEMPLATE_ROOT}/agents/${AGENT}"
ENABLED_FILE="${BOS_ROOT}/config/enabled-agents.json"

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
    rm -f "${BOS_ROOT}/logs/${AGENT}/.crash_count_today"

    # Reload launchd
    PLIST="${HOME}/Library/LaunchAgents/com.business-os.${BOS_INSTANCE_ID}.${AGENT}.plist"
    if [[ -f "${PLIST}" ]]; then
        launchctl unload "${PLIST}" 2>/dev/null || true
        launchctl load "${PLIST}"
        echo "${AGENT} restarted."
    else
        echo "No launchd plist found. Running full setup..."
        "${TEMPLATE_ROOT}/scripts/generate-launchd.sh" "${AGENT}"
    fi
    exit 0
fi

# Set environment for the agent
export BOS_AGENT_NAME="${AGENT}"
export BOS_INSTANCE_ID="${BOS_INSTANCE_ID}"
export BOS_ROOT="${BOS_ROOT}"
export BOS_TEMPLATE_ROOT="${TEMPLATE_ROOT}"

# Ensure all scripts are executable
chmod +x "${TEMPLATE_ROOT}/"*.sh 2>/dev/null || true
chmod +x "${TEMPLATE_ROOT}/scripts/"*.sh 2>/dev/null || true
chmod +x "${TEMPLATE_ROOT}/bus/"*.sh 2>/dev/null || true

# Create per-agent state directories
mkdir -p "${BOS_ROOT}/inbox/${AGENT}"
mkdir -p "${BOS_ROOT}/outbox/${AGENT}"
mkdir -p "${BOS_ROOT}/processed/${AGENT}"
mkdir -p "${BOS_ROOT}/inflight/${AGENT}"
mkdir -p "${BOS_ROOT}/logs/${AGENT}"

# Generate and load launchd plist
echo ""
echo "Setting up persistence with launchd..."
"${TEMPLATE_ROOT}/scripts/generate-launchd.sh" "${AGENT}"

# Update enabled status
jq ".\"${AGENT}\".enabled = true | .\"${AGENT}\".status = \"configured\"" "${ENABLED_FILE}" > "${ENABLED_FILE}.tmp"
mv "${ENABLED_FILE}.tmp" "${ENABLED_FILE}"

echo ""
echo "========================================="
echo "  ${AGENT} is now LIVE"
echo "========================================="
echo ""
echo "  launchd: loaded (auto-restarts on crash)"
echo "  tmux: attach with: tmux attach -t bos-${BOS_INSTANCE_ID}-${AGENT}"
echo ""
echo "  Test it: Send a message to the agent's Telegram bot"
echo ""
