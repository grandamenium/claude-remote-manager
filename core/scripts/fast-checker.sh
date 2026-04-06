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

# --- Singleton: prevent duplicate fast-checker processes per agent ---
# Use mkdir as an atomic lock (POSIX-portable, works on macOS without flock).
# The lock dir exists for the lifetime of this process. If another instance
# starts, mkdir fails atomically and it exits. A stale lock from a crashed
# process is detected by checking if the recorded PID is still alive.
LOCKDIR="${CRM_ROOT}/state/${AGENT}.fast-checker.lock"
PIDFILE="${CRM_ROOT}/state/${AGENT}.fast-checker.pid"
mkdir -p "${CRM_ROOT}/state"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    # Lock dir exists — check if holder is still alive
    OLD_PID=$(cat "$PIDFILE" 2>/dev/null || echo "")
    if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
        log "Another fast-checker (pid ${OLD_PID}) already running for ${AGENT}. Exiting."
        exit 0
    fi
    # Stale lock from crashed process — reclaim it
    log "Reclaiming stale lock (old pid ${OLD_PID} is dead)"
    rm -rf "$LOCKDIR"
    mkdir "$LOCKDIR" 2>/dev/null || { log "Lock race lost. Exiting."; exit 0; }
fi
echo $$ > "$PIDFILE"
trap 'rm -rf "$LOCKDIR"; rm -f "$PIDFILE"' EXIT

log "Starting (pid $$). Waiting for agent to finish bootstrapping..."

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

# --- State tracking for context monitoring + responsiveness ---
POLL_COUNT=0
INJECT_COUNT=0
mkdir -p "${CRM_ROOT}/state"
SESSION_START_FILE="${CRM_ROOT}/state/${AGENT}.session-start"
if [[ ! -f "${SESSION_START_FILE}" ]]; then
    date +%s > "${SESSION_START_FILE}"
fi
SESSION_START=$(cat "${SESSION_START_FILE}")

# Configurable thresholds (from config.json or defaults)
CONTEXT_MAX_HOURS=$(jq -r '.context_max_hours // 16' "${AGENT_DIR}/config.json" 2>/dev/null || echo "16")
CONTEXT_MAX_INJECTIONS=$(jq -r '.context_max_injections // 150' "${AGENT_DIR}/config.json" 2>/dev/null || echo "150")
CONTEXT_RESTART_TRIGGERED=false

LAST_AUTO_REPLY=0
AUTO_REPLY_COOLDOWN=60  # seconds between auto-replies

# Typing indicator state (Fix 9)
HUMAN_MSG_PENDING=false
HUMAN_MSG_CHAT_ID=""
TYPING_LAST_SENT=0
HUMAN_MSG_PENDING_SINCE=0  # timestamp when last human msg arrived

FROZEN_SOFT_NUDGE_SECONDS=120   # soft nudge (Ctrl+C + re-prompt) after 2 min
FROZEN_RESTART_MAX_SECONDS=300  # hard-restart if agent busy for 5+ min with pending human msg
FROZEN_NUDGE_SENT=0             # track whether we already sent a soft nudge (0=no, 1=yes)
LAST_PANE_HASH=""               # track pane content changes for progress detection
PANE_STALE_SINCE=0              # when pane content stopped changing

# Live activity streaming state
ACTIVITY_STREAMING=$(jq -r '.activity_streaming // false' "${AGENT_DIR}/config.json" 2>/dev/null || echo "false")
ACTIVITY_INTERVAL=$(jq -r '.activity_interval_seconds // 8' "${AGENT_DIR}/config.json" 2>/dev/null || echo "8")
LAST_ACTIVITY=""
LAST_ACTIVITY_SENT=0

# Telemetry state file (Fix 7)
STATS_FILE="${CRM_ROOT}/state/${AGENT}.stats.json"

# Check if agent is idle by looking at tmux pane.
# NOTE: This relies on Claude Code's TUI showing a bare ">" prompt when idle.
# If Claude Code changes its prompt UI in a future version, this regex may
# need updating. The grep pattern is intentionally loose (allows whitespace).
is_agent_idle() {
    local pane_bottom
    pane_bottom=$(tmux capture-pane -t "${TMUX_SESSION}:0.0" -p 2>/dev/null | grep -v '^$' | tail -3)
    echo "$pane_bottom" | grep -qE '^\s*>\s*$'
}

