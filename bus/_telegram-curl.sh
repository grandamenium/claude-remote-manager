#!/usr/bin/env bash
# _telegram-curl.sh - Shared helper for Telegram API calls
# Keeps BOT_TOKEN out of shell traces (set +x) while preserving stderr for errors.
# Source this file, then call the functions. Requires BOT_TOKEN in environment.
#
# Usage:
#   source "$(dirname "$0")/_telegram-curl.sh"
#   RESPONSE=$(telegram_api_post "sendMessage" -d chat_id=123 --data-urlencode "text=hello")
#   RESPONSE=$(telegram_api_get "getUpdates?offset=0&timeout=5")
#   telegram_file_download "photos/file_123.jpg" /tmp/photo.jpg

# POST to a Telegram Bot API method
# Usage: telegram_api_post <method> [curl_args...]
telegram_api_post() {
    local method="$1"; shift
    (
        set +x  # prevent trace from leaking token in URL
        curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/${method}" "$@"
    )
}

# GET from a Telegram Bot API endpoint
# Usage: telegram_api_get <path_after_bot_token> [curl_args...]
telegram_api_get() {
    local path="$1"; shift
    (
        set +x
        curl -s "https://api.telegram.org/bot${BOT_TOKEN}/${path}" "$@"
    )
}

# Download a file from Telegram's file storage
# Usage: telegram_file_download <file_path> <output_path>
telegram_file_download() {
    local file_path="$1"
    local output="$2"
    (
        set +x
        curl -s "https://api.telegram.org/file/bot${BOT_TOKEN}/${file_path}" -o "${output}"
    )
}
