#!/usr/bin/env bash
# send-telegram.sh - Send a Telegram message or photo, optionally with inline keyboard
# Usage: send-telegram.sh <chat_id> "<message>" [inline_keyboard_json]
#        send-telegram.sh <chat_id> "<caption>" --image /path/to/image.jpg

set -euo pipefail

TEMPLATE_ROOT="${BOS_TEMPLATE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
BOS_AGENT_NAME="$(basename "$(pwd)")"
ME="${BOS_AGENT_NAME}"

# Parse arguments - handle --image flag
CHAT_ID="${1:-}"
MESSAGE="${2:-}"
KEYBOARD=""
IMAGE_PATH=""

shift 2 2>/dev/null || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)
            IMAGE_PATH="${2:-}"
            shift 2
            ;;
        *)
            KEYBOARD="$1"
            shift
            ;;
    esac
done

# Always source .env to get BOT_TOKEN
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

# Source shared Telegram helper (keeps token out of traces)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_telegram-curl.sh"

# Send photo if --image provided
if [[ -n "${IMAGE_PATH}" ]]; then
    if [[ ! -f "${IMAGE_PATH}" ]]; then
        echo "ERROR: Image file not found: ${IMAGE_PATH}" >&2
        exit 1
    fi
    RESPONSE=$(telegram_api_post "sendPhoto" \
        -F "chat_id=${CHAT_ID}" \
        -F "photo=@${IMAGE_PATH}" \
        -F "caption=${MESSAGE}" \
        -F "parse_mode=Markdown")
    if echo "${RESPONSE}" | jq -e '.ok' > /dev/null 2>&1; then
        echo "${RESPONSE}" | jq -r '.result.message_id'
    else
        echo "ERROR: Failed to send photo" >&2
        echo "${RESPONSE}" | jq -r '.description // "Unknown error"' >&2
        exit 1
    fi
    exit 0
fi

# Build text message request
if [[ -n "${KEYBOARD}" ]]; then
    KEYBOARD_VALID=$(echo "${KEYBOARD}" | jq -c '.' 2>/dev/null || echo '{"inline_keyboard":[]}')
    PAYLOAD=$(jq -n -c \
        --argjson chat_id "${CHAT_ID}" \
        --arg text "${MESSAGE}" \
        --argjson markup "${KEYBOARD_VALID}" \
        '{chat_id: $chat_id, text: $text, parse_mode: "Markdown", reply_markup: $markup}')
    RESPONSE=$(telegram_api_post "sendMessage" \
        -H "Content-Type: application/json" \
        -d "${PAYLOAD}")
else
    RESPONSE=$(telegram_api_post "sendMessage" \
        -d chat_id="${CHAT_ID}" \
        --data-urlencode "text=${MESSAGE}" \
        -d parse_mode="Markdown")
fi

# Check success
if echo "${RESPONSE}" | jq -e '.ok' > /dev/null 2>&1; then
    echo "${RESPONSE}" | jq -r '.result.message_id'
else
    echo "ERROR: Failed to send message" >&2
    echo "${RESPONSE}" | jq -r '.description // "Unknown error"' >&2
    exit 1
fi
