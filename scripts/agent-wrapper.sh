#!/usr/bin/env bash
# agent-wrapper.sh - Wrapper script for launchd-managed Claude Code agents
# Handles crash counting, environment loading, rate limit detection, and respawn
# Usage: agent-wrapper.sh <agent_name> <template_root>
#
# Lifecycle:
#   1. launchd starts this script
#   2. We create a tmux session and run claude inside it (provides PTY)
#   3. Claude bootstraps, creates /loop crons, runs until timeout (default 71h)
#   4. Timer restarts Claude CLI with --continue (reloads configs, preserves conversation)
#
# User can attach to any agent: tmux attach -t bos-<instance>-<agent_name>
#
# NOTE: --dangerously-skip-permissions is required for headless mode.
# Agent boundaries are enforced via CLAUDE.md instructions, not CLI permissions.

set -euo pipefail

AGENT="$1"
TEMPLATE_ROOT="$2"

# Load instance ID from repo .env or environment
REPO_ENV="${TEMPLATE_ROOT}/.env"
if [[ -f "${REPO_ENV}" ]]; then
    BOS_INSTANCE_ID=$(grep '^BOS_INSTANCE_ID=' "${REPO_ENV}" | cut -d= -f2)
fi
BOS_INSTANCE_ID="${BOS_INSTANCE_ID:-default}"

BOS_ROOT="${HOME}/.business-os/${BOS_INSTANCE_ID}"
AGENT_DIR="${TEMPLATE_ROOT}/agents/${AGENT}"
LOG_DIR="${BOS_ROOT}/logs/${AGENT}"
CRASH_LOG="${LOG_DIR}/crashes.log"
CRASH_COUNT_FILE="${LOG_DIR}/.crash_count_today"
MAX_CRASHES_PER_DAY=3
TMUX_SESSION="bos-${BOS_INSTANCE_ID}-${AGENT}"

mkdir -p "${LOG_DIR}"

# Source environment file if it exists (for bot tokens, API keys, etc.)
ENV_FILE="${AGENT_DIR}/.env"
if [[ -f "${ENV_FILE}" ]]; then
    set -a
    source "${ENV_FILE}"
    set +a
fi

# Also source user's shell profile for global env vars
for profile in "${HOME}/.zshrc" "${HOME}/.bashrc" "${HOME}/.bash_profile" "${HOME}/.profile"; do
    if [[ -f "${profile}" ]]; then
        # Only source export lines to avoid interactive shell issues
        grep -E '^export ' "${profile}" 2>/dev/null | while read -r line; do
            eval "${line}" 2>/dev/null || true
        done
        break
    fi
done

export BOS_AGENT_NAME="${AGENT}"
export BOS_INSTANCE_ID="${BOS_INSTANCE_ID}"
export BOS_ROOT="${BOS_ROOT}"
export BOS_TEMPLATE_ROOT="${TEMPLATE_ROOT}"

# Check crash count for today (single-line format: date:count)
TODAY=$(date +%Y-%m-%d)
if [[ -f "${CRASH_COUNT_FILE}" ]]; then
    STORED_DATE=$(cut -d: -f1 "${CRASH_COUNT_FILE}" 2>/dev/null || echo "")
    CRASH_COUNT=$(cut -d: -f2 "${CRASH_COUNT_FILE}" 2>/dev/null || echo "0")
else
    STORED_DATE=""
    CRASH_COUNT=0
fi

if [[ "${STORED_DATE}" != "${TODAY}" ]]; then
    CRASH_COUNT=0
fi

# Check if we've exceeded crash limit
if [[ ${CRASH_COUNT} -ge ${MAX_CRASHES_PER_DAY} ]]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) HALTED: ${AGENT} exceeded ${MAX_CRASHES_PER_DAY} crashes today. Manual restart required." >> "${CRASH_LOG}"

    # Alert via Telegram
    if [[ -n "${BOT_TOKEN:-}" && -n "${CHAT_ID:-}" ]]; then
        curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
            -d chat_id="${CHAT_ID}" \
            -d text="ALERT: ${AGENT} has crashed ${MAX_CRASHES_PER_DAY} times today and has been halted. Run: ./enable-agent.sh ${AGENT} --restart" \
            > /dev/null 2>&1 || true
    fi

    sleep 86400
    exit 1
fi

# Staggered startup delay to avoid simultaneous API hits
DELAY=$(jq -r '.startup_delay // 0' "${AGENT_DIR}/config.json" 2>/dev/null || echo "0")
sleep ${DELAY}

# Session duration: config override, or default 71 hours (255600s)
# /loop crons expire at 72h, so we restart 1h before that
# Set "max_session_seconds" in config.json for testing (e.g. 300)
MAX_SESSION=$(jq -r '.max_session_seconds // 255600' "${AGENT_DIR}/config.json" 2>/dev/null || echo "255600")

# Model override: set "model" in config.json (e.g. "claude-haiku-4-5-20251001")
MODEL_FLAG=""
MODEL=$(jq -r '.model // empty' "${AGENT_DIR}/config.json" 2>/dev/null || echo "")
if [[ -n "${MODEL}" ]]; then
    MODEL_FLAG="--model ${MODEL}"
