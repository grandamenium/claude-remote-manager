#!/usr/bin/env bash
# enable-agent.sh - Enable a Claude Remote Manager agent
# Usage: enable-agent.sh <agent_name> [--restart]

set -euo pipefail

TEMPLATE_ROOT="$(cd "$(dirname "$0")" && pwd)"

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

# Configure per-agent Telegram MCP if agent has Telegram credentials.
# The Telegram plugin doesn't inherit env vars from the parent process,
# so we must configure the MCP server explicitly with env vars per agent.
ENV_FILE="${AGENT_DIR}/.env"
if [[ -f "${ENV_FILE}" ]]; then
    AGENT_TG_TOKEN=$(grep '^TELEGRAM_BOT_TOKEN=' "${ENV_FILE}" | cut -d= -f2)
    AGENT_TG_STATE=$(grep '^TELEGRAM_STATE_DIR=' "${ENV_FILE}" | cut -d= -f2)

    if [[ -n "${AGENT_TG_TOKEN}" && -n "${AGENT_TG_STATE}" ]]; then
        # Write token to state dir .env (safety net for plugin reads)
        mkdir -p "${AGENT_TG_STATE}"
        echo "TELEGRAM_BOT_TOKEN=${AGENT_TG_TOKEN}" > "${AGENT_TG_STATE}/.env"
        chmod 600 "${AGENT_TG_STATE}/.env"

        # Find the telegram plugin root (latest version)
        TG_PLUGIN_ROOT=$(ls -d "${HOME}/.claude/plugins/cache/claude-plugins-official/telegram/"*/server.ts 2>/dev/null | sort -V | tail -1 | xargs dirname)
        BUN_PATH="${HOME}/.bun/bin/bun"

        if [[ -n "${TG_PLUGIN_ROOT}" && -x "${BUN_PATH}" ]]; then
            # Write explicit Telegram MCP server config with env vars.
            # The global Telegram plugin doesn't inherit env vars from the parent
            # process, so project-level .claude.json provides the correct token.
            CLAUDE_JSON="${AGENT_DIR}/.claude.json"
            EXISTING=$(cat "${CLAUDE_JSON}" 2>/dev/null || echo '{}')

            NEW_CONFIG=$(echo "${EXISTING}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
data.setdefault('mcpServers', {})
data['mcpServers']['telegram'] = {
    'command': '${BUN_PATH}',
    'args': ['run', '--cwd', '${TG_PLUGIN_ROOT}', '--shell=bun', '--silent', 'start'],
    'env': {
        'TELEGRAM_BOT_TOKEN': '${AGENT_TG_TOKEN}',
        'TELEGRAM_STATE_DIR': '${AGENT_TG_STATE}'
    }
}
print(json.dumps(data, indent=2))
")
            echo "${NEW_CONFIG}" > "${CLAUDE_JSON}"
            echo "  Telegram MCP: configured with per-agent token and state dir"
        fi

        # Disable the global Telegram plugin at project level so it doesn't
        # override the per-agent MCP config above with the wrong token.
        AGENT_SETTINGS="${AGENT_DIR}/.claude/settings.json"
        mkdir -p "${AGENT_DIR}/.claude"
        EXISTING_SETTINGS=$(cat "${AGENT_SETTINGS}" 2>/dev/null || echo '{}')
        echo "${EXISTING_SETTINGS}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
data['enabledPlugins'] = {'telegram@claude-plugins-official': False}
print(json.dumps(data, indent=2))
" > "${AGENT_SETTINGS}"
        echo "  Telegram plugin: disabled (using project-level MCP with per-agent token)"
    fi
fi

# Generate and load launchd plist
echo ""
echo "Setting up persistence with launchd..."
"${TEMPLATE_ROOT}/core/scripts/generate-launchd.sh" "${AGENT}"

# Update enabled status
jq ".\"${AGENT}\".enabled = true | .\"${AGENT}\".status = \"configured\"" "${ENABLED_FILE}" > "${ENABLED_FILE}.tmp"
mv "${ENABLED_FILE}.tmp" "${ENABLED_FILE}"

echo ""
echo "========================================="
echo "  ${AGENT} is now LIVE"
echo "========================================="
echo ""
echo "  launchd: loaded (auto-restarts on crash)"
echo "  tmux: attach with: tmux attach -t crm-${CRM_INSTANCE_ID}-${AGENT}"
echo ""
echo "  Test it: Send a message to the agent's Telegram bot"
echo ""