# Auto-reply on Telegram when agent is busy processing
auto_reply_busy() {
    local chat_id="$1"
    local now
    now=$(date +%s)
    if (( now - LAST_AUTO_REPLY > AUTO_REPLY_COOLDOWN )); then
        telegram_api_post "sendMessage" \
            -H "Content-Type: application/json" \
            -d "$(jq -n -c --arg cid "$chat_id" --arg txt "Got it, processing..." \
                '{chat_id: $cid, text: $txt}')" > /dev/null 2>&1 || true
        LAST_AUTO_REPLY=$now
        log "Auto-replied 'processing' to ${chat_id}"
    fi
}

# Extract current activity from tmux pane for live streaming
extract_activity() {
    local pane_text
    pane_text=$(tmux capture-pane -t "${TMUX_SESSION}:0.0" -p 2>/dev/null | grep -v '^$' | tail -15)
    [[ -z "$pane_text" ]] && return 1

    local activity=""
    # Match tool call patterns in Claude Code output (most specific first)
    if echo "$pane_text" | grep -q "send-telegram.sh"; then
        return 1  # skip — don't echo telegram sends
    elif echo "$pane_text" | grep -qiE "search_gmail|gmail_message"; then
        activity="Checking Gmail..."
    elif echo "$pane_text" | grep -qiE "get_events|list_calendars|manage_event"; then
        activity="Checking calendar..."
    elif echo "$pane_text" | grep -qiE "search_drive|list_drive"; then
        activity="Searching Google Drive..."
    elif echo "$pane_text" | grep -qiE "WebSearch|WebFetch"; then
        activity="Searching the web..."
    elif echo "$pane_text" | grep -qiE "clearpath-intelligence"; then
        activity="Pulling Clearpath intelligence..."
    elif echo "$pane_text" | grep -qE "Agent\b.*prompt"; then
        activity="Dispatching sub-agent..."
    elif echo "$pane_text" | grep -qE "^[[:space:]]*(Grep|Glob)"; then
        activity="Searching codebase..."
    elif echo "$pane_text" | grep -qE "git log|git diff|git status"; then
        activity="Checking git history..."
    elif echo "$pane_text" | grep -qE "^[[:space:]]*Read "; then
        local fname
        fname=$(echo "$pane_text" | grep -oE "Read [^ ]+" | tail -1 | sed 's|Read .*/||')
        activity="Reading ${fname:0:40}..."
    elif echo "$pane_text" | grep -qE "^[[:space:]]*Edit "; then
        local fname
        fname=$(echo "$pane_text" | grep -oE "Edit [^ ]+" | tail -1 | sed 's|Edit .*/||')
        activity="Editing ${fname:0:40}..."
    elif echo "$pane_text" | grep -qE "^[[:space:]]*Write "; then
        local fname
        fname=$(echo "$pane_text" | grep -oE "Write [^ ]+" | tail -1 | sed 's|Write .*/||')
        activity="Writing ${fname:0:40}..."
    elif echo "$pane_text" | grep -qE "^[[:space:]]*Bash"; then
        local desc
        desc=$(echo "$pane_text" | grep -oE "Bash:? .*" | tail -1 | head -c 50)
        activity="Running: ${desc:5:45}..."
    elif echo "$pane_text" | grep -qE "CronCreate|CronList|CronDelete"; then
        activity="Managing scheduled tasks..."
    fi

    [[ -z "$activity" ]] && return 1
    echo "$activity"
}

# Send activity status update to Telegram (silent notification)
send_activity_update() {
    local chat_id="$1"
    local activity="$2"
    local now
    now=$(date +%s)

    # Throttle: skip if same activity or too soon
    if [[ "$activity" == "$LAST_ACTIVITY" ]]; then
        return 0
    fi
    if (( now - LAST_ACTIVITY_SENT < ACTIVITY_INTERVAL )); then
        return 0
    fi

    telegram_api_post "sendMessage" \
        -H "Content-Type: application/json" \
        -d "$(jq -n -c --arg cid "$chat_id" --arg txt "$activity" \
            '{chat_id: $cid, text: $txt, disable_notification: true}')" \
        > /dev/null 2>&1 || true

    LAST_ACTIVITY="$activity"
    LAST_ACTIVITY_SENT=$now
    log "Activity update to ${chat_id}: ${activity}"
}

# Dedup: rolling hash file to prevent double-injection on crash recovery
DEDUP_FILE="${CRM_ROOT}/state/${AGENT}.dedup"

