#!/usr/bin/env bash
# setup.sh - Interactive onboarding: create a new agent from template
# Creates agent directory, configures Telegram, generates launchd, and starts the agent.

set -euo pipefail

# Dependency checks
MISSING=""
command -v tmux >/dev/null 2>&1 || MISSING="${MISSING} tmux"
command -v jq >/dev/null 2>&1 || MISSING="${MISSING} jq"
command -v claude >/dev/null 2>&1 || MISSING="${MISSING} claude"

if [[ -n "$MISSING" ]]; then
    echo "ERROR: Missing required dependencies:${MISSING}"
    echo ""
    [[ "$MISSING" == *"tmux"* ]] && echo "  tmux:   brew install tmux"
    [[ "$MISSING" == *"jq"* ]] && echo "  jq:     brew install jq"
    [[ "$MISSING" == *"claude"* ]] && echo "  claude: https://docs.anthropic.com/en/docs/claude-code"
    echo ""
    echo "Install the missing dependencies and run this again."
    exit 1
fi

# Check that claude is authenticated
if ! claude --version >/dev/null 2>&1; then
    echo "ERROR: Claude CLI is installed but may not be set up."
    echo "  Run 'claude' in a terminal first to accept terms and log in."
    echo "  Once that works, run this again."
    exit 1
fi

TEMPLATE_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Check if installed
if [[ ! -f "${TEMPLATE_ROOT}/.env" ]]; then
    echo "ERROR: Run ./install.sh first to create state directories."
    exit 1
fi

# Load instance ID
CRM_INSTANCE_ID=$(grep '^CRM_INSTANCE_ID=' "${TEMPLATE_ROOT}/.env" | cut -d= -f2)
CRM_INSTANCE_ID="${CRM_INSTANCE_ID:-default}"
CRM_ROOT="${HOME}/.claude-remote/${CRM_INSTANCE_ID}"

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

if [[ ! "${AGENT_NAME}" =~ ^[a-z0-9_-]+$ ]]; then
    echo "ERROR: Agent name can only contain lowercase letters, numbers, hyphens, and underscores."
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

# Auto-detect Chat ID via long-polling getUpdates
echo ""
echo "Almost there! Now link your Telegram account:"
echo ""
echo "  1. Open Telegram and find your new bot (search by username)"
echo "  2. Tap START (or send /start) — this is required for new bots"
echo "  3. Send any message after /start (e.g. 'hello')"
echo ""
echo "Waiting for your message (30 second timeout)..."
echo ""

CHAT_ID=""
for attempt in 1 2 3; do
    UPDATES=$(curl -s --max-time 35 \
        "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?timeout=30&offset=0&limit=5" 2>/dev/null || true)
    CHAT_ID=$(echo "${UPDATES}" | jq -r '[.result[] | select(.message.chat.id != null)] | last | .message.chat.id // empty' 2>/dev/null || true)

    if [[ -n "${CHAT_ID}" && "${CHAT_ID}" != "null" ]]; then
        FROM_NAME=$(echo "${UPDATES}" | jq -r '[.result[] | select(.message.chat.id != null)] | last | .message.from.first_name // "you"' 2>/dev/null || true)
        echo "  Detected chat ID: ${CHAT_ID} (from: ${FROM_NAME})"
        break
    fi

    if [[ $attempt -lt 3 ]]; then
        echo "  No message received yet. Make sure you sent /start first, then try again..."
        sleep 2
    fi
done

if [[ -z "${CHAT_ID}" || "${CHAT_ID}" == "null" ]]; then
    echo ""
    echo "  Auto-detection timed out. To find your Chat ID manually:"
    echo "    Visit: https://api.telegram.org/bot${BOT_TOKEN}/getUpdates"
    echo "    Look for: \"chat\":{\"id\":YOUR_CHAT_ID}"
    echo ""
    read -rp "Your Telegram Chat ID: " CHAT_ID
fi

