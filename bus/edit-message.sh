#!/usr/bin/env bash
# edit-message.sh - Edit an existing Telegram message text and optionally remove inline keyboard
# Usage: edit-message.sh <chat_id> <message_id> <new_text> [reply_markup_json]

set -euo pipefail

TEMPLATE_ROOT="${BOS_TEMPLATE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
BOS_AGENT_NAME="$(basename "$(pwd)")"
ME="${BOS_AGENT_NAME}"

CHAT_ID="$1"
MESSAGE_ID="$2"
NEW_TEXT="$3"
REPLY_MARKUP="${4:-}"

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

SCRIPT_DIR_EDIT="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR_EDIT}/_telegram-curl.sh"

if [[ -n "${REPLY_MARKUP}" && "${REPLY_MARKUP}" != "null" ]]; then
    PAYLOAD=$(jq -n \
        --argjson chat_id "${CHAT_ID}" \
        --argjson message_id "${MESSAGE_ID}" \
        --arg text "${NEW_TEXT}" \
        --argjson markup "${REPLY_MARKUP}" \
        '{chat_id: $chat_id, message_id: $message_id, text: $text, parse_mode: "Markdown", reply_markup: $markup}')
else
    PAYLOAD=$(jq -n \
        --argjson chat_id "${CHAT_ID}" \
        --argjson message_id "${MESSAGE_ID}" \
        --arg text "${NEW_TEXT}" \
        '{chat_id: $chat_id, message_id: $message_id, text: $text, parse_mode: "Markdown", reply_markup: {"inline_keyboard": []}}')
fi

RESPONSE=$(telegram_api_post "editMessageText" \
    -H "Content-Type: application/json" \
    -d "${PAYLOAD}")

if ! echo "${RESPONSE}" | jq -e '.ok' > /dev/null 2>&1; then
    echo "ERROR: Failed to edit message" >&2
    echo "${RESPONSE}" | jq -r '.description // "Unknown error"' >&2
    exit 1
fi
