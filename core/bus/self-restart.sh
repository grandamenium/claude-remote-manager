#!/usr/bin/env bash
# self-restart.sh - Restart Claude CLI with --continue (preserves conversation)
# Usage: bash ../../bus/self-restart.sh --reason "why"
#
# Kills the current Claude process inside tmux and relaunches with --continue.
# This reloads all configs (settings.json, hooks, CLAUDE.md) while preserving
# the full conversation history. Crons need to be re-set up after restart.
#
# For a hard restart (fresh session, no history), use: bash ../../bus/hard-restart.sh

set -euo pipefail

AGENT="$(basename "$(pwd)")"
TEMPLATE_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AGENT_DIR="${TEMPLATE_ROOT}/agents/${AGENT}"

# Load instance ID
REPO_ENV="${TEMPLATE_ROOT}/.env"
if [[ -f "${REPO_ENV}" ]]; then
    CRM_INSTANCE_ID=$(grep '^CRM_INSTANCE_ID=' "${REPO_ENV}" | cut -d= -f2)
fi
CRM_INSTANCE_ID="${CRM_INSTANCE_ID:-default}"
CRM_ROOT="${CRM_ROOT:-${HOME}/.claude-remote/${CRM_INSTANCE_ID}}"

TMUX_SESSION="crm-${CRM_INSTANCE_ID}-${AGENT}"
REASON="${2:-no reason specified}"

# Validate handoff state before allowing restart
VALIDATE_SCRIPT="${TEMPLATE_ROOT}/core/bus/validate-handoff.sh"
if [[ -f "${VALIDATE_SCRIPT}" ]]; then
    if ! bash "${VALIDATE_SCRIPT}" "${AGENT}"; then
        echo "RESTART BLOCKED: Handoff validation failed. Update state file first." >&2
        exit 1
    fi
fi

# Load agent .env for Telegram notification
AGENT_ENV="${TEMPLATE_ROOT}/agents/${AGENT}/.env"
if [[ -f "${AGENT_ENV}" ]]; then
    set -a; source "${AGENT_ENV}"; set +a
fi

# Send Telegram notification before restart
if [[ -n "${BOT_TOKEN:-}" && -n "${CHAT_ID:-}" ]]; then
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="${CHAT_ID}" \
        -d text="Soft-restarting ${AGENT}: ${REASON}" \
        > /dev/null 2>&1 || true
fi

# Log the restart
LOG_DIR="${CRM_ROOT}/logs/${AGENT}"
mkdir -p "${LOG_DIR}"
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] CLI restart with --continue. Reason: ${REASON}" >> "${LOG_DIR}/restarts.log"

# Check if tmux session exists
if ! tmux has-session -t "${TMUX_SESSION}" 2>/dev/null; then
    echo "ERROR: No tmux session '${TMUX_SESSION}' found. Agent is not running." >&2
    exit 1
fi

# Model flag
MODEL_FLAG=""
MODEL=$(jq -r '.model // empty' "${AGENT_DIR}/config.json" 2>/dev/null || echo "")
if [[ -n "${MODEL}" ]]; then
    MODEL_FLAG="--model ${MODEL}"
fi

RESTART_NOTIFY="After setting up crons, send a Telegram message to the user saying you restarted, why, and what you are resuming."

CONTINUE_PROMPT="SESSION CONTINUATION: Your CLI was restarted with --continue to reload configs. Reason: ${REASON}. Your conversation history is preserved. Re-read bootstrap files listed in CLAUDE.md, set up crons from config.json via /loop, then resume what you were working on. ${RESTART_NOTIFY}"

# Schedule the restart after a delay so current turn can finish
nohup bash -c "
    sleep 5

    # Capture the old Claude PID before trying to exit
    OLD_PANE_PID=\$(tmux list-panes -t '${TMUX_SESSION}' -F '#{pane_pid}' 2>/dev/null | head -1)
    OLD_CLAUDE_PID=''
    if [[ -n \"\$OLD_PANE_PID\" ]]; then
        OLD_CLAUDE_PID=\$(pgrep -P \"\$OLD_PANE_PID\" -f 'claude' 2>/dev/null | head -1 || true)
    fi
    echo \"[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Old pane PID: \$OLD_PANE_PID, Old claude PID: \$OLD_CLAUDE_PID\"

    # Step 1: Try graceful exit
    tmux send-keys -t '${TMUX_SESSION}:0.0' C-c
    sleep 1
    tmux send-keys -t '${TMUX_SESSION}:0.0' '/exit' Enter
    sleep 3

    # Step 2: Check if Claude actually exited
    STILL_ALIVE=false
    if [[ -n \"\$OLD_CLAUDE_PID\" ]] && kill -0 \"\$OLD_CLAUDE_PID\" 2>/dev/null; then
        STILL_ALIVE=true
        echo \"[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ZOMBIE: Claude PID \$OLD_CLAUDE_PID still alive after /exit. Escalating to pkill.\"
        pkill -P \"\$OLD_PANE_PID\" 2>/dev/null || true
        sleep 3
    fi

    # Step 3: Nuclear option — if still alive, force kill
    if [[ -n \"\$OLD_CLAUDE_PID\" ]] && kill -0 \"\$OLD_CLAUDE_PID\" 2>/dev/null; then
        echo \"[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ZOMBIE: Still alive after pkill. Force killing PID \$OLD_CLAUDE_PID.\"
        kill -9 \"\$OLD_CLAUDE_PID\" 2>/dev/null || true
        sleep 2
    fi

    # Step 4: Final fallback — kill everything in the pane
    if [[ -n \"\$OLD_PANE_PID\" ]]; then
        REMAINING=\$(pgrep -P \"\$OLD_PANE_PID\" 2>/dev/null || true)
        if [[ -n \"\$REMAINING\" ]]; then
            echo \"[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Killing remaining children of pane: \$REMAINING\"
            echo \"\$REMAINING\" | xargs kill -9 2>/dev/null || true
            sleep 2
        fi
    fi

    echo \"[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Old session cleared. Starting new session.\"

    # Kill old fast-checker and start fresh one
    pkill -f 'fast-checker.sh ${AGENT} ' 2>/dev/null || true
    sleep 1
    FAST_CHECKER='${TEMPLATE_ROOT}/core/scripts/fast-checker.sh'
    if [[ -f \"\$FAST_CHECKER\" ]]; then
        bash \"\$FAST_CHECKER\" '${AGENT}' '${TMUX_SESSION}' '${AGENT_DIR}' '${TEMPLATE_ROOT}' \
            >> '${LOG_DIR}/fast-checker.log' 2>&1 &
    fi

    tmux send-keys -t '${TMUX_SESSION}:0.0' \
        \"cd '${AGENT_DIR}' && claude --continue --dangerously-skip-permissions ${MODEL_FLAG} '${CONTINUE_PROMPT}'\" Enter

    # Step 5: Verify restart actually happened (wait 10s, check for new PID)
    sleep 10
    NEW_CLAUDE_PID=\$(tmux list-panes -t '${TMUX_SESSION}' -F '#{pane_pid}' 2>/dev/null | head -1)
    if [[ \"\$NEW_CLAUDE_PID\" == \"\$OLD_PANE_PID\" ]]; then
        echo \"[$(date -u +%Y-%m-%dT%H:%M:%SZ)] WARNING: Pane PID unchanged — restart may have failed\"
    else
        echo \"[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Restart verified. New pane PID: \$NEW_CLAUDE_PID\"
    fi
" >> "${LOG_DIR}/restarts.log" 2>&1 &
disown

echo "CLI restart with --continue scheduled for ${AGENT} in ~5 seconds. Conversation will be preserved."
