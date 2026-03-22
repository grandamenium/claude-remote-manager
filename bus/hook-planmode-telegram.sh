#!/usr/bin/env bash
# hook-planmode-telegram.sh - ExitPlanMode PermissionRequest hook
# Reads the plan file, sends it to Telegram with Approve/Deny buttons.
# Approve = allow (agent executes the plan)
# Deny = deny (agent asks what to change via Telegram)
# Timeout: 1800s (30 min), auto-approves so agents aren't blocked if user is away.

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
    echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
    exit 0
fi

# Find the plan file
PLAN_PATH=$(echo "$INPUT" | jq -r '.tool_input.plan_file // empty' 2>/dev/null)
if [[ -z "$PLAN_PATH" ]]; then
    PLAN_PATH=$(ls -t ~/.claude/plans/*.md 2>/dev/null | head -1)
fi

# Read plan content
PLAN_CONTENT=""
if [[ -n "$PLAN_PATH" ]] && [[ -f "$PLAN_PATH" ]]; then
    PLAN_CONTENT=$(head -100 "$PLAN_PATH" 2>/dev/null)
fi

if [[ -z "$PLAN_CONTENT" ]]; then
    PLAN_CONTENT="(Plan file not found or empty)"
fi

# Generate unique ID
UNIQUE_ID="${$}_$(date +%s)_${RANDOM}"
RESPONSE_FILE="/tmp/bos-hook-response-${AGENT}-${UNIQUE_ID}.json"

cleanup() {
    rm -f "$RESPONSE_FILE"
}
trap cleanup EXIT

# Telegram has 4096 char limit
if [[ ${#PLAN_CONTENT} -gt 3600 ]]; then
    PLAN_CONTENT="${PLAN_CONTENT:0:3600}...(truncated)"
fi

MSG_TEXT="PLAN REVIEW - ${AGENT}

${PLAN_CONTENT}"

KEYBOARD=$(jq -n -c \
    --arg approve "perm_allow_${UNIQUE_ID}" \
    --arg deny "perm_deny_${UNIQUE_ID}" \
    '{inline_keyboard: [[
        {text: "Approve Plan", callback_data: $approve},
        {text: "Deny Plan", callback_data: $deny}
    ]]}')

curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "$(jq -n -c \
        --arg chat_id "$CHAT_ID" \
        --arg text "$MSG_TEXT" \
        --argjson reply_markup "$KEYBOARD" \
        '{chat_id: $chat_id, text: $text, reply_markup: $reply_markup}')" > /dev/null 2>&1 || {
    echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
    exit 0
}

# Poll for response
ELAPSED=0
while [[ $ELAPSED -lt 1800 ]]; do
    if [[ -f "$RESPONSE_FILE" ]]; then
        DECISION=$(jq -r '.decision // "deny"' "$RESPONSE_FILE" 2>/dev/null || echo "deny")

        if [[ "$DECISION" == "allow" ]]; then
            echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
        else
            echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Plan denied by user via Telegram. Ask what they want to change."}}}'
        fi
        exit 0
    fi

    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

# Timeout - auto-approve so agents aren't blocked
bash "${TEMPLATE_ROOT}/bus/send-telegram.sh" "${CHAT_ID}" "Plan review TIMED OUT (auto-approved): ${AGENT}" > /dev/null 2>&1 || true

echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
