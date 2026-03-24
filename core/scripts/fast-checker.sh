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
    CRM_INSTANCE_ID=$(grep '^CRM_INSTANCE_ID=' "${REPO_ENV}" | cut -d= -f2)
fi
CRM_INSTANCE_ID="${CRM_INSTANCE_ID:-default}"
CRM_ROOT="${HOME}/.claude-remote/${CRM_INSTANCE_ID}"
BUS_DIR="${TEMPLATE_ROOT}/core/bus"
LOG_FILE="${CRM_ROOT}/logs/${AGENT}/fast-checker.log"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [fast-checker/${AGENT}] $1" >> "$LOG_FILE"
}

log "Starting. Waiting for agent to finish bootstrapping..."

# Wait for Claude Code to be ready before injecting messages.
# Detects readiness by checking for the "permissions" status bar text
# in the tmux pane, which only appears once Claude Code's UI is fully
# initialized. Falls back to 30s fixed wait if the text is never found
# (e.g., if Claude Code changes its UI in a future version).
BOOT_TIMEOUT=30
BOOT_ELAPSED=0
while [[ ${BOOT_ELAPSED} -lt ${BOOT_TIMEOUT} ]]; do
    if tmux capture-pane -t "${TMUX_SESSION}:0.0" -p 2>/dev/null | grep -q "permissions"; then
        break
    fi
    sleep 2
    BOOT_ELAPSED=$((BOOT_ELAPSED + 2))
done

log "Bootstrap wait complete. Beginning poll loop."

# Inject a block of messages into the Claude Code session.
inject_messages() {
    local content="$1"
    local tmpfile
    tmpfile=$(mktemp "${CRM_ROOT}/logs/${AGENT}/.crm-msg-XXXXXX.txt" 2>/dev/null) || {
        log "mktemp failed - skipping injection to avoid bare Enter"
        return 1
    }
    chmod 600 "$tmpfile"
    printf '%s' "$content" > "$tmpfile"
    local byte_count
    byte_count=$(wc -c < "$tmpfile" | tr -d ' ')

    # load-buffer reads the file into tmux's paste buffer (handles raw bytes).
    # paste-buffer uses bracketed paste mode to inject the content directly
    # into Claude's input field inline. Enter submits.
    tmux load-buffer -b "crm-${AGENT}" "$tmpfile"
    tmux paste-buffer -t "${TMUX_SESSION}:0.0" -b "crm-${AGENT}"
    sleep 0.3  # Let paste content land in PTY buffer before sending Enter
    tmux send-keys -t "${TMUX_SESSION}:0.0" Enter
    rm -f "$tmpfile"

    log "Injected ${byte_count} bytes inline via paste-buffer"
}

# Main poll loop
cd "$AGENT_DIR"

# Source Telegram helpers and agent .env for sending questions directly
source "${BUS_DIR}/_telegram-curl.sh"
ENV_FILE="${TEMPLATE_ROOT}/agents/${AGENT}/.env"
{ set +x; } 2>/dev/null
if [[ -f "$ENV_FILE" ]]; then
    set -a; source "$ENV_FILE"; set +a
elif [[ -f ".env" ]]; then
    set -a; source ".env"; set +a
fi

