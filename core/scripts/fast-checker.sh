#!/usr/bin/env bash
# fast-checker.sh - High-frequency Telegram + inbox poller
# Injects messages into the live Claude Code tmux session via send-keys
# Usage: fast-checker.sh <agent> <tmux_session> <agent_dir> <template_root>
# Lifecycle: started by agent-wrapper.sh after tmux session is created;
#            killed by agent-wrapper.sh when tmux session dies

set -o pipefail
# Note: intentionally NOT using set -u. For a long-running daemon, an unbound
# variable should not crash the entire poll loop. All variables are initialized
# with safe defaults below instead.

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

# --- Cron scheduler state ---
# Infrastructure-level cron: reads config.json crons[] and fires them on schedule.
# No LLM involvement — crons fire even if agent forgot bootstrap.
CRON_STATE_FILE="${CRM_ROOT}/state/${AGENT}.cron-state.json"
CRON_LAST_CHECK=0
CRON_CHECK_INTERVAL=30  # check every 30 poll cycles (~30s)

# Initialize cron state file if missing
if [[ ! -f "$CRON_STATE_FILE" ]]; then
    echo '{}' > "$CRON_STATE_FILE"
fi

# Check if a cron expression matches the current time
# Supports: */N * * * *, M H * * *, M H * * D, M H */D * *
cron_matches_now() {
    local cron_expr="$1"
    local now_min now_hour now_dom now_dow
    now_min=$(date +%-M)
    now_hour=$(date +%-H)
    now_dom=$(date +%-d)
    now_dow=$(date +%u)  # 1=Mon..7=Sun
    # Convert to 0=Sun..6=Sat for cron compatibility
    [[ "$now_dow" == "7" ]] && now_dow=0

    local c_min c_hour c_dom c_mon c_dow
    read -r c_min c_hour c_dom c_mon c_dow <<< "$cron_expr"

    # Check minute
    if [[ "$c_min" == "*" ]]; then
        : # matches all
    elif [[ "$c_min" =~ ^\*/([0-9]+)$ ]]; then
        local step="${BASH_REMATCH[1]}"
        (( now_min % step != 0 )) && return 1
    elif [[ "$c_min" =~ ^[0-9]+$ ]]; then
        (( now_min != c_min )) && return 1
    fi

    # Check hour
    if [[ "$c_hour" == "*" ]]; then
        :
    elif [[ "$c_hour" =~ ^\*/([0-9]+)$ ]]; then
        local step="${BASH_REMATCH[1]}"
        (( now_hour % step != 0 )) && return 1
    elif [[ "$c_hour" =~ ^[0-9]+$ ]]; then
        (( now_hour != c_hour )) && return 1
    fi

    # Check day of month
    if [[ "$c_dom" == "*" ]]; then
        :
    elif [[ "$c_dom" =~ ^\*/([0-9]+)$ ]]; then
        local step="${BASH_REMATCH[1]}"
        (( now_dom % step != 0 )) && return 1
    elif [[ "$c_dom" =~ ^[0-9]+$ ]]; then
        (( now_dom != c_dom )) && return 1
    fi

    # Check day of week (supports 0-6 and comma-separated like 1,3,5)
    if [[ "$c_dow" == "*" ]]; then
        :
    elif [[ "$c_dow" =~ , ]]; then
        # Comma-separated list
        local match=false
        IFS=',' read -ra DAYS <<< "$c_dow"
        for d in "${DAYS[@]}"; do
            (( d == now_dow )) && match=true
        done
        [[ "$match" == "false" ]] && return 1
    elif [[ "$c_dow" =~ ^([0-9])-([0-9])$ ]]; then
        # Range like 1-5
        local start="${BASH_REMATCH[1]}" end="${BASH_REMATCH[2]}"
        (( now_dow < start || now_dow > end )) && return 1
    elif [[ "$c_dow" =~ ^[0-9]+$ ]]; then
        (( now_dow != c_dow )) && return 1
    fi

    return 0
}

