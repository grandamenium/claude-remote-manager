#!/usr/bin/env bash
# hook-ask-telegram.sh - PreToolUse hook for AskUserQuestion
# Captures the question Claude is asking and sends it to Telegram
# Non-blocking: exits 0 immediately, fast-checker handles the response injection

set -uo pipefail

# Read stdin FIRST before anything that might consume it
INPUT=$(cat)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENT="${BOS_AGENT_NAME:-$(basename "$(pwd)")}"

# Source .env for BOT_TOKEN and CHAT_ID
ENV_FILE="${TEMPLATE_ROOT}/agents/${AGENT}/.env"
{ set +x; } 2>/dev/null
if [[ -f "$ENV_FILE" ]]; then
    set -a; source "$ENV_FILE"; set +a
elif [[ -f ".env" ]]; then
    set -a; source ".env"; set +a
fi

if [[ -z "${BOT_TOKEN:-}" ]] || [[ -z "${CHAT_ID:-}" ]]; then
    exit 0
fi

# Parse the AskUserQuestion structure
QUESTION=$(echo "$INPUT" | jq -r '
    .tool_input.questions[0].question //
    .tool_input.question //
    .tool_input.text //
    "Claude is asking you a question"
' 2>/dev/null || echo "Claude is asking you a question")

HEADER=$(echo "$INPUT" | jq -r '.tool_input.questions[0].header // empty' 2>/dev/null || echo "")

OPTIONS_JSON=$(echo "$INPUT" | jq -c '
    .tool_input.questions[0].options //
    .tool_input.options //
    empty
' 2>/dev/null || echo "")

if [[ -n "$OPTIONS_JSON" ]] && [[ "$OPTIONS_JSON" != "null" ]] && [[ "$OPTIONS_JSON" != "[]" ]]; then
    OPTION_COUNT=$(echo "$OPTIONS_JSON" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$OPTION_COUNT" -gt 0 ]]; then
        MSG="${AGENT} Question:"
        [[ -n "$HEADER" ]] && MSG+="
${HEADER}"
        MSG+="
${QUESTION}
"
        for i in $(seq 0 $((OPTION_COUNT - 1))); do
            LABEL=$(echo "$OPTIONS_JSON" | jq -r ".[$i].label // .[$i] // \"Option $((i+1))\"" 2>/dev/null)
            DESC=$(echo "$OPTIONS_JSON" | jq -r ".[$i].description // empty" 2>/dev/null || echo "")
            MSG+="
$((i+1)). ${LABEL}"
            [[ -n "$DESC" ]] && MSG+="
   ${DESC}"
        done

        KEYBOARD='{"inline_keyboard":['
        FIRST=true
        for i in $(seq 0 $((OPTION_COUNT - 1))); do
            LABEL=$(echo "$OPTIONS_JSON" | jq -r ".[$i].label // .[$i] // \"Option $((i+1))\"" 2>/dev/null)
            CB_DATA=$(echo "$LABEL" | head -c 60)

            [[ "$FIRST" == "true" ]] && FIRST=false || KEYBOARD+=','
            KEYBOARD+="[{\"text\":$(echo "$LABEL" | jq -Rs .),\"callback_data\":$(echo "$CB_DATA" | jq -Rs .)}]"
        done
        KEYBOARD+=']}'

        source "${TEMPLATE_ROOT}/bus/_telegram-curl.sh"
        telegram_api_post "sendMessage" \
            -H "Content-Type: application/json" \
            -d "$(jq -n -c \
                --arg chat_id "$CHAT_ID" \
                --arg text "$MSG" \
                --argjson reply_markup "$KEYBOARD" \
                '{chat_id: $chat_id, text: $text, reply_markup: $reply_markup}')" > /dev/null 2>&1 || true
    fi
else
    MSG="${AGENT} Question:
${QUESTION}

Reply with your answer on Telegram."

    source "${TEMPLATE_ROOT}/bus/_telegram-curl.sh"
    telegram_api_post "sendMessage" \
        -H "Content-Type: application/json" \
        -d "$(jq -n -c \
            --arg chat_id "$CHAT_ID" \
            --arg text "$MSG" \
            '{chat_id: $chat_id, text: $text}')" > /dev/null 2>&1 || true
fi

exit 0