# Send a question from the ask state file to Telegram (inlined to avoid env issues)
send_next_question() {
    local q_idx="$1"
    local state_file="/tmp/crm-ask-state-${AGENT}.json"

    if [[ ! -f "$state_file" ]]; then
        log "send_next_question: state file not found"
        return 1
    fi

    local total_q q_text q_header q_multi q_options q_opt_count msg keyboard
    total_q=$(jq -r '.total_questions // 1' "$state_file")
    q_text=$(jq -r ".questions[${q_idx}].question // \"Question\"" "$state_file")
    q_header=$(jq -r ".questions[${q_idx}].header // empty" "$state_file" || echo "")
    q_multi=$(jq -r ".questions[${q_idx}].multiSelect // false" "$state_file")
    q_options=$(jq -c ".questions[${q_idx}].options // []" "$state_file")
    q_opt_count=$(echo "$q_options" | jq 'length')

    msg="QUESTION ($((q_idx+1))/${total_q}) - ${AGENT}:"
    [[ -n "$q_header" ]] && msg+=$'\n'"${q_header}"
    msg+=$'\n'"${q_text}"$'\n'

    if [[ "$q_multi" == "true" ]]; then
        msg+=$'\n'"(Multi-select: tap options to toggle, then tap Submit)"
    fi

    for i in $(seq 0 $((q_opt_count - 1))); do
        local label
        label=$(echo "$q_options" | jq -r ".[$i] // \"Option $((i+1))\"")
        msg+=$'\n'"$((i+1)). ${label}"
    done

    if [[ "$q_multi" == "true" ]]; then
        keyboard=$(echo "$q_options" | jq -c '[to_entries[] | [{
            text: (.value // "Option \(.key + 1)"),
            callback_data: "asktoggle_'"$q_idx"'_\(.key)"
        }]] + [[{text: "Submit Selections", callback_data: "asksubmit_'"$q_idx"'"}]]')
    else
        keyboard=$(echo "$q_options" | jq -c '[to_entries[] | [{
            text: (.value // "Option \(.key + 1)"),
            callback_data: "askopt_'"$q_idx"'_\(.key)"
        }]]')
    fi
    keyboard="{\"inline_keyboard\":${keyboard}}"

    telegram_api_post "sendMessage" \
        -H "Content-Type: application/json" \
        -d "$(jq -n -c \
            --arg chat_id "$CHAT_ID" \
            --arg text "$msg" \
            --argjson reply_markup "$keyboard" \
            '{chat_id: $chat_id, text: $text, reply_markup: $reply_markup}')" > /dev/null 2>&1

    log "Sent question $((q_idx+1))/${total_q} to Telegram"
}

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

            # Sanitize FROM to prevent header injection
            if [[ ! "${FROM}" =~ ^[a-zA-Z0-9_\ -]+$ ]]; then
                FROM="unknown"
            fi

            if [[ "$TYPE" == "callback" ]]; then
                DATA=$(echo "$line" | jq -r '.callback_data // ""' 2>/dev/null || echo "")
                MSG_ID=$(echo "$line" | jq -r '.message_id // ""' 2>/dev/null || echo "")
                CALLBACK_QID=$(echo "$line" | jq -r '.callback_query_id // ""' 2>/dev/null || echo "")

                # Permission hook callbacks: write response file instead of injecting into tmux
                if [[ "$DATA" =~ ^perm_(allow|deny|continue)_([a-f0-9]+)$ ]]; then
                    PERM_DECISION="${BASH_REMATCH[1]}"
                    PERM_ID="${BASH_REMATCH[2]}"
                    RESPONSE_FILE="/tmp/crm-hook-response-${AGENT}-${PERM_ID}.json"

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

                # === AskUserQuestion handlers ===
                ASK_STATE="/tmp/crm-ask-state-${AGENT}.json"
                log "DEBUG callback_data='${DATA}' hex=$(printf '%s' "$DATA" | xxd -p | head -c 60)"

                # Single-select: askopt_{questionIdx}_{optionIdx}
                if [[ "$DATA" =~ ^askopt_([0-9]+)_([0-9]+)$ ]]; then
                    Q_IDX="${BASH_REMATCH[1]}"
                    O_IDX="${BASH_REMATCH[2]}"

                    bash "${BUS_DIR}/answer-callback.sh" "$CALLBACK_QID" "Got it" 2>/dev/null || true
                    bash "${BUS_DIR}/edit-message.sh" "$CHAT_ID" "$MSG_ID" "Answered" 2>/dev/null || true

                    # Navigate TUI: Down * O_IDX, then Enter to select + advance
                    for ((k=0; k<O_IDX; k++)); do
                        tmux send-keys -t "${TMUX_SESSION}:0.0" Down
                        sleep 0.1
                    done
                    sleep 0.2
                    tmux send-keys -t "${TMUX_SESSION}:0.0" Enter

                    log "AskUserQuestion: Q${Q_IDX} selected option ${O_IDX}"

                    # Check if there are more questions to send
                    if [[ -f "$ASK_STATE" ]]; then
                        TOTAL_Q=$(jq -r '.total_questions // 1' "$ASK_STATE" 2>/dev/null)
                        NEXT_Q=$((Q_IDX + 1))
                        if [[ $NEXT_Q -lt $TOTAL_Q ]]; then
                            # Update state
                            jq --argjson nq "$NEXT_Q" '.current_question = $nq' "$ASK_STATE" > "${ASK_STATE}.tmp" && mv "${ASK_STATE}.tmp" "$ASK_STATE"
                            # Send next question via Telegram after short delay for TUI to advance
                            sleep 0.5
                            send_next_question "$NEXT_Q"
                        else
                            # Last question answered - hit Enter on the Submit button
                            sleep 0.5
                            tmux send-keys -t "${TMUX_SESSION}:0.0" Enter
                            log "AskUserQuestion: submitted all answers"
                            rm -f "$ASK_STATE"
                        fi
                    fi
                    continue
                fi

                # Multi-select toggle: asktoggle_{questionIdx}_{optionIdx}
                if [[ "$DATA" =~ ^asktoggle_([0-9]+)_([0-9]+)$ ]]; then
                    Q_IDX="${BASH_REMATCH[1]}"
                    O_IDX="${BASH_REMATCH[2]}"

                    bash "${BUS_DIR}/answer-callback.sh" "$CALLBACK_QID" "Toggled" 2>/dev/null || true

                    # Track toggled selections in state file
                    if [[ -f "$ASK_STATE" ]]; then
                        # Toggle: add if not present, remove if present
                        CURRENT=$(jq -r ".multi_select_chosen | index($O_IDX)" "$ASK_STATE" 2>/dev/null)
                        if [[ "$CURRENT" == "null" ]]; then
                            jq --argjson idx "$O_IDX" '.multi_select_chosen += [$idx]' "$ASK_STATE" > "${ASK_STATE}.tmp" && mv "${ASK_STATE}.tmp" "$ASK_STATE"
                        else
                            jq --argjson idx "$O_IDX" '.multi_select_chosen -= [$idx]' "$ASK_STATE" > "${ASK_STATE}.tmp" && mv "${ASK_STATE}.tmp" "$ASK_STATE"
                        fi

                        # Update the Telegram message to show current selections
                        CHOSEN=$(jq -r '.multi_select_chosen | sort | map(. + 1) | map(tostring) | join(", ")' "$ASK_STATE" 2>/dev/null)
                        if [[ -n "$CHOSEN" && "$CHOSEN" != "" ]]; then
                            bash "${BUS_DIR}/edit-message.sh" "$CHAT_ID" "$MSG_ID" "Selected: ${CHOSEN}