fi

# Prompts - two distinct variants based on start mode
RESTART_NOTIFY="After setting up crons, send a Telegram message to the user saying you are back online, what session this is, and what you are about to work on."

# STARTUP_PROMPT: used for fresh starts (hard-restart or first-ever launch)
STARTUP_PROMPT="You are starting a new session. Read all bootstrap files listed in CLAUDE.md. Then read config.json and set up your crons using /loop for each entry in the crons array. After crons are set up, immediately run: bash ../../bus/update-heartbeat.sh online to mark yourself as online. ${RESTART_NOTIFY}"

# CONTINUE_PROMPT: used when resuming via --continue (timer refresh or self-restart)
CONTINUE_PROMPT="SESSION CONTINUATION: Your CLI process was restarted with --continue to reload configs. Your full conversation history is preserved. Do the following immediately: 1) Re-read ALL bootstrap files listed in CLAUDE.md. 2) Set up your crons from config.json using /loop (they were lost when the CLI restarted). 3) Check inbox. 4) Update heartbeat. 5) Resume normal operations. ${RESTART_NOTIFY}"

# Force-fresh marker: written by hard-restart.sh to signal a clean slate is needed.
# Without the marker, launchd respawns always use --continue to preserve conversation history.
FORCE_FRESH_MARKER="${BOS_ROOT}/state/heartbeat/${AGENT}.force-fresh"

cd "${AGENT_DIR}"

# Determine start mode
if [[ -f "${FORCE_FRESH_MARKER}" ]]; then
    START_MODE="fresh"
    rm -f "${FORCE_FRESH_MARKER}"
else
    START_MODE="continue"
fi

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Starting ${AGENT} mode=${START_MODE} (session cap: ${MAX_SESSION}s)" >> "${LOG_DIR}/activity.log"

# Write a "booting" heartbeat immediately so other agents know we're alive
HEARTBEAT_DIR="${BOS_ROOT}/state/heartbeat"
mkdir -p "${HEARTBEAT_DIR}"
BOOT_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
printf '{"last_heartbeat":"%s","status":"booting","current_task":"starting %s session","loop_interval":"1m"}\n' "${BOOT_TS}" "${START_MODE}" > "${HEARTBEAT_DIR}/${AGENT}.json"

# Prevent Mac from sleeping while agent runs
caffeinate -is -w $$ &

# Kill any existing tmux session for this agent (stale from previous run)
tmux kill-session -t "${TMUX_SESSION}" 2>/dev/null || true

# LOCAL OVERRIDE PATTERN (upgradeability mechanism)
# Users place custom .md files in agents/{agent}/local/ to add context that
# persists across git pull updates. These override/extend the repo versions.
# .gitignore excludes local/ so user customizations are never clobbered.
# Files are concatenated and passed as --append-system-prompt to Claude.
LOCAL_PROMPT_FILE=""
LOCAL_DIR="${AGENT_DIR}/local"
if [[ -d "${LOCAL_DIR}" ]]; then
    LOCAL_FILES=$(find "${LOCAL_DIR}" -name '*.md' -type f 2>/dev/null | sort)
    if [[ -n "${LOCAL_FILES}" ]]; then
        LOCAL_CONTENT=""
        while IFS= read -r lf; do
            LOCAL_CONTENT="${LOCAL_CONTENT}
--- $(basename "${lf}") ---
$(cat "${lf}")
"
        done <<< "${LOCAL_FILES}"
        LOCAL_PROMPT_FILE="${LOG_DIR}/.local-prompt"
        printf '%s' "${LOCAL_CONTENT}" > "${LOCAL_PROMPT_FILE}"
    fi
fi

# Build the initial launch command based on start mode
if [[ "${START_MODE}" == "fresh" ]]; then
    LAUNCHER="${LOG_DIR}/.launch.sh"
    cat > "${LAUNCHER}" << LAUNCH_SCRIPT
#!/usr/bin/env bash
cd '${AGENT_DIR}'
ARGS=(--dangerously-skip-permissions)
${MODEL_FLAG:+ARGS+=(--model ${MODEL})}
LOCAL_FILE="${LOG_DIR}/.local-prompt"
if [[ -f "\${LOCAL_FILE}" ]]; then
    ARGS+=(--append-system-prompt "\$(cat "\${LOCAL_FILE}")")
fi
exec claude "\${ARGS[@]}" '${STARTUP_PROMPT}'
LAUNCH_SCRIPT
    chmod +x "${LAUNCHER}"
    INITIAL_CMD="bash '${LAUNCHER}'"
else
    INITIAL_CMD="cd '${AGENT_DIR}' && claude --continue --dangerously-skip-permissions ${MODEL_FLAG} '${CONTINUE_PROMPT}'"
fi

# Start claude inside a tmux session
# tmux provides the PTY that claude needs to stay in interactive mode
# where /loop crons can fire. Without a PTY, claude exits immediately.
tmux new-session -d -s "${TMUX_SESSION}" bash
tmux send-keys -t "${TMUX_SESSION}:0.0" "${INITIAL_CMD}" Enter

