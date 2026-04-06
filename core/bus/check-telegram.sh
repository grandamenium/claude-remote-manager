#!/usr/bin/env bash
# check-telegram.sh - Check for new Telegram messages for this agent's bot
# Usage: check-telegram.sh
# Requires: CRM_AGENT_NAME, BOT_TOKEN from environment (.env)

set -euo pipefail

CRM_ROOT="${CRM_ROOT:-${HOME}/.claude-remote}"
TEMPLATE_ROOT="${CRM_TEMPLATE_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
# Always detect from cwd
CRM_AGENT_NAME="${CRM_AGENT_NAME:-$(basename "$(pwd)")}"
ME="${CRM_AGENT_NAME}"

# Always source .env to get BOT_TOKEN
ENV_FILE="${TEMPLATE_ROOT}/agents/${ME}/.env"
{ set +x; } 2>/dev/null
if [[ -f "${ENV_FILE}" ]]; then
    set -a; source "${ENV_FILE}"; set +a
elif [[ -f ".env" ]]; then
    set -a; source ".env"; set +a
fi

if [[ -z "${BOT_TOKEN:-}" ]]; then
    exit 0  # No bot token configured, skip silently
fi

# Source shared Telegram helper (keeps token out of traces)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_telegram-curl.sh"

# ALLOWED_USER is required - reject all messages if not configured
ALLOWED_USER="${ALLOWED_USER:-}"
if [[ -z "${ALLOWED_USER}" ]]; then
    exit 0
fi
OFFSET_FILE="${CRM_ROOT}/state/.telegram-offset-${ME}"

# Read last offset
OFFSET=$(cat "${OFFSET_FILE}" 2>/dev/null || echo "0")

# Poll Telegram
RESPONSE=$(telegram_api_get "getUpdates?offset=${OFFSET}&timeout=5" 2>/dev/null || echo '{"ok":false}')

# Check if response is valid
if ! echo "${RESPONSE}" | jq -e '.ok' > /dev/null 2>&1; then
    exit 0
fi

# Filter messages
MESSAGES=$(echo "${RESPONSE}" | jq --arg uid "${ALLOWED_USER}" \
    '[.result[] | select(.message.from.id == ($uid | tonumber) or .callback_query.from.id == ($uid | tonumber))]')

MSG_COUNT=$(echo "${MESSAGES}" | jq 'length')

IMAGE_DIR="${TELEGRAM_IMAGE_DIR:-${TEMPLATE_ROOT}/agents/${ME}/telegram-images}"
mkdir -p "${IMAGE_DIR}"

