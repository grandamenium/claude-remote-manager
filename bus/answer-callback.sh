#!/usr/bin/env bash
# answer-callback.sh - Answer a Telegram callback query to dismiss button loading state
# Usage: answer-callback.sh <callback_query_id> [toast_text]

set -euo pipefail

TEMPLATE_ROOT="${BOS_TEMPLATE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
BOS_AGENT_NAME="$(basename "$(pwd)")"
ME="${BOS_AGENT_NAME}"

CALLBACK_QUERY_ID="$1"
TOAST_TEXT="${2:-Got it}"

# Source BOT_TOKEN
ENV_FILE="${TEMPLATE_ROOT}/agents/${ME}/.env"
{ set +x; } 2>/dev/null
if [[ -f "${ENV_FILE}" ]]; then
    set -a; source "${ENV_FILE}"; set +a
elif [[ -f ".env" ]]; then
    set -a; source ".env"; set +a
fi

if [[ -z "${BOT_TOKEN:-}" ]]; then
    echo "ERROR: No bot token configured for ${ME}" >&2
    exit 1
fi

SCRIPT_DIR_CB="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR_CB}/_telegram-curl.sh"

PAYLOAD=$(jq -n -c \
    --arg cqid "${CALLBACK_QUERY_ID}" \
    --arg text "${TOAST_TEXT}" \
    '{callback_query_id: $cqid, text: $text}')

telegram_api_post "answerCallbackQuery" \
    -H "Content-Type: application/json" \
    -d "${PAYLOAD}" > /dev/null
