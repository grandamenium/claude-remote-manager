#!/usr/bin/env bash
# crash-alert.sh - SessionEnd hook for instant crash/exit alerting
# Called by Claude Code's SessionEnd hook in each agent's .claude/settings.json
# Receives JSON on stdin with: session_id, transcript_path, cwd, hook_event_name
# Environment: CRM_AGENT_NAME, CRM_ROOT, CRM_TEMPLATE_ROOT set by agent-wrapper.sh

set -uo pipefail  # No -e: best-effort alerting even if parts fail

CRM_ROOT="${CRM_ROOT:-${HOME}/.claude-remote}"
AGENT="${CRM_AGENT_NAME:-unknown}"
TEMPLATE_ROOT="${CRM_TEMPLATE_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"

# Load platform detection
if [[ -f "${TEMPLATE_ROOT}/core/scripts/platform.sh" ]]; then
    source "${TEMPLATE_ROOT}/core/scripts/platform.sh"
else
    is_windows() { [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "${OS:-}" == "Windows_NT" ]]; }
    is_macos() { [[ "$OSTYPE" == "darwin"* ]]; }
fi
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
LOG_DIR="${CRM_ROOT}/logs/${AGENT}"

mkdir -p "${LOG_DIR}"

# Read hook input from stdin (non-blocking, may be empty)
HOOK_INPUT=$(cat 2>/dev/null || echo '{}')
SESSION_ID=$(echo "${HOOK_INPUT}" | jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")

# Log the session end
echo "${TIMESTAMP} SESSION_END agent=${AGENT} session=${SESSION_ID}" >> "${LOG_DIR}/activity.log" 2>/dev/null

# Check crash count for context
CRASH_COUNT_FILE="${LOG_DIR}/.crash_count_today"
TODAY=$(date +%Y-%m-%d)
CRASH_COUNT=0
if [[ -f "${CRASH_COUNT_FILE}" ]]; then
    STORED_DATE=$(cut -d: -f1 "${CRASH_COUNT_FILE}" 2>/dev/null || echo "")
    if [[ "${STORED_DATE}" == "${TODAY}" ]]; then
        CRASH_COUNT=$(cut -d: -f2 "${CRASH_COUNT_FILE}" 2>/dev/null || echo "0")
    fi
fi

# Build alert message (platform-gated respawn method)
if is_windows; then
    RESPAWN_METHOD="PM2"
else
    RESPAWN_METHOD="launchd"
fi
MESSAGE="SESSION END: ${AGENT} exited at ${TIMESTAMP}. Crashes today: ${CRASH_COUNT}. ${RESPAWN_METHOD} will respawn."

# Send alert to the agent's Telegram chat
ENV_FILE="${TEMPLATE_ROOT}/agents/${AGENT}/.env"
if [[ -f "${ENV_FILE}" ]]; then
    { set +x; } 2>/dev/null
    set -a; source "${ENV_FILE}"; set +a
fi

if [[ -n "${BOT_TOKEN:-}" && -n "${CHAT_ID:-}" ]]; then
    source "${TEMPLATE_ROOT}/core/bus/_telegram-curl.sh"
    telegram_api_post "sendMessage" \
        -d chat_id="${CHAT_ID}" \
        --data-urlencode "text=${MESSAGE}" \
        > /dev/null 2>&1 || true
fi

exit 0
