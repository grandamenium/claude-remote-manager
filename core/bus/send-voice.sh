#!/bin/bash
# Send a voice message via Telegram Bot API
# Usage: bash send-voice.sh <chat_id> "<text to speak>"

CHAT_ID="$1"
TEXT="$2"

if [ -z "$CHAT_ID" ] || [ -z "$TEXT" ]; then
  echo "Usage: bash send-voice.sh <chat_id> \"<text>\""
  exit 1
fi

# Load bot token from CortextOS agent .env (same source as send-telegram.sh)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_ROOT="${CRM_TEMPLATE_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
CRM_AGENT_NAME="${CRM_AGENT_NAME:-$(basename "$(pwd)")}"
ENV_FILE="${TEMPLATE_ROOT}/agents/${CRM_AGENT_NAME}/.env"

if [[ -f "${ENV_FILE}" ]]; then
  set -a; source "${ENV_FILE}"; set +a
elif [[ -f ".env" ]]; then
  set -a; source ".env"; set +a
fi

if [ -z "${BOT_TOKEN:-}" ]; then
  echo "ERROR: BOT_TOKEN not set in ${ENV_FILE}"
  exit 1
fi

TMP_AIFF=$(mktemp /tmp/dane-voice-XXXXXX.aiff)
TMP_OGG=$(mktemp /tmp/dane-voice-XXXXXX.ogg)

# Generate speech
say -o "$TMP_AIFF" "$TEXT"

# Convert to ogg opus
ffmpeg -y -i "$TMP_AIFF" -c:a libopus -b:a 64k "$TMP_OGG" 2>/dev/null

# Send voice message
RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendVoice" \
  -F "chat_id=${CHAT_ID}" \
  -F "voice=@${TMP_OGG}")

# Cleanup
rm -f "$TMP_AIFF" "$TMP_OGG"

echo "$RESPONSE" | jq '.ok, .result.message_id' 2>/dev/null || echo "$RESPONSE"
