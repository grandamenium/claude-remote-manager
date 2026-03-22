#!/usr/bin/env bash
# fast-checker.sh - High-frequency Telegram + inbox poller
# Injects messages into the live Claude Code tmux session via send-keys
# Usage: fast-checker.sh <agent> <tmux_session> <agent_dir> <template_root>
# Lifecycle: started by agent-wrapper.sh after tmux session is created;
#            killed by agent-wrapper.sh when tmux session dies

set -uo pipefail

AGENT="$1"
TMUX_SESSION="$2"
AGENT_DIR="$3"
TEMPLATE_ROOT="$4"
# Load instance ID
REPO_ENV="${TEMPLATE_ROOT}/.env"
if [[ -f "${REPO_ENV}" ]]; then
    BOS_INSTANCE_ID=$(grep '^BOS_INSTANCE_ID=' "${REPO_ENV}" | cut -d= -f2)
fi
BOS_INSTANCE_ID="${BOS_INSTANCE_ID:-default}"
BOS_ROOT="${HOME}/.business-os/${BOS_INSTANCE_ID}"
BUS_DIR="${TEMPLATE_ROOT}/bus"
LOG_FILE="${BOS_ROOT}/logs/${AGENT}/fast-checker.log"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [fast-checker/${AGENT}] $1" >> "$LOG_FILE"
}

log "Starting. Waiting for agent to finish bootstrapping..."

# Wait for agent bootstrap to complete (heartbeat transitions from "booting" to online)
MAX_WAIT=120
WAITED=0
while [[ $WAITED -lt $MAX_WAIT ]]; do
    STATUS=$(jq -r '.status // "booting"' "${BOS_ROOT}/state/heartbeat/${AGENT}.json" 2>/dev/null || echo "booting")
    if [[ "$STATUS" != "booting" ]]; then
        break
    fi
    sleep 5
    WAITED=$((WAITED + 5))
done

log "Agent ready (waited ${WAITED}s). Beginning poll loop."

# Inject a block of messages into the Claude Code session.
inject_messages() {
    local content="$1"
    local tmpfile
    tmpfile=$(mktemp /tmp/bos-msg-XXXXXX.txt 2>/dev/null) || {
        log "mktemp failed - skipping injection to avoid bare Enter"
        return 1
    }
    printf '%s' "$content" > "$tmpfile"
    local byte_count
    byte_count=$(wc -c < "$tmpfile" | tr -d ' ')

    # load-buffer reads the file into tmux's paste buffer (handles raw bytes).
    # paste-buffer uses bracketed paste mode to inject the content directly
    # into Claude's input field inline. Enter submits.
    tmux load-buffer -b "bos-${AGENT}" "$tmpfile"
    tmux paste-buffer -t "${TMUX_SESSION}:0.0" -b "bos-${AGENT}"
    sleep 0.3  # Let paste content land in PTY buffer before sending Enter
    tmux send-keys -t "${TMUX_SESSION}:0.0" Enter
    rm -f "$tmpfile"

    log "Injected ${byte_count} bytes inline via paste-buffer"
}

# Main poll loop
cd "$AGENT_DIR"

