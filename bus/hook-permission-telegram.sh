#!/usr/bin/env bash
# hook-permission-telegram.sh - Blocking PermissionRequest hook
# Forwards permission prompts to Telegram with Approve/Deny inline buttons.
# Polls for a response file written by fast-checker when the user taps a button.
# Timeout: 1800s (30 min, deny by default). Settings.json timeout should be 1860s.

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
    echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"No Telegram credentials configured for remote approval"}}}'
    exit 0
fi

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"' 2>/dev/null || echo "unknown")

# ExitPlanMode is handled by hook-planmode-telegram.sh - skip here
if [[ "$TOOL_NAME" == "ExitPlanMode" || "$TOOL_NAME" == "AskUserQuestion" ]]; then
    exit 0
fi

# Build a human-readable summary
case "$TOOL_NAME" in
    Edit)
        FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // "unknown"' 2>/dev/null)
        OLD_STR=$(echo "$INPUT" | jq -r '.tool_input.old_string // ""' 2>/dev/null | head -c 300)
        NEW_STR=$(echo "$INPUT" | jq -r '.tool_input.new_string // ""' 2>/dev/null | head -c 300)
        TOOL_SUMMARY="File: ${FILE_PATH}

- ${OLD_STR}
+ ${NEW_STR}"
        ;;
    Write)
        FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // "unknown"' 2>/dev/null)
        CONTENT_PREVIEW=$(echo "$INPUT" | jq -r '.tool_input.content // ""' 2>/dev/null | head -c 300)
        TOOL_SUMMARY="File: ${FILE_PATH}

${CONTENT_PREVIEW}"
        ;;
    Bash)
        CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null | head -c 200)
        TOOL_SUMMARY="Command: ${CMD}"
        ;;
    *)
        TOOL_SUMMARY=$(echo "$INPUT" | jq -r '.tool_input // {}' 2>/dev/null | jq -c '.' 2>/dev/null | head -c 200)
        ;;
esac

# Generate unique ID for this request
UNIQUE_ID="${$}_$(date +%s)_${RANDOM}"
RESPONSE_FILE="/tmp/bos-hook-response-${AGENT}-${UNIQUE_ID}.json"

cleanup() {
    rm -f "$RESPONSE_FILE"
}
trap cleanup EXIT

# Escape markdown special chars for Telegram
escape_md() {
    echo "$1" | sed 's/[_*`\[]/\\&/g'
}

MESSAGE="PERMISSION REQUEST
Agent: $(escape_md "${AGENT}")
Tool: $(escape_md "${TOOL_NAME}")

$(escape_md "${TOOL_SUMMARY}")"

# Truncate if over Telegram's 4096 char limit
if [[ ${#MESSAGE} -gt 3800 ]]; then
    MESSAGE="${MESSAGE:0:3800}...(truncated)"
fi

KEYBOARD=$(jq -n -c \
    --arg allow "perm_allow_${UNIQUE_ID}" \
    --arg deny "perm_deny_${UNIQUE_ID}" \
    '{inline_keyboard: [[
        {text: "Approve", callback_data: $allow},
        {text: "Deny", callback_data: $deny}
    ]]}')

bash "${TEMPLATE_ROOT}/bus/send-telegram.sh" "${CHAT_ID}" "${MESSAGE}" "${KEYBOARD}" > /dev/null 2>&1 || {
    echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Failed to send permission request to Telegram"}}}'
    exit 0
}

# Poll for response file
ELAPSED=0
TIMEOUT=1800
POLL_INTERVAL=2

while [[ $ELAPSED -lt $TIMEOUT ]]; do
    if [[ -f "$RESPONSE_FILE" ]]; then
        DECISION=$(jq -r '.decision // "deny"' "$RESPONSE_FILE" 2>/dev/null || echo "deny")

        if [[ "$DECISION" == "allow" ]]; then
            echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
        else
            echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied by user via Telegram"}}}'
        fi
        exit 0
    fi

    sleep $POLL_INTERVAL
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

# Timeout - deny and notify
bash "${TEMPLATE_ROOT}/bus/send-telegram.sh" "${CHAT_ID}" "Permission request TIMED OUT (auto-denied): ${TOOL_NAME}" > /dev/null 2>&1 || true

echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Timed out waiting for Telegram approval (30m)"}}}'
