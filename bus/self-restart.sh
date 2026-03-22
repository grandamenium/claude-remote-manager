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
TEMPLATE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENT_DIR="${TEMPLATE_ROOT}/agents/${AGENT}"

# Load instance ID
REPO_ENV="${TEMPLATE_ROOT}/.env"
if [[ -f "${REPO_ENV}" ]]; then
    BOS_INSTANCE_ID=$(grep '^BOS_INSTANCE_ID=' "${REPO_ENV}" | cut -d= -f2)
fi
BOS_INSTANCE_ID="${BOS_INSTANCE_ID:-default}"
BOS_ROOT="${BOS_ROOT:-${HOME}/.business-os/${BOS_INSTANCE_ID}}"

TMUX_SESSION="bos-${BOS_INSTANCE_ID}-${AGENT}"
REASON="${2:-no reason specified}"

# Log the restart
LOG_DIR="${BOS_ROOT}/logs/${AGENT}"
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

    tmux send-keys -t '${TMUX_SESSION}:0.0' C-c
    sleep 1
    tmux send-keys -t '${TMUX_SESSION}:0.0' '/exit' Enter
    sleep 3

    CLAUDE_PID=\$(tmux list-panes -t '${TMUX_SESSION}' -F '#{pane_pid}' 2>/dev/null | head -1)
    if [[ -n \"\$CLAUDE_PID\" ]]; then
        pkill -P \"\$CLAUDE_PID\" 2>/dev/null || true
        sleep 2
    fi

    # Kill old fast-checker and start fresh one
    pkill -f 'fast-checker.sh ${AGENT} ' 2>/dev/null || true
    sleep 1
    FAST_CHECKER='${TEMPLATE_ROOT}/scripts/fast-checker.sh'
    if [[ -f \"\$FAST_CHECKER\" ]]; then
        bash \"\$FAST_CHECKER\" '${AGENT}' '${TMUX_SESSION}' '${AGENT_DIR}' '${TEMPLATE_ROOT}' \
            >> '${LOG_DIR}/fast-checker.log' 2>&1 &
    fi

    tmux send-keys -t '${TMUX_SESSION}:0.0' \
        \"cd '${AGENT_DIR}' && claude --continue --dangerously-skip-permissions ${MODEL_FLAG} '${CONTINUE_PROMPT}'\" Enter
" >> "${LOG_DIR}/restarts.log" 2>&1 &
disown

echo "CLI restart with --continue scheduled for ${AGENT} in ~5 seconds. Conversation will be preserved."