Tap more options or Submit" '{"inline_keyboard":'"$(jq -c '.questions['"$Q_IDX"'].options | [to_entries[] | [{text: (.value // "Option \(.key+1)"), callback_data: "asktoggle_'"$Q_IDX"'_\(.key)"}]] + [[{text: "Submit Selections", callback_data: "asksubmit_'"$Q_IDX"'"}]]' "$ASK_STATE" 2>/dev/null)"'}' 2>/dev/null || true
                        fi
                    fi

                    log "AskUserQuestion: Q${Q_IDX} toggled option ${O_IDX}"
                    continue
                fi

                # Multi-select submit: asksubmit_{questionIdx}
                if [[ "$DATA" =~ ^asksubmit_([0-9]+)$ ]]; then
                    Q_IDX="${BASH_REMATCH[1]}"

                    bash "${BUS_DIR}/answer-callback.sh" "$CALLBACK_QID" "Submitted" 2>/dev/null || true
                    bash "${BUS_DIR}/edit-message.sh" "$CHAT_ID" "$MSG_ID" "Submitted" 2>/dev/null || true

                    if [[ -f "$ASK_STATE" ]]; then
                        # Get chosen indices and navigate TUI
                        CHOSEN_INDICES=$(jq -r '.multi_select_chosen | sort | .[]' "$ASK_STATE" 2>/dev/null)

                        # For multi-select TUI: navigate to each chosen option and press Space
                        TOTAL_OPTS=$(jq -r ".questions[${Q_IDX}].options | length" "$ASK_STATE" 2>/dev/null || echo "4")
                        CURRENT_POS=0
                        for idx in $CHOSEN_INDICES; do
                            MOVES=$((idx - CURRENT_POS))
                            for ((k=0; k<MOVES; k++)); do
                                tmux send-keys -t "${TMUX_SESSION}:0.0" Down
                                sleep 0.1
                            done
                            tmux send-keys -t "${TMUX_SESSION}:0.0" Space
                            sleep 0.1
                            CURRENT_POS=$idx
                        done
                        # Navigate past all options (including "Other") to the Submit button
                        # Options count + 1 for "Other" auto-added by Claude Code
                        SUBMIT_POS=$((TOTAL_OPTS + 1))
                        REMAINING=$((SUBMIT_POS - CURRENT_POS))
                        for ((k=0; k<REMAINING; k++)); do
                            tmux send-keys -t "${TMUX_SESSION}:0.0" Down
                            sleep 0.1
                        done
                        sleep 0.2
                        tmux send-keys -t "${TMUX_SESSION}:0.0" Enter

                        log "AskUserQuestion: Q${Q_IDX} submitted multi-select"

                        # Check for more questions
                        TOTAL_Q=$(jq -r '.total_questions // 1' "$ASK_STATE" 2>/dev/null)
                        NEXT_Q=$((Q_IDX + 1))
                        # Reset multi_select_chosen for next question
                        jq '.multi_select_chosen = []' "$ASK_STATE" > "${ASK_STATE}.tmp" && mv "${ASK_STATE}.tmp" "$ASK_STATE"

                        if [[ $NEXT_Q -lt $TOTAL_Q ]]; then
                            jq --argjson nq "$NEXT_Q" '.current_question = $nq' "$ASK_STATE" > "${ASK_STATE}.tmp" && mv "${ASK_STATE}.tmp" "$ASK_STATE"
                            sleep 0.5
                            send_next_question "$NEXT_Q"
                        else
                            # Last question answered - hit Enter on the Submit button
                            sleep 0.5
                            tmux send-keys -t "${TMUX_SESSION}:0.0" Enter
                            log "AskUserQuestion: submitted all answers"
                            rm -f "$ASK_STATE"
                        fi
                    fi
                    continue
                fi

                MESSAGE_BLOCK+="=== TELEGRAM CALLBACK from ${FROM} (chat_id:${CHAT_ID}) ===