while true; do
    # Exit if tmux session is gone
    if ! tmux has-session -t "${TMUX_SESSION}" 2>/dev/null; then
        log "Tmux session gone. Exiting."
        exit 0
    fi

    MESSAGE_BLOCK=""

    # --- Telegram ---
    TG_OUTPUT=$(bash "${BUS_DIR}/check-telegram.sh" 2>/dev/null || echo "")
    if [[ -n "$TG_OUTPUT" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            TYPE=$(echo "$line" | jq -r '.type // "message"' 2>/dev/null || echo "message")
            FROM=$(echo "$line" | jq -r '.from // "unknown"' 2>/dev/null || echo "unknown")
            TEXT=$(echo "$line" | jq -r '.text // ""' 2>/dev/null || echo "")
            CHAT_ID=$(echo "$line" | jq -r '.chat_id // ""' 2>/dev/null || echo "")

            if [[ "$TYPE" == "callback" ]]; then
                DATA=$(echo "$line" | jq -r '.callback_data // ""' 2>/dev/null || echo "")
                MSG_ID=$(echo "$line" | jq -r '.message_id // ""' 2>/dev/null || echo "")
                CALLBACK_QID=$(echo "$line" | jq -r '.callback_query_id // ""' 2>/dev/null || echo "")

                # Permission hook callbacks: write response file instead of injecting into tmux
                if [[ "$DATA" =~ ^perm_(allow|deny|continue)_(.+)$ ]]; then
                    PERM_DECISION="${BASH_REMATCH[1]}"
                    PERM_ID="${BASH_REMATCH[2]}"
                    RESPONSE_FILE="/tmp/bos-hook-response-${AGENT}-${PERM_ID}.json"

                    HOOK_DECISION="$PERM_DECISION"
                    if [[ "$PERM_DECISION" == "continue" ]]; then
                        HOOK_DECISION="deny"
                    fi

                    printf '{"decision":"%s"}\n' "$HOOK_DECISION" > "$RESPONSE_FILE"

                    bash "${BUS_DIR}/answer-callback.sh" "$CALLBACK_QID" "Got it" 2>/dev/null || true
                    DECISION_LABEL="$(echo "$PERM_DECISION" | sed 's/allow/Approved/;s/deny/Denied/;s/continue/Continue in Chat/')"
                    bash "${BUS_DIR}/edit-message.sh" "$CHAT_ID" "$MSG_ID" "${DECISION_LABEL}" 2>/dev/null || true

                    log "Permission callback: ${PERM_DECISION} for ${PERM_ID}"
                    continue
                fi

                MESSAGE_BLOCK+="=== TELEGRAM CALLBACK from ${FROM} (chat_id:${CHAT_ID}) ===
callback_data: ${DATA}
message_id: ${MSG_ID}
Reply using: bash ../../bus/send-telegram.sh ${CHAT_ID} \"<your reply>\"

"
            elif [[ "$TYPE" == "photo" ]]; then
                IMAGE_PATH=$(echo "$line" | jq -r '.image_path // ""' 2>/dev/null || echo "")
                MESSAGE_BLOCK+="=== TELEGRAM PHOTO from ${FROM} (chat_id:${CHAT_ID}) ===
caption: ${TEXT}
local_file: ${IMAGE_PATH}
Reply using: bash ../../bus/send-telegram.sh ${CHAT_ID} \"<your reply>\"

"
            else
                MESSAGE_BLOCK+="=== TELEGRAM from ${FROM} (chat_id:${CHAT_ID}) ===
${TEXT}
Reply using: bash ../../bus/send-telegram.sh ${CHAT_ID} \"<your reply>\"

"
            fi
        done <<< "$TG_OUTPUT"
    fi

    # --- Agent Inbox ---
    INBOX_OUTPUT=$(bash "${BUS_DIR}/check-inbox.sh" 2>/dev/null || echo "[]")
    MSG_COUNT=$(echo "$INBOX_OUTPUT" | jq 'length' 2>/dev/null || echo "0")
    INBOX_MSG_IDS=()
    if [[ "$MSG_COUNT" -gt 0 ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            FROM=$(echo "$line" | jq -r '.from // "unknown"' 2>/dev/null || echo "unknown")
            TEXT=$(echo "$line" | jq -r '.text // ""' 2>/dev/null || echo "")
            MSG_ID=$(echo "$line" | jq -r '.id // ""' 2>/dev/null || echo "")
            REPLY_TO=$(echo "$line" | jq -r '.reply_to // ""' 2>/dev/null || echo "")

            INBOX_MSG_IDS+=("$MSG_ID")

            REPLY_NOTE=""
            [[ -n "$REPLY_TO" ]] && REPLY_NOTE=" [reply_to: ${REPLY_TO}]"

            MESSAGE_BLOCK+="=== AGENT MESSAGE from ${FROM}${REPLY_NOTE} [msg_id: ${MSG_ID}] ===
${TEXT}
Reply using: bash ../../bus/send-message.sh ${FROM} normal '<your reply>' ${MSG_ID}

"
        done < <(echo "$INBOX_OUTPUT" | jq -c '.[]' 2>/dev/null)
    fi

    # --- Inject if anything found ---
    if [[ -n "$MESSAGE_BLOCK" ]]; then
        if inject_messages "$MESSAGE_BLOCK"; then
            for ack_id in "${INBOX_MSG_IDS[@]}"; do
                bash "${BUS_DIR}/ack-inbox.sh" "$ack_id" 2>/dev/null || true
            done
            # Cooldown after injection
            sleep 5
        fi
    fi

    sleep 1
done