if [[ "${MSG_COUNT}" -gt 0 ]]; then
    # Output regular text messages
    echo "${MESSAGES}" | jq -c '.[] | select(.message and .message.text) | {
        chat_id: .message.chat.id,
        from: .message.from.first_name,
        text: .message.text,
        date: .message.date,
        type: "message"
    }'

    # Handle photo messages: download largest size and output with local path
    while IFS= read -r photo_msg; do
        CHAT_ID_VAL=$(echo "${photo_msg}" | jq -r '.chat_id')
        FROM_VAL=$(echo "${photo_msg}" | jq -r '.from')
        DATE_VAL=$(echo "${photo_msg}" | jq -r '.date')
        CAPTION_VAL=$(echo "${photo_msg}" | jq -r '.caption // ""')
        FILE_ID=$(echo "${photo_msg}" | jq -r '.file_id')

        FILE_RESPONSE=$(telegram_api_get "getFile?file_id=${FILE_ID}" 2>/dev/null || echo '{"ok":false}')
        FILE_PATH=$(echo "${FILE_RESPONSE}" | jq -r '.result.file_path // empty')

        if [[ -n "${FILE_PATH}" ]]; then
            LOCAL_FILE="${IMAGE_DIR}/${DATE_VAL}.jpg"
            telegram_file_download "${FILE_PATH}" "${LOCAL_FILE}" 2>/dev/null || true

            jq -nc \
                --arg chat_id "${CHAT_ID_VAL}" \
                --arg from "${FROM_VAL}" \
                --arg caption "${CAPTION_VAL}" \
                --argjson date "${DATE_VAL}" \
                --arg image_path "${LOCAL_FILE}" \
                '{chat_id: ($chat_id | tonumber), from: $from, text: $caption, image_path: $image_path, date: $date, type: "photo"}'
        fi
    done < <(echo "${MESSAGES}" | jq -c '.[] | select(.message.photo) | {
        chat_id: .message.chat.id,
        from: .message.from.first_name,
        caption: (.message.caption // ""),
        date: .message.date,
        file_id: (.message.photo | last | .file_id)
    }')

    # Handle document messages: download and output with local path
    while IFS= read -r doc_msg; do
        CHAT_ID_VAL=$(echo "${doc_msg}" | jq -r '.chat_id')
        FROM_VAL=$(echo "${doc_msg}" | jq -r '.from')
        DATE_VAL=$(echo "${doc_msg}" | jq -r '.date')
        CAPTION_VAL=$(echo "${doc_msg}" | jq -r '.caption // ""')
        FILE_ID=$(echo "${doc_msg}" | jq -r '.file_id')
        FILE_NAME=$(echo "${doc_msg}" | jq -r '.file_name')

        FILE_RESPONSE=$(telegram_api_get "getFile?file_id=${FILE_ID}" 2>/dev/null || echo '{"ok":false}')
        FILE_PATH=$(echo "${FILE_RESPONSE}" | jq -r '.result.file_path // empty')

        if [[ -n "${FILE_PATH}" ]]; then
            LOCAL_FILE="${IMAGE_DIR}/${FILE_NAME}"
            telegram_file_download "${FILE_PATH}" "${LOCAL_FILE}" 2>/dev/null || true

            jq -nc \
                --arg chat_id "${CHAT_ID_VAL}" \
                --arg from "${FROM_VAL}" \
                --arg caption "${CAPTION_VAL}" \
                --argjson date "${DATE_VAL}" \
                --arg file_path "${LOCAL_FILE}" \
                --arg file_name "${FILE_NAME}" \
                '{chat_id: ($chat_id | tonumber), from: $from, text: $caption, file_path: $file_path, file_name: $file_name, date: $date, type: "document"}'
        fi
    done < <(echo "${MESSAGES}" | jq -c '.[] | select(.message.document) | {
        chat_id: .message.chat.id,
        from: .message.from.first_name,
        caption: (.message.caption // ""),
        date: .message.date,
        file_id: .message.document.file_id,
        file_name: .message.document.file_name
    }')

    # Handle audio messages: download and output with local path
    while IFS= read -r audio_msg; do
        CHAT_ID_VAL=$(echo "${audio_msg}" | jq -r '.chat_id')
        FROM_VAL=$(echo "${audio_msg}" | jq -r '.from')
        DATE_VAL=$(echo "${audio_msg}" | jq -r '.date')
        FILE_ID=$(echo "${audio_msg}" | jq -r '.file_id')
        FILE_NAME=$(echo "${audio_msg}" | jq -r '.file_name')

        FILE_RESPONSE=$(telegram_api_get "getFile?file_id=${FILE_ID}" 2>/dev/null || echo '{"ok":false}')
        FILE_PATH=$(echo "${FILE_RESPONSE}" | jq -r '.result.file_path // empty')

        if [[ -n "${FILE_PATH}" ]]; then
            LOCAL_FILE="${IMAGE_DIR}/${FILE_NAME}"
            telegram_file_download "${FILE_PATH}" "${LOCAL_FILE}" 2>/dev/null || true

            jq -nc \
                --arg chat_id "${CHAT_ID_VAL}" \
                --arg from "${FROM_VAL}" \
                --argjson date "${DATE_VAL}" \
                --arg file_path "${LOCAL_FILE}" \
                --arg file_name "${FILE_NAME}" \
                '{chat_id: ($chat_id | tonumber), from: $from, text: "", file_path: $file_path, file_name: $file_name, date: $date, type: "audio"}'
        fi
    done < <(echo "${MESSAGES}" | jq -c '.[] | select(.message.audio) | {
        chat_id: .message.chat.id,
        from: .message.from.first_name,
        date: .message.date,
        file_id: .message.audio.file_id,
        file_name: (.message.audio.file_name // ("audio_" + (.message.date | tostring) + ".ogg"))
    }')

    # Handle voice messages: download and output with local path
    while IFS= read -r voice_msg; do
        CHAT_ID_VAL=$(echo "${voice_msg}" | jq -r '.chat_id')
        FROM_VAL=$(echo "${voice_msg}" | jq -r '.from')
        DATE_VAL=$(echo "${voice_msg}" | jq -r '.date')
        FILE_ID=$(echo "${voice_msg}" | jq -r '.file_id')

        FILE_RESPONSE=$(telegram_api_get "getFile?file_id=${FILE_ID}" 2>/dev/null || echo '{"ok":false}')
        FILE_PATH=$(echo "${FILE_RESPONSE}" | jq -r '.result.file_path // empty')

        if [[ -n "${FILE_PATH}" ]]; then
            LOCAL_FILE="${IMAGE_DIR}/voice_${DATE_VAL}.ogg"
            telegram_file_download "${FILE_PATH}" "${LOCAL_FILE}" 2>/dev/null || true

            jq -nc \
                --arg chat_id "${CHAT_ID_VAL}" \
                --arg from "${FROM_VAL}" \
                --argjson date "${DATE_VAL}" \
                --arg file_path "${LOCAL_FILE}" \
                '{chat_id: ($chat_id | tonumber), from: $from, text: "", file_path: $file_path, date: $date, type: "voice"}'
        fi
    done < <(echo "${MESSAGES}" | jq -c '.[] | select(.message.voice) | {
        chat_id: .message.chat.id,
        from: .message.from.first_name,
        date: .message.date,
        file_id: .message.voice.file_id
    }')

    # Handle video_note messages (round video): download and output with local path
    while IFS= read -r vnote_msg; do
        CHAT_ID_VAL=$(echo "${vnote_msg}" | jq -r '.chat_id')
        FROM_VAL=$(echo "${vnote_msg}" | jq -r '.from')
        DATE_VAL=$(echo "${vnote_msg}" | jq -r '.date')
        FILE_ID=$(echo "${vnote_msg}" | jq -r '.file_id')

        FILE_RESPONSE=$(telegram_api_get "getFile?file_id=${FILE_ID}" 2>/dev/null || echo '{"ok":false}')
        FILE_PATH=$(echo "${FILE_RESPONSE}" | jq -r '.result.file_path // empty')

        if [[ -n "${FILE_PATH}" ]]; then
            LOCAL_FILE="${IMAGE_DIR}/videonote_${DATE_VAL}.mp4"
            telegram_file_download "${FILE_PATH}" "${LOCAL_FILE}" 2>/dev/null || true

            jq -nc \
                --arg chat_id "${CHAT_ID_VAL}" \
                --arg from "${FROM_VAL}" \
                --argjson date "${DATE_VAL}" \
                --arg file_path "${LOCAL_FILE}" \
                '{chat_id: ($chat_id | tonumber), from: $from, text: "", file_path: $file_path, date: $date, type: "video_note"}'
        fi
    done < <(echo "${MESSAGES}" | jq -c '.[] | select(.message.video_note) | {
        chat_id: .message.chat.id,
        from: .message.from.first_name,
        date: .message.date,
        file_id: .message.video_note.file_id
    }')

    # Output callback queries (inline button presses)
    echo "${MESSAGES}" | jq -c '.[] | select(.callback_query) | {
        chat_id: .callback_query.message.chat.id,
        from: .callback_query.from.first_name,
        callback_data: .callback_query.data,
        callback_query_id: .callback_query.id,
        message_id: .callback_query.message.message_id,
        date: .callback_query.message.date,
        type: "callback"
    }'
fi

# Update offset AFTER all messages have been output
# This prevents silent message loss if the script crashes mid-output
NEW_OFFSET=$(echo "${RESPONSE}" | jq '.result[-1].update_id + 1 // empty')
if [[ -n "${NEW_OFFSET}" ]]; then
    echo "${NEW_OFFSET}" > "${OFFSET_FILE}"
fi