# Convert interval shorthand (15m, 2h) to seconds for dedup window
interval_to_seconds() {
    local interval="$1"
    if [[ "$interval" =~ ^([0-9]+)m$ ]]; then
        echo $(( ${BASH_REMATCH[1]} * 60 ))
    elif [[ "$interval" =~ ^([0-9]+)h$ ]]; then
        echo $(( ${BASH_REMATCH[1]} * 3600 ))
    elif [[ "$interval" =~ ^([0-9]+)d$ ]]; then
        echo $(( ${BASH_REMATCH[1]} * 86400 ))
    elif [[ "$interval" =~ ^([0-9]+)s$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "600"  # default 10min
    fi
}

# Fire due crons from config.json
fire_due_crons() {
    local config_file="${AGENT_DIR}/config.json"
    [[ ! -f "$config_file" ]] && return

    local crons_json
    crons_json=$(jq -c '.crons // []' "$config_file" 2>/dev/null || echo "[]")
    local cron_count
    cron_count=$(echo "$crons_json" | jq 'length' 2>/dev/null || echo "0")
    (( cron_count == 0 )) && return

    local now_epoch
    now_epoch=$(date +%s)

    local cron_state
    cron_state=$(cat "$CRON_STATE_FILE" 2>/dev/null || echo "{}")

    for i in $(seq 0 $((cron_count - 1))); do
        local name schedule interval prompt last_fired cooldown_secs
        name=$(echo "$crons_json" | jq -r ".[$i].name // \"cron_$i\"")
        schedule=$(echo "$crons_json" | jq -r ".[$i].schedule // \"\"")
        interval=$(echo "$crons_json" | jq -r ".[$i].interval // \"\"")
        prompt=$(echo "$crons_json" | jq -r ".[$i].prompt // \"\"")
        [[ -z "$prompt" ]] && continue

        last_fired=$(echo "$cron_state" | jq -r ".\"${name}\" // 0")

        if [[ -n "$schedule" ]]; then
            # Cron expression — check if it matches now
            if ! cron_matches_now "$schedule"; then
                continue
            fi
            # Cooldown: don't re-fire within 55 seconds (prevents double-fire within same minute)
            cooldown_secs=55
        elif [[ -n "$interval" ]]; then
            # Interval shorthand — convert and check elapsed
            cooldown_secs=$(interval_to_seconds "$interval")
            local elapsed=$(( now_epoch - last_fired ))
            if (( elapsed < cooldown_secs )); then
                continue
            fi
        else
            continue
        fi

        # Check cooldown
        local since_last=$(( now_epoch - last_fired ))
        if (( since_last < cooldown_secs )); then
            continue
        fi

        # Fire it
        log "CRON FIRE [${name}]: injecting prompt (${#prompt} chars)"
        if inject_messages "$prompt"; then
            INJECT_COUNT=$((INJECT_COUNT + 1))
            # Update state
            cron_state=$(echo "$cron_state" | jq -c --arg n "$name" --argjson t "$now_epoch" '.[$n] = $t')
            echo "$cron_state" > "$CRON_STATE_FILE"
            log "CRON FIRE [${name}]: success, next eligible after cooldown"
            # Only fire one cron per poll cycle to avoid flooding
            return
        else
            log "CRON FIRE [${name}]: injection failed"
        fi
    done
}

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

FROZEN_RESTART_MAX_SECONDS=600  # hard-restart if agent busy for 10+ min with pending human msg
FROZEN_NUDGE_SENT=0  # whether we've sent a soft nudge before hard-restart
BOOTSTRAP_GRACE_SECONDS=600  # skip frozen detection for first 10 min after startup

# Passive frozen detection: detect stale agents even without human messages
LAST_PANE_HASH=""
PANE_UNCHANGED_SINCE=0  # timestamp when pane content last changed
PASSIVE_FROZEN_THRESHOLD=1800  # 30 min of zero pane change while busy = frozen
PASSIVE_FROZEN_TRIGGERED=false

# Telemetry state file (Fix 7)
STATS_FILE="${CRM_ROOT}/state/${AGENT}.stats.json"

# Trigger a hard-restart with retry logic
do_hard_restart() {
    local reason="${1:-unknown}"
    local restart_script="${BUS_DIR}/hard-restart.sh"
    if [[ -x "$restart_script" ]] || [[ -f "$restart_script" ]]; then
        log "Executing hard-restart: ${reason}"
        bash "$restart_script" --reason "$reason" &
    else
        log "ERROR: hard-restart.sh not found at ${restart_script} — attempting direct launchctl restart"
        # Fallback: directly restart via launchctl
        local plist="${HOME}/Library/LaunchAgents/com.claude-remote.${CRM_INSTANCE_ID}.${AGENT}.plist"
        if [[ -f "$plist" ]]; then
            mkdir -p "${CRM_ROOT}/state"
            touch "${CRM_ROOT}/state/${AGENT}.force-fresh"
            rm -f "${CRM_ROOT}/state/${AGENT}.session-start"
            nohup bash -c "sleep 10 && launchctl unload '${plist}' 2>/dev/null; sleep 1 && launchctl load '${plist}'" \
                >> "${CRM_ROOT}/logs/${AGENT}/restarts.log" 2>&1 &
            disown
            log "Fallback launchctl restart scheduled for ${AGENT}"
        else
            log "CRITICAL: No plist found at ${plist} — cannot restart ${AGENT}"
        fi
    fi
}

# Check if agent is idle by looking at tmux pane
is_agent_idle() {
    local pane_bottom
    pane_bottom=$(tmux capture-pane -t "${TMUX_SESSION}:0.0" -p 2>/dev/null | grep -v '^$' | tail -5)
    # Claude Code shows ❯ or > prompt when idle, tool output/spinners when busy
    # Also check for status bar patterns (bypass permissions, context %) as idle indicators
    echo "$pane_bottom" | grep -qE '^\s*(>|❯)\s*$' || echo "$pane_bottom" | grep -qE 'bypass permissions on'
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

# Dedup: rolling hash file to prevent double-injection on crash recovery
DEDUP_FILE="${CRM_ROOT}/state/${AGENT}.dedup"

# Inject a block of messages into the Claude Code session.
inject_messages() {
    local content="$1"

    # --- Dedup check (Fix 8) ---
    local msg_hash=""
    # shasum is always available on macOS; md5/md5sum may not be
    msg_hash=$(printf '%s' "$content" | shasum -a 256 2>/dev/null | cut -d' ' -f1) || msg_hash=""
    if [[ -z "$msg_hash" ]]; then
        msg_hash=$(printf '%s' "$content" | md5 -q 2>/dev/null) || msg_hash=""
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
        ELAPSED_HOURS=$(( (NOW_TS - SESSION_START) / 3600 ))

        SHOULD_RESTART=false
        RESTART_REASON=""

        # Primary: parse actual context % from Claude Code status bar
        CONTEXT_PCT=0
        STATUS_BAR=$(tmux capture-pane -t "${TMUX_SESSION}:0.0" -p 2>/dev/null | tail -3)
        if [[ -n "$STATUS_BAR" ]]; then
            # Match patterns like "████████░░ 89%" or "89%" in the status bar
            PCT_MATCH=$(echo "$STATUS_BAR" | grep -oE '[0-9]+%' | head -1 | tr -d '%')
            if [[ -n "$PCT_MATCH" && "$PCT_MATCH" =~ ^[0-9]+$ ]]; then
                CONTEXT_PCT=$PCT_MATCH
            fi
        fi

        if (( CONTEXT_PCT >= 80 )); then
            SHOULD_RESTART=true
            RESTART_REASON="context at ${CONTEXT_PCT}% (threshold: 80%)"
        elif (( ELAPSED_HOURS >= CONTEXT_MAX_HOURS )); then
            SHOULD_RESTART=true
            RESTART_REASON="session running ${ELAPSED_HOURS}h (limit: ${CONTEXT_MAX_HOURS}h)"
        elif (( INJECT_COUNT >= CONTEXT_MAX_INJECTIONS )); then
            SHOULD_RESTART=true
            RESTART_REASON="injection count ${INJECT_COUNT} (limit: ${CONTEXT_MAX_INJECTIONS})"
        fi

        if [[ "$SHOULD_RESTART" == "true" ]]; then
            log "CONTEXT_THRESHOLD: ${RESTART_REASON} — triggering hard-restart"
            CONTEXT_RESTART_TRIGGERED=true
            inject_messages "SYSTEM: Context threshold reached (${RESTART_REASON}). Before restarting: 1) Write handoff files (state.json + markdown). 2) Notify Josh via Telegram you're restarting. 3) Run: bash ../../core/bus/hard-restart.sh --reason '${RESTART_REASON}'"
            rm -f "${SESSION_START_FILE}"
            # Safety net with retry: if Claude doesn't self-restart within 2 min, force it.
            # Then verify the restart succeeded. If not, retry once more.
            ( sleep 120
              log "CONTEXT_THRESHOLD: safety net — forcing hard-restart (${RESTART_REASON})"
              do_hard_restart "forced: context threshold not acted on (${RESTART_REASON})"
              # Verify restart succeeded after 90s
              sleep 90
              if ! tmux has-session -t "${TMUX_SESSION}" 2>/dev/null; then
                  log "CONTEXT_THRESHOLD: post-restart verification FAILED — tmux gone. Retry restart."
                  do_hard_restart "retry: first restart failed (${RESTART_REASON})"
              else
                  VERIFY_PANE=$(tmux capture-pane -t "${TMUX_SESSION}:0.0" -p 2>/dev/null | tail -5)
                  if echo "$VERIFY_PANE" | grep -qE 'permissions|bypass|❯'; then
                      log "CONTEXT_THRESHOLD: post-restart verification PASSED"
                  else
                      log "CONTEXT_THRESHOLD: post-restart verification UNCERTAIN — agent may still be booting"
                  fi
              fi
            ) &
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
            else
                # /status command: respond directly from fast-checker (Fix 10)
                if [[ "$TEXT" == "/status" ]]; then
                    NOW_S=$(date +%s)
                    UP_H=$(( (NOW_S - SESSION_START) / 3600 ))
                    UP_M=$(( ((NOW_S - SESSION_START) % 3600) / 60 ))
                    is_agent_idle && IDLE_STR="idle" || IDLE_STR="busy"
                    # Parse context % from status bar
                    SB=$(tmux capture-pane -t "${TMUX_SESSION}:0.0" -p 2>/dev/null | tail -3)
                    CTX_S="unknown"
                    if [[ -n "$SB" ]]; then
                        CTX_V=$(echo "$SB" | grep -oE '[0-9]+%' | head -1)
                        [[ -n "$CTX_V" ]] && CTX_S="$CTX_V"
                    fi
                    STATUS_MSG="*${AGENT} Status*
Context: ${CTX_S}
Uptime: ${UP_H}h ${UP_M}m
Injections: ${INJECT_COUNT}/${CONTEXT_MAX_INJECTIONS}
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
        # Commit Telegram offset immediately — dedup hash prevents re-injection on retry
        if [[ -n "$TG_NEW_OFFSET" ]]; then
            OFFSET_STATE_FILE="${CRM_ROOT}/state/.telegram-offset-${AGENT}"
            echo "$TG_NEW_OFFSET" > "$OFFSET_STATE_FILE"
            log "Committed Telegram offset: ${TG_NEW_OFFSET}"
            TG_NEW_OFFSET=""  # clear so the else-branch below doesn't double-commit
        fi
        if inject_messages "$MESSAGE_BLOCK"; then
            INJECT_COUNT=$((INJECT_COUNT + 1))
            for ack_id in "${INBOX_MSG_IDS[@]+"${INBOX_MSG_IDS[@]}"}"; do
                bash "${BUS_DIR}/ack-inbox.sh" "$ack_id" 2>/dev/null || true
            done
            # Cooldown after injection
            sleep 5
        else
            log "Injection failed — offset already committed, dedup hash will prevent re-injection"
        fi
    else
        # No messages but offset may need advancing (e.g. filtered-out updates from non-allowed users)
        if [[ -n "$TG_NEW_OFFSET" ]]; then
            OFFSET_STATE_FILE="${CRM_ROOT}/state/.telegram-offset-${AGENT}"
            echo "$TG_NEW_OFFSET" > "$OFFSET_STATE_FILE"
        fi
    fi

    # --- Typing indicator while agent processes human message (Fix 9) ---
    if [[ "$HUMAN_MSG_PENDING" == "true" ]]; then
        NOW_TS=$(date +%s)
        PENDING_AGE=$(( NOW_TS - HUMAN_MSG_PENDING_SINCE ))
        # Keep typing active for at least 30s after message injection — agent goes idle
        # briefly between tool calls which would prematurely clear the indicator
        TYPING_GRACE_SECONDS=30

        if ! is_agent_idle; then
            if (( NOW_TS - TYPING_LAST_SENT >= 5 )); then
                telegram_api_post "sendChatAction" \
                    -H "Content-Type: application/json" \
                    -d "$(jq -n -c --arg cid "$HUMAN_MSG_CHAT_ID" '{chat_id: $cid, action: "typing"}')" \
                    > /dev/null 2>&1 || true
                TYPING_LAST_SENT=$NOW_TS
            fi
            # Soft nudge at 60% of threshold — try to unstick agent before hard-restart
            NUDGE_THRESHOLD=$(( FROZEN_RESTART_MAX_SECONDS * 60 / 100 ))
            if (( FROZEN_NUDGE_SENT == 0 && HUMAN_MSG_PENDING_SINCE > 0 && PENDING_AGE >= NUDGE_THRESHOLD && PENDING_AGE < FROZEN_RESTART_MAX_SECONDS )); then
                log "SOFT NUDGE: agent busy for ${PENDING_AGE}s — sending Escape+Enter to try unsticking"
                tmux send-keys -t "${TMUX_SESSION}:0.0" Escape
                sleep 0.5
                tmux send-keys -t "${TMUX_SESSION}:0.0" Enter
                FROZEN_NUDGE_SENT=1
            fi

            # Frozen detection: if agent has been "busy" for too long, hard-restart
            # Skip during bootstrap grace period
            UPTIME=$(( NOW_TS - SESSION_START ))
            if (( UPTIME >= BOOTSTRAP_GRACE_SECONDS && HUMAN_MSG_PENDING_SINCE > 0 && PENDING_AGE >= FROZEN_RESTART_MAX_SECONDS )); then
                log "FROZEN DETECTED: agent busy for ${PENDING_AGE}s with unhandled human msg — hard-restarting"
                telegram_api_post "sendMessage" \
                    -H "Content-Type: application/json" \
                    -d "$(jq -n -c --arg cid "$HUMAN_MSG_CHAT_ID" --arg txt "Looks like I got stuck. Restarting now..." \
                        '{chat_id: $cid, text: $txt}')" > /dev/null 2>&1 || true
                HUMAN_MSG_PENDING=false
                HUMAN_MSG_PENDING_SINCE=0
                FROZEN_NUDGE_SENT=0
                do_hard_restart "frozen: agent busy ${PENDING_AGE}s with unhandled message"
            fi
        elif (( PENDING_AGE < TYPING_GRACE_SECONDS )); then
            # Agent appears idle but within grace period — keep typing indicator active
            if (( NOW_TS - TYPING_LAST_SENT >= 5 )); then
                telegram_api_post "sendChatAction" \
                    -H "Content-Type: application/json" \
                    -d "$(jq -n -c --arg cid "$HUMAN_MSG_CHAT_ID" '{chat_id: $cid, action: "typing"}')" \
                    > /dev/null 2>&1 || true
                TYPING_LAST_SENT=$NOW_TS
            fi
        else
            HUMAN_MSG_PENDING=false
            HUMAN_MSG_PENDING_SINCE=0
            FROZEN_NUDGE_SENT=0
        fi
    fi

    # --- Passive frozen detection: catch stuck agents even without human messages ---
    # Primary signal: heartbeat file written by PostToolUse hook (most reliable)
    # Fallback: tmux pane hash comparison (for agents without heartbeat hook)
    if (( POLL_COUNT % 30 == 0 )); then
        NOW_TS=$(date +%s)
        UPTIME_NOW=$(( NOW_TS - SESSION_START ))
        HEARTBEAT_FILE="${CRM_ROOT}/state/${AGENT}.heartbeat"
        HEARTBEAT_AGE=-1

        if [[ -f "$HEARTBEAT_FILE" ]]; then
            # Heartbeat file exists — use it as primary activity signal
            LAST_HEARTBEAT=$(cat "$HEARTBEAT_FILE" 2>/dev/null || echo "0")
            if [[ "$LAST_HEARTBEAT" =~ ^[0-9]+$ ]] && (( LAST_HEARTBEAT > 0 )); then
                HEARTBEAT_AGE=$(( NOW_TS - LAST_HEARTBEAT ))
                if (( HEARTBEAT_AGE < PASSIVE_FROZEN_THRESHOLD )); then
                    # Recent heartbeat — agent is alive, reset frozen state
                    PASSIVE_FROZEN_TRIGGERED=false
                    PANE_UNCHANGED_SINCE=$NOW_TS
                elif [[ "$PASSIVE_FROZEN_TRIGGERED" == "false" ]] && ! is_agent_idle && (( UPTIME_NOW >= BOOTSTRAP_GRACE_SECONDS )); then
                    log "PASSIVE FROZEN (heartbeat): no tool use for ${HEARTBEAT_AGE}s while agent busy — hard-restarting"
                    PASSIVE_FROZEN_TRIGGERED=true
                    do_hard_restart "passive frozen: heartbeat stale ${HEARTBEAT_AGE}s while busy"
                fi
            fi
        fi

        # Fallback: pane hash comparison (used when heartbeat file doesn't exist yet)
        if (( HEARTBEAT_AGE < 0 )); then
            CURRENT_PANE=$(tmux capture-pane -t "${TMUX_SESSION}:0.0" -p 2>/dev/null | tail -20)
            CURRENT_PANE_HASH=$(printf '%s' "$CURRENT_PANE" | shasum -a 256 2>/dev/null | cut -d' ' -f1)

            if [[ "$CURRENT_PANE_HASH" != "$LAST_PANE_HASH" ]]; then
                LAST_PANE_HASH="$CURRENT_PANE_HASH"
                PANE_UNCHANGED_SINCE=$NOW_TS
                PASSIVE_FROZEN_TRIGGERED=false
            elif [[ "$PASSIVE_FROZEN_TRIGGERED" == "false" ]] && (( PANE_UNCHANGED_SINCE > 0 )); then
                STALE_DURATION=$(( NOW_TS - PANE_UNCHANGED_SINCE ))
                if ! is_agent_idle && (( UPTIME_NOW >= BOOTSTRAP_GRACE_SECONDS && STALE_DURATION >= PASSIVE_FROZEN_THRESHOLD )); then
                    log "PASSIVE FROZEN (pane): pane unchanged for ${STALE_DURATION}s while agent busy — hard-restarting"
                    PASSIVE_FROZEN_TRIGGERED=true
                    do_hard_restart "passive frozen: pane unchanged ${STALE_DURATION}s while busy"
                fi
            fi
        fi
    fi

    # --- Health telemetry (Fix 7) — write stats every ~5 min ---
    if (( POLL_COUNT % 300 == 0 )); then
        NOW_TS=$(date +%s)
        # Read heartbeat age for telemetry
        HB_AGE_STAT=-1
        HB_FILE_STAT="${CRM_ROOT}/state/${AGENT}.heartbeat"
        if [[ -f "$HB_FILE_STAT" ]]; then
            HB_TS=$(cat "$HB_FILE_STAT" 2>/dev/null || echo "0")
            [[ "$HB_TS" =~ ^[0-9]+$ ]] && (( HB_TS > 0 )) && HB_AGE_STAT=$(( NOW_TS - HB_TS ))
        fi
        # Read context % from status bar for telemetry
        CTX_PCT_STAT=0
        CTX_BAR=$(tmux capture-pane -t "${TMUX_SESSION}:0.0" -p 2>/dev/null | tail -3)
        if [[ -n "$CTX_BAR" ]]; then
            CTX_M=$(echo "$CTX_BAR" | grep -oE '[0-9]+%' | head -1 | tr -d '%')
            [[ -n "$CTX_M" && "$CTX_M" =~ ^[0-9]+$ ]] && CTX_PCT_STAT=$CTX_M
        fi
        jq -n -c \
            --argjson uptime "$((NOW_TS - SESSION_START))" \
            --argjson inject_count "$INJECT_COUNT" \
            --argjson inject_limit "$CONTEXT_MAX_INJECTIONS" \
            --argjson hours_limit "$CONTEXT_MAX_HOURS" \
            --argjson poll_count "$POLL_COUNT" \
            --argjson heartbeat_age "$HB_AGE_STAT" \
            --argjson context_pct "$CTX_PCT_STAT" \
            --arg last_check "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --arg agent_state "$(is_agent_idle && echo idle || echo busy)" \
            '{uptime_s: $uptime, injects: $inject_count, inject_limit: $inject_limit, hours_limit: $hours_limit, polls: $poll_count, heartbeat_age_s: $heartbeat_age, context_pct: $context_pct, checked: $last_check, agent: $agent_state}' \
            > "${STATS_FILE}" 2>/dev/null
    fi

    # --- Idle-state dedup clearing + queued message detection ---
    # When agent transitions from busy to idle, clear the dedup file so
    # messages that were injected but not processed can be re-injected.
    # Also detect Claude Code's "Press up to edit queued messages" state
    # and auto-submit with Enter.
    if (( POLL_COUNT % 5 == 0 )); then
        if is_agent_idle; then
            # Check for "queued messages" state — means input was pasted but not submitted
            PANE_BOTTOM=$(tmux capture-pane -t "${TMUX_SESSION}:0.0" -p 2>/dev/null | tail -5)
            if echo "$PANE_BOTTOM" | grep -qi "queued messages\|Press up to edit"; then
                log "QUEUED MSG FIX: detected 'queued messages' state — sending Enter to submit"
                tmux send-keys -t "${TMUX_SESSION}:0.0" Enter
            fi

            # Clear dedup file when agent is idle — allows re-injection of unprocessed messages
            if [[ "${AGENT_WAS_BUSY:-false}" == "true" ]]; then
                if [[ -f "$DEDUP_FILE" ]]; then
                    log "DEDUP CLEAR: agent returned to idle — clearing dedup file for fresh message injection"
                    rm -f "$DEDUP_FILE"
                fi
                AGENT_WAS_BUSY=false
            fi
        else
            AGENT_WAS_BUSY=true
        fi
    fi

    # --- Infrastructure cron scheduler ---
    # Fires crons from config.json independently of LLM bootstrap.
    # Checks every CRON_CHECK_INTERVAL polls (~30s). Only fires when agent is idle
    # to avoid interrupting active work (cron will fire on next idle check).
    if (( POLL_COUNT % CRON_CHECK_INTERVAL == 0 )); then
        if is_agent_idle; then
            fire_due_crons
        fi
    fi

    sleep 1
done