# Handle external SIGTERM (e.g., launchctl unload) gracefully
graceful_shutdown() {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) SIGTERM received for ${AGENT}" >> "${CRASH_LOG}"
    if tmux has-session -t "${TMUX_SESSION}" 2>/dev/null; then
        tmux send-keys -t "${TMUX_SESSION}:0.0" \
            "SYSTEM SHUTDOWN: SIGTERM received. Session ending in 30 seconds. Save your work NOW." Enter
        sleep 30
        tmux kill-session -t "${TMUX_SESSION}" 2>/dev/null || true
    fi
}
trap graceful_shutdown SIGTERM SIGINT

# Background timer: restart Claude CLI with --continue after MAX_SESSION seconds
(
    while true; do
        sleep ${MAX_SESSION}
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) SESSION_REFRESH after ${MAX_SESSION}s agent=${AGENT}" >> "${CRASH_LOG}"

        if tmux has-session -t "${TMUX_SESSION}" 2>/dev/null; then
            tmux send-keys -t "${TMUX_SESSION}:0.0" C-c
            sleep 1
            tmux send-keys -t "${TMUX_SESSION}:0.0" "/exit" Enter
            sleep 3

            CLAUDE_PID=$(tmux list-panes -t "${TMUX_SESSION}" -F '#{pane_pid}' 2>/dev/null | head -1)
            if [[ -n "$CLAUDE_PID" ]]; then
                pkill -P "$CLAUDE_PID" 2>/dev/null || true
                sleep 2
            fi

            # Kill old fast-checker and start fresh one
            pkill -f "fast-checker.sh ${AGENT} " 2>/dev/null || true
            sleep 1
            if [[ -f "${TEMPLATE_ROOT}/scripts/fast-checker.sh" ]]; then
                bash "${TEMPLATE_ROOT}/scripts/fast-checker.sh" "${AGENT}" "${TMUX_SESSION}" "${AGENT_DIR}" "${TEMPLATE_ROOT}" \
                    >> "${LOG_DIR}/fast-checker.log" 2>&1 &
            fi

            tmux send-keys -t "${TMUX_SESSION}:0.0" \
                "cd '${AGENT_DIR}' && claude --continue --dangerously-skip-permissions ${MODEL_FLAG} '${CONTINUE_PROMPT}'" Enter

            echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Relaunched ${AGENT} with --continue" >> "${LOG_DIR}/activity.log"
        else
            break
        fi
    done
) &
TIMER_PID=$!

# Kill any stale fast-checker for this agent before starting a fresh one.
pkill -f "fast-checker.sh ${AGENT} " 2>/dev/null || true

# Start fast message checker (Telegram + inbox polling every 3s)
FAST_PID=""
FAST_CHECKER="${TEMPLATE_ROOT}/scripts/fast-checker.sh"
if [[ -f "${FAST_CHECKER}" ]]; then
    bash "${FAST_CHECKER}" "${AGENT}" "${TMUX_SESSION}" "${AGENT_DIR}" "${TEMPLATE_ROOT}" \
        >> "${LOG_DIR}/fast-checker.log" 2>&1 &
    FAST_PID=$!
fi

# Wait for the tmux session to end
while tmux has-session -t "${TMUX_SESSION}" 2>/dev/null; do
    # Watchdog: restart fast-checker if it died unexpectedly
    if [[ -n "${FAST_PID:-}" ]] && ! kill -0 "${FAST_PID}" 2>/dev/null; then
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) fast-checker died (pid ${FAST_PID}), restarting" >> "${LOG_DIR}/fast-checker.log"
        bash "${FAST_CHECKER}" "${AGENT}" "${TMUX_SESSION}" "${AGENT_DIR}" "${TEMPLATE_ROOT}" \
            >> "${LOG_DIR}/fast-checker.log" 2>&1 &
        FAST_PID=$!
    fi
    sleep 5
done

EXIT_CODE=0

# If we get here, tmux session ended
kill ${TIMER_PID} 2>/dev/null || true

# Kill fast checker alongside session
if [[ -n "${FAST_PID:-}" ]]; then
    kill "${FAST_PID}" 2>/dev/null || true
fi

# Check for rate limiting
if tail -20 "${LOG_DIR}/stderr.log" 2>/dev/null | grep -qi "rate.limit\|429\|capacity"; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) RATE_LIMITED agent=${AGENT}" >> "${CRASH_LOG}"
    RATE_COUNT=$(grep -c "RATE_LIMITED" "${CRASH_LOG}" 2>/dev/null || echo "0")
    BACKOFF=$((300 * (RATE_COUNT > 3 ? 4 : RATE_COUNT + 1)))
    sleep ${BACKOFF}
    exit 0
fi

# Check if this was a planned refresh or unexpected exit
if tail -1 "${CRASH_LOG}" 2>/dev/null | grep -q "SESSION_REFRESH"; then
    exit 0
fi

# Unexpected exit - claude died or crashed
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) EXIT agent=${AGENT}" >> "${CRASH_LOG}"
echo "${TODAY}:$((CRASH_COUNT + 1))" > "${CRASH_COUNT_FILE}"
exit 1
