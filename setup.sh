#!/usr/bin/env bash
# setup.sh - Interactive onboarding: create a new agent from template
# Creates agent directory, configures Telegram, generates launchd, and starts the agent.

set -euo pipefail

TEMPLATE_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Check if installed
if [[ ! -f "${TEMPLATE_ROOT}/.env" ]]; then
    echo "ERROR: Run ./install.sh first to create state directories."
    exit 1
fi

# Load instance ID
BOS_INSTANCE_ID=$(grep '^BOS_INSTANCE_ID=' "${TEMPLATE_ROOT}/.env" | cut -d= -f2)
BOS_INSTANCE_ID="${BOS_INSTANCE_ID:-default}"
BOS_ROOT="${HOME}/.business-os/${BOS_INSTANCE_ID}"

echo "========================================="
echo "  Claude Remote Manager - Agent Setup"
echo "========================================="
echo ""

# Ask for agent name
read -rp "Agent name (lowercase, no spaces, e.g. 'assistant'): " AGENT_NAME
AGENT_NAME=$(echo "${AGENT_NAME}" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

if [[ -z "${AGENT_NAME}" ]]; then
    echo "ERROR: Agent name cannot be empty."
    exit 1
fi

AGENT_DIR="${TEMPLATE_ROOT}/agents/${AGENT_NAME}"

if [[ -d "${AGENT_DIR}" ]]; then
    echo "ERROR: Agent '${AGENT_NAME}' already exists at ${AGENT_DIR}"
    exit 1
fi

# Copy template
echo ""
echo "Creating agent from template..."
cp -r "${TEMPLATE_ROOT}/agents/agent-template" "${AGENT_DIR}"

# Ask for Telegram bot token
echo ""
echo "Create a Telegram bot via @BotFather and paste the token below."
echo "  1. Open Telegram, search for @BotFather"
echo "  2. Send /newbot, follow the prompts"
echo "  3. Copy the HTTP API token"
echo ""
read -rp "Telegram Bot Token: " BOT_TOKEN

if [[ -z "${BOT_TOKEN}" ]]; then
    echo "ERROR: Bot token cannot be empty."
    rm -rf "${AGENT_DIR}"
    exit 1
fi

# Ask for chat ID
echo ""
echo "To get your Chat ID:"
echo "  1. Send any message to your new bot on Telegram"
echo "  2. Visit: https://api.telegram.org/bot${BOT_TOKEN}/getUpdates"
echo "  3. Look for \"chat\":{\"id\":YOUR_CHAT_ID}"
echo ""
read -rp "Your Telegram Chat ID: " CHAT_ID

if [[ -z "${CHAT_ID}" ]]; then
    echo "ERROR: Chat ID cannot be empty."
    rm -rf "${AGENT_DIR}"
    exit 1
fi

# Ask for allowed user ID (optional)
echo ""
echo "For security, enter your Telegram User ID to restrict who can message the bot."
echo "(This is usually the same as Chat ID for private chats. Leave blank to allow anyone.)"
read -rp "Allowed User ID (optional): " ALLOWED_USER

# Write .env file
cat > "${AGENT_DIR}/.env" << EOF
BOT_TOKEN=${BOT_TOKEN}
CHAT_ID=${CHAT_ID}
ALLOWED_USER=${ALLOWED_USER}
EOF

# Update config.json with agent name
TEMP_CONFIG=$(mktemp)
jq --arg name "${AGENT_NAME}" '.agent_name = $name' "${AGENT_DIR}/config.json" > "${TEMP_CONFIG}"
mv "${TEMP_CONFIG}" "${AGENT_DIR}/config.json"

# Create per-agent state directories
mkdir -p "${BOS_ROOT}/inbox/${AGENT_NAME}"
mkdir -p "${BOS_ROOT}/outbox/${AGENT_NAME}"
mkdir -p "${BOS_ROOT}/processed/${AGENT_NAME}"
mkdir -p "${BOS_ROOT}/inflight/${AGENT_NAME}"
mkdir -p "${BOS_ROOT}/logs/${AGENT_NAME}"

# Make all scripts executable
chmod +x "${TEMPLATE_ROOT}/"*.sh 2>/dev/null || true
chmod +x "${TEMPLATE_ROOT}/scripts/"*.sh 2>/dev/null || true
chmod +x "${TEMPLATE_ROOT}/bus/"*.sh 2>/dev/null || true

# Generate launchd plist
echo ""
echo "Generating launchd service..."
"${TEMPLATE_ROOT}/scripts/generate-launchd.sh" "${AGENT_NAME}"

# Update enabled-agents.json
ENABLED_FILE="${BOS_ROOT}/config/enabled-agents.json"
jq ".\"${AGENT_NAME}\".enabled = true | .\"${AGENT_NAME}\".status = \"configured\"" "${ENABLED_FILE}" > "${ENABLED_FILE}.tmp"
mv "${ENABLED_FILE}.tmp" "${ENABLED_FILE}"

echo ""
echo "========================================="
echo "  Done! Your agent is now running."
echo "========================================="
echo ""
echo "  Agent:   ${AGENT_NAME}"
echo "  Dir:     ${AGENT_DIR}"
echo "  tmux:    tmux attach -t bos-${BOS_INSTANCE_ID}-${AGENT_NAME}"
echo "  Logs:    ${BOS_ROOT}/logs/${AGENT_NAME}/"
echo ""
echo "  Message your Telegram bot to start."
echo ""