callback_data: \`${DATA}\`
message_id: ${MSG_ID}
Reply using: bash ../../core/bus/send-telegram.sh ${CHAT_ID} \"<your reply>\"

"
            elif [[ "$TYPE" == "photo" ]]; then
                IMAGE_PATH=$(echo "$line" | jq -r '.image_path // ""' 2>/dev/null || echo "")
                MESSAGE_BLOCK+="=== TELEGRAM PHOTO from ${FROM} (chat_id:${CHAT_ID}) ===
caption:
\`\`\`
${TEXT}
\`\`\`
local_file: ${IMAGE_PATH}
Reply using: bash ../../core/bus/send-telegram.sh ${CHAT_ID} \"<your reply>\"

"
            else
                # Built-in CLI commands: inject raw so they trigger directly
                if [[ "$TEXT" =~ ^/(compact|clear|help|cost|login|logout|status|doctor|config|bug|init|review|fast|slow)$ ]]; then
                    MESSAGE_BLOCK+="${TEXT}
"
                else
                    MESSAGE_BLOCK+="=== TELEGRAM from ${FROM} (chat_id:${CHAT_ID}) ===
\`\`\`
${TEXT}
\`\`\`
Reply using: bash ../../core/bus/send-telegram.sh ${CHAT_ID} \"<your reply>\"

"
                fi
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

            # Sanitize FROM to prevent header injection
            if [[ ! "${FROM}" =~ ^[a-z0-9_-]+$ ]]; then
                FROM="unknown"
            fi

            INBOX_MSG_IDS+=("$MSG_ID")

            REPLY_NOTE=""
            [[ -n "$REPLY_TO" ]] && REPLY_NOTE=" [reply_to: ${REPLY_TO}]"

            MESSAGE_BLOCK+="=== AGENT MESSAGE from ${FROM}${REPLY_NOTE} [msg_id: ${MSG_ID}] ===
\`\`\`
${TEXT}
\`\`\`
Reply using: bash ../../core/bus/send-message.sh ${FROM} normal '<your reply>' ${MSG_ID}

"
        done < <(echo "$INBOX_OUTPUT" | jq -c '.[]' 2>/dev/null)
    fi

    # --- Inject if anything found ---
    if [[ -n "$MESSAGE_BLOCK" ]]; then
        if inject_messages "$MESSAGE_BLOCK"; then
            for ack_id in "${INBOX_MSG_IDS[@]+"${INBOX_MSG_IDS[@]}"}"; do
                bash "${BUS_DIR}/ack-inbox.sh" "$ack_id" 2>/dev/null || true
            done
            # Cooldown after injection
            sleep 5
        fi
    fi

    sleep 1
done