# Inject a block of messages into the Claude Code session.
inject_messages() {
    local content="$1"

    # --- Dedup check (Fix 8) ---
    local msg_hash
    msg_hash=$(printf '%s' "$content" | shasum 2>/dev/null | cut -d' ' -f1) || msg_hash=""
    if [[ -z "$msg_hash" ]]; then
        msg_hash=$(printf '%s' "$content" | md5 -q 2>/dev/null) || msg_hash=""
    fi
    if [[ -z "$msg_hash" ]]; then
        msg_hash=$(printf '%s' "$content" | md5sum 2>/dev/null | cut -d' ' -f1) || msg_hash=""
    fi
    if [[ -z "$msg_hash" ]]; then
        msg_hash="nohash_$(date +%s)_$$"
        log "Dedup: hash computation failed, using fallback: ${msg_hash}"
    fi
    if [[ -f "$DEDUP_FILE" ]] && grep -qxF "$msg_hash" "$DEDUP_FILE" 2>/dev/null; then
        log "Dedup: skipping duplicate (hash: ${msg_hash:0:8})"
        return 0
    fi
    echo "$msg_hash" >> "$DEDUP_FILE"
    # Clean dedup file and remove any empty lines
    grep -v '^$' "$DEDUP_FILE" 2>/dev/null | tail -100 > "${DEDUP_FILE}.tmp" 2>/dev/null && mv "${DEDUP_FILE}.tmp" "$DEDUP_FILE"

    local tmpfile
    tmpfile=$(mktemp "/tmp/.crm-msg-XXXXXX" 2>/dev/null) || {
        log "mktemp failed - skipping injection to avoid bare Enter"
        return 1
    }
    chmod 600 "$tmpfile"
    printf '%s' "$content" > "$tmpfile"
    local byte_count
    byte_count=$(wc -c < "$tmpfile" | tr -d ' ')

    # No idle wait — inject immediately. Claude Code queues input received
    # during tool execution and processes it on the next turn.

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
    POLL_COUNT=$((POLL_COUNT + 1))

    # --- Context threshold check (every ~2 min) ---
    if (( POLL_COUNT % 120 == 0 )) && [[ "$CONTEXT_RESTART_TRIGGERED" == "false" ]]; then
        NOW_TS=$(date +%s)
        ELAPSED_SECS=$((NOW_TS - SESSION_START))
        ELAPSED_HOURS=$(( ELAPSED_SECS / 3600 ))
        # Also check if we're within 1 hour of the limit using seconds comparison
        # to avoid integer division flooring at the boundary
        LIMIT_SECS=$((CONTEXT_MAX_HOURS * 3600))

        SHOULD_RESTART=false
        RESTART_REASON=""

        if (( ELAPSED_SECS >= LIMIT_SECS )); then
            SHOULD_RESTART=true
            RESTART_REASON="session running ${ELAPSED_HOURS}h (limit: ${CONTEXT_MAX_HOURS}h)"
        elif (( INJECT_COUNT >= CONTEXT_MAX_INJECTIONS )); then
            SHOULD_RESTART=true
            RESTART_REASON="injection count ${INJECT_COUNT} (limit: ${CONTEXT_MAX_INJECTIONS})"
        fi

        if [[ "$SHOULD_RESTART" == "true" ]]; then
            log "CONTEXT_THRESHOLD: ${RESTART_REASON} — triggering hard-restart"
            CONTEXT_RESTART_TRIGGERED=true
            inject_messages "SYSTEM: Context threshold reached (${RESTART_REASON}). Before restarting: 1) Write a handoff file to ${CRM_ROOT}/state/${AGENT}.handoff.md with current tasks, briefings sent today, open threads, and in-progress work. 2) Notify Josh via Telegram you're restarting. 3) Run: bash ../../core/bus/hard-restart.sh --reason '${RESTART_REASON}'"
            rm -f "${SESSION_START_FILE}"
            # Safety net: if Claude doesn't self-restart within 3 min, force it
            ( sleep 180; if [[ "$CONTEXT_RESTART_TRIGGERED" == "true" ]]; then
                log "CONTEXT_THRESHOLD: Claude did not self-restart in 3min — forcing hard-restart"
                bash "${BUS_DIR}/hard-restart.sh" --reason "forced: context threshold not acted on (${RESTART_REASON})" &
            fi ) &
        fi
    fi

    # Exit if tmux session is gone
    if ! tmux has-session -t "${TMUX_SESSION}" 2>/dev/null; then
        log "Tmux session gone. Exiting."
        exit 0
    fi

    MESSAGE_BLOCK=""

    # --- Kill switch check ---
    KILL_SWITCH_FILE="${CRM_ROOT}/agents/${AGENT}/kill-switch"
    if [[ -f "$KILL_SWITCH_FILE" ]]; then
        REASON=$(cat "$KILL_SWITCH_FILE" 2>/dev/null || echo "paused")
        log "Kill switch active (${REASON}) — skipping message poll"
        sleep 5
        continue
    fi

    # --- Telegram ---
    # Capture offset from fd3 so we can commit it AFTER successful injection.
    TG_OFFSET_FILE=$(mktemp /tmp/crm-tg-offset-XXXXXX 2>/dev/null || echo "/tmp/crm-tg-offset-$$")
    TG_OUTPUT=$(bash "${BUS_DIR}/check-telegram.sh" 3>"$TG_OFFSET_FILE" 2>/dev/null || echo "")
    TG_NEW_OFFSET=""
    if [[ -f "$TG_OFFSET_FILE" ]]; then
        TG_NEW_OFFSET=$(grep '__OFFSET__:' "$TG_OFFSET_FILE" 2>/dev/null | sed 's/__OFFSET__://' || true)
        rm -f "$TG_OFFSET_FILE"
    fi
    if [[ -n "$TG_OUTPUT" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            TYPE=$(echo "$line" | jq -r '.type // "message"' 2>/dev/null || echo "message")
            FROM=$(echo "$line" | jq -r '.from // "unknown"' 2>/dev/null || echo "unknown")
            TEXT=$(echo "$line" | jq -r '.text // ""' 2>/dev/null || echo "")
            CHAT_ID=$(echo "$line" | jq -r '.chat_id // ""' 2>/dev/null || echo "")
            REPLY_TO_TEXT=$(echo "$line" | jq -r '.reply_to_text // ""' 2>/dev/null || echo "")

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
            elif [[ "$TYPE" == "document" ]]; then
                DOC_PATH=$(echo "$line" | jq -r '.file_path // ""' 2>/dev/null || echo "")
                DOC_NAME=$(echo "$line" | jq -r '.file_name // "document"' 2>/dev/null || echo "document")
                # Auto-reply when agent is busy processing
                if ! is_agent_idle; then
                    auto_reply_busy "${CHAT_ID}"
                fi
                HUMAN_MSG_PENDING=true
                HUMAN_MSG_CHAT_ID="${CHAT_ID}"
                HUMAN_MSG_PENDING_SINCE=$(date +%s)
                MESSAGE_BLOCK+="=== TELEGRAM DOCUMENT from ${FROM} (chat_id:${CHAT_ID}) ===
file_name: ${DOC_NAME}
caption:
\`\`\`
${TEXT}
\`\`\`
local_file: ${DOC_PATH}
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
            elif [[ "$TYPE" == "document" ]]; then
                DOC_PATH=$(echo "$line" | jq -r '.file_path // ""' 2>/dev/null || echo "")
                DOC_NAME=$(echo "$line" | jq -r '.file_name // ""' 2>/dev/null || echo "")
                MESSAGE_BLOCK+="=== TELEGRAM DOCUMENT from ${FROM} (chat_id:${CHAT_ID}) ===
caption:
\`\`\`
${TEXT}
\`\`\`
local_file: ${DOC_PATH}
file_name: ${DOC_NAME}
Reply using: bash ../../core/bus/send-telegram.sh ${CHAT_ID} \"<your reply>\"

"
            elif [[ "$TYPE" == "voice" || "$TYPE" == "audio" ]]; then
                AUDIO_PATH=$(echo "$line" | jq -r '.file_path // ""' 2>/dev/null || echo "")
                AUDIO_NAME=$(echo "$line" | jq -r '.file_name // ""' 2>/dev/null || echo "")
                MESSAGE_BLOCK+="=== TELEGRAM ${TYPE^^} from ${FROM} (chat_id:${CHAT_ID}) ===
local_file: ${AUDIO_PATH}
file_name: ${AUDIO_NAME}
Reply using: bash ../../core/bus/send-telegram.sh ${CHAT_ID} \"<your reply>\"

"
            elif [[ "$TYPE" == "video_note" ]]; then
                VIDEO_PATH=$(echo "$line" | jq -r '.file_path // ""' 2>/dev/null || echo "")
                MESSAGE_BLOCK+="=== TELEGRAM VIDEO NOTE from ${FROM} (chat_id:${CHAT_ID}) ===
local_file: ${VIDEO_PATH}
Reply using: bash ../../core/bus/send-telegram.sh ${CHAT_ID} \"<your reply>\"

"
            else
                # /status command: respond directly from fast-checker (Fix 10)
                if [[ "$TEXT" == "/status" ]]; then
                    NOW_S=$(date +%s)
                    UP_H=$(( (NOW_S - SESSION_START) / 3600 ))
                    UP_M=$(( ((NOW_S - SESSION_START) % 3600) / 60 ))
                    is_agent_idle && IDLE_STR="idle" || IDLE_STR="busy"
                    STATUS_MSG="*${AGENT} Status*
Uptime: ${UP_H}h ${UP_M}m
Injections: ${INJECT_COUNT}/${CONTEXT_MAX_INJECTIONS}
Time: ${UP_H}h/${CONTEXT_MAX_HOURS}h limit
Fast-checker: running (poll ${POLL_COUNT})
Agent: ${IDLE_STR}"
                    telegram_api_post "sendMessage" \
                        -H "Content-Type: application/json" \
                        -d "$(jq -n -c --arg cid "$CHAT_ID" --arg txt "$STATUS_MSG" --arg pm "Markdown" \
                            '{chat_id: $cid, text: $txt, parse_mode: $pm}')" > /dev/null 2>&1 || true
                    log "Responded to /status directly"
                    continue
                fi

                # Built-in CLI commands: inject raw so they trigger directly
                if [[ "$TEXT" =~ ^/(compact|clear|help|cost|login|logout|doctor|config|bug|init|review|fast|slow)$ ]]; then
                    MESSAGE_BLOCK+="${TEXT}
"
                else
                    # Auto-reply when agent is busy processing
                    if ! is_agent_idle; then
                        auto_reply_busy "${CHAT_ID}"
                    fi
                    # Track human message for typing indicator (Fix 9)
                    HUMAN_MSG_PENDING=true
                    HUMAN_MSG_CHAT_ID="${CHAT_ID}"
                    HUMAN_MSG_PENDING_SINCE=$(date +%s)
                    REPLY_CONTEXT=""
                    [[ -n "$REPLY_TO_TEXT" ]] && REPLY_CONTEXT="
In reply to: \"${REPLY_TO_TEXT}\""
                    MESSAGE_BLOCK+="=== TELEGRAM from ${FROM} (chat_id:${CHAT_ID}) ===${REPLY_CONTEXT}
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
            INJECT_COUNT=$((INJECT_COUNT + 1))
            # Commit Telegram offset ONLY after successful injection
            if [[ -n "$TG_NEW_OFFSET" ]]; then
                OFFSET_STATE_FILE="${CRM_ROOT}/state/.telegram-offset-${AGENT}"
                echo "$TG_NEW_OFFSET" > "$OFFSET_STATE_FILE"
                log "Committed Telegram offset: ${TG_NEW_OFFSET}"
                TG_NEW_OFFSET=""
            fi
            for ack_id in "${INBOX_MSG_IDS[@]+"${INBOX_MSG_IDS[@]}"}"; do
                bash "${BUS_DIR}/ack-inbox.sh" "$ack_id" 2>/dev/null || true
            done
            # Cooldown after injection
            sleep 5
        else
            log "Injection deferred — NOT advancing Telegram offset (will retry next poll)"
        fi
    else
        # No messages but offset may need advancing (e.g. filtered-out updates from non-allowed users)
        if [[ -n "$TG_NEW_OFFSET" ]]; then
            OFFSET_STATE_FILE="${CRM_ROOT}/state/.telegram-offset-${AGENT}"
            echo "$TG_NEW_OFFSET" > "$OFFSET_STATE_FILE"
        fi
    fi

    # --- Typing indicator + live activity streaming while agent processes human message ---
    if [[ "$HUMAN_MSG_PENDING" == "true" ]]; then
        if ! is_agent_idle; then
            NOW_TS=$(date +%s)

            # Live activity streaming: send status updates instead of just typing indicator
            ACTIVITY_SENT_THIS_CYCLE=false
            if [[ "$ACTIVITY_STREAMING" == "true" ]]; then
                current_activity=$(extract_activity 2>/dev/null) || current_activity=""
                if [[ -n "$current_activity" ]]; then
                    send_activity_update "$HUMAN_MSG_CHAT_ID" "$current_activity"
                    ACTIVITY_SENT_THIS_CYCLE=true
                fi
            fi

            # Fall back to typing indicator if no activity update was sent
            if [[ "$ACTIVITY_SENT_THIS_CYCLE" != "true" ]] && (( NOW_TS - TYPING_LAST_SENT >= 5 )); then
                telegram_api_post "sendChatAction" \
                    -H "Content-Type: application/json" \
                    -d "$(jq -n -c --arg cid "$HUMAN_MSG_CHAT_ID" '{chat_id: $cid, action: "typing"}')" \
                    > /dev/null 2>&1 || true
                TYPING_LAST_SENT=$NOW_TS
            fi
            # Progress detection: hash tmux pane to see if agent is making progress
            CURRENT_PANE=$(tmux capture-pane -t "${TMUX_SESSION}:0.0" -p 2>/dev/null | tail -10)
            CURRENT_HASH=$(printf '%s' "$CURRENT_PANE" | shasum 2>/dev/null | cut -d' ' -f1 || echo "")
            if [[ "$CURRENT_HASH" != "$LAST_PANE_HASH" ]]; then
                # Agent is making progress — reset stale timer
                LAST_PANE_HASH="$CURRENT_HASH"
                PANE_STALE_SINCE=$NOW_TS
            fi
            # Only check frozen if pane has been stale (no progress)
            STALE_AGE=$(( NOW_TS - PANE_STALE_SINCE ))

            # Stage 1: Soft nudge — only if pane stale for 2+ min (no tool output changing)
            if (( PANE_STALE_SINCE > 0 && STALE_AGE >= FROZEN_SOFT_NUDGE_SECONDS && FROZEN_NUDGE_SENT == 0 )); then
                log "FROZEN NUDGE: pane stale for ${STALE_AGE}s — sending Ctrl+C and re-prompt"
                FROZEN_NUDGE_SENT=1
                tmux send-keys -t "${TMUX_SESSION}:0.0" C-c
                sleep 2
                inject_messages "SYSTEM: You have been unresponsive for over ${STALE_AGE} seconds with no visible progress. A user message is waiting. Reply to the user on Telegram NOW — acknowledge their message and explain what happened. Do NOT resume long processing without replying first."
                INJECT_COUNT=$((INJECT_COUNT + 1))
            fi

            # Stage 2: Hard restart — only if stale for 5+ min (nudge didn't help)
            if (( PANE_STALE_SINCE > 0 && STALE_AGE >= FROZEN_RESTART_MAX_SECONDS )); then
                log "FROZEN DETECTED: pane stale for ${STALE_AGE}s — hard-restarting"
                telegram_api_post "sendMessage" \
                    -H "Content-Type: application/json" \
                    -d "$(jq -n -c --arg cid "$HUMAN_MSG_CHAT_ID" --arg txt "Looks like I got stuck. Restarting now..." \
                        '{chat_id: $cid, text: $txt}')" > /dev/null 2>&1 || true
                HUMAN_MSG_PENDING=false
                HUMAN_MSG_PENDING_SINCE=0
                FROZEN_NUDGE_SENT=0
                PANE_STALE_SINCE=0
                bash "${BUS_DIR}/hard-restart.sh" --reason "frozen: pane stale ${STALE_AGE}s with unhandled message" &
            fi
        else
            HUMAN_MSG_PENDING=false
            HUMAN_MSG_PENDING_SINCE=0
            FROZEN_NUDGE_SENT=0
            LAST_PANE_HASH=""
            PANE_STALE_SINCE=0
            LAST_ACTIVITY=""
        fi
    fi

    # --- Health telemetry (Fix 7) — write stats every ~5 min ---
    if (( POLL_COUNT % 300 == 0 )); then
        NOW_TS=$(date +%s)
        jq -n -c \
            --argjson uptime "$((NOW_TS - SESSION_START))" \
            --argjson inject_count "$INJECT_COUNT" \
            --argjson inject_limit "$CONTEXT_MAX_INJECTIONS" \
            --argjson hours_limit "$CONTEXT_MAX_HOURS" \
            --argjson poll_count "$POLL_COUNT" \
            --arg last_check "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --arg agent_state "$(is_agent_idle && echo idle || echo busy)" \
            '{uptime_s: $uptime, injects: $inject_count, inject_limit: $inject_limit, hours_limit: $hours_limit, polls: $poll_count, checked: $last_check, agent: $agent_state}' \
            > "${STATS_FILE}" 2>/dev/null
    fi

    sleep 1
done