if [[ -z "${CHAT_ID}" ]]; then
    echo "ERROR: Chat ID cannot be empty."
    rm -rf "${AGENT_DIR}"
    exit 1
fi

# Ask for allowed user ID (required for security)
echo ""
echo "For security, enter your Telegram User ID to restrict who can message the bot."
echo "(This is usually the same as Chat ID for private chats.)"
read -rp "Allowed User ID: " ALLOWED_USER

if [[ -z "${ALLOWED_USER}" ]]; then
    echo "  Auto-detecting from Chat ID (same for private chats)..."
    ALLOWED_USER="${CHAT_ID}"
    echo "  Using: ${ALLOWED_USER}"
fi

# Write .env file
cat > "${AGENT_DIR}/.env" << EOF
BOT_TOKEN=${BOT_TOKEN}
CHAT_ID=${CHAT_ID}
ALLOWED_USER=${ALLOWED_USER}
EOF
chmod 600 "${AGENT_DIR}/.env"

# Update config.json with agent name
TEMP_CONFIG=$(mktemp)
jq --arg name "${AGENT_NAME}" '.agent_name = $name' "${AGENT_DIR}/config.json" > "${TEMP_CONFIG}"
mv "${TEMP_CONFIG}" "${AGENT_DIR}/config.json"

# Create per-agent state directories (700 = owner-only access)
mkdir -p "${CRM_ROOT}/inbox/${AGENT_NAME}" && chmod 700 "${CRM_ROOT}/inbox/${AGENT_NAME}"
mkdir -p "${CRM_ROOT}/outbox/${AGENT_NAME}" && chmod 700 "${CRM_ROOT}/outbox/${AGENT_NAME}"
mkdir -p "${CRM_ROOT}/processed/${AGENT_NAME}" && chmod 700 "${CRM_ROOT}/processed/${AGENT_NAME}"
mkdir -p "${CRM_ROOT}/inflight/${AGENT_NAME}" && chmod 700 "${CRM_ROOT}/inflight/${AGENT_NAME}"
mkdir -p "${CRM_ROOT}/logs/${AGENT_NAME}" && chmod 700 "${CRM_ROOT}/logs/${AGENT_NAME}"

# Make all scripts executable
chmod +x "${TEMPLATE_ROOT}/"*.sh 2>/dev/null || true
chmod +x "${TEMPLATE_ROOT}/core/scripts/"*.sh 2>/dev/null || true
chmod +x "${TEMPLATE_ROOT}/core/bus/"*.sh 2>/dev/null || true

# Generate launchd plist
echo ""
echo "Generating launchd service..."
"${TEMPLATE_ROOT}/core/scripts/generate-launchd.sh" "${AGENT_NAME}"

# Update enabled-agents.json
ENABLED_FILE="${CRM_ROOT}/config/enabled-agents.json"
jq ".\"${AGENT_NAME}\".enabled = true | .\"${AGENT_NAME}\".status = \"configured\"" "${ENABLED_FILE}" > "${ENABLED_FILE}.tmp"
mv "${ENABLED_FILE}.tmp" "${ENABLED_FILE}"

echo ""
echo "========================================="
echo "  Done! Your agent is now running."
echo "========================================="
echo ""
echo "  Agent:   ${AGENT_NAME}"
echo "  Dir:     ${AGENT_DIR}"
echo "  tmux:    tmux attach -t crm-${CRM_INSTANCE_ID}-${AGENT_NAME}"
echo "  Logs:    ${CRM_ROOT}/logs/${AGENT_NAME}/"
echo ""
echo "  NOTE: Claude Code may prompt you to trust this directory on first boot."
echo "  If your agent doesn't come online, attach to the tmux session to approve:"
echo ""
echo "    tmux attach -t crm-${CRM_INSTANCE_ID}-${AGENT_NAME}"
echo ""
echo "  Approve the trust prompt, then detach with Ctrl-b d."
echo "  After that, message your Telegram bot to start."
echo ""
