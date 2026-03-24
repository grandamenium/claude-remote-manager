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
# User can attach to any agent: tmux attach -t crm-<instance>-<agent_name>
#
# NOTE: --dangerously-skip-permissions is required for headless mode.
# Agent boundaries are enforced via CLAUDE.md instructions, not CLI permissions.

set -euo pipefail

AGENT="$1"
TEMPLATE_ROOT="$2"

# Load instance ID from repo .env or environment
REPO_ENV="${TEMPLATE_ROOT}/.env"
if [[ -f "${REPO_ENV}" ]]; then
    CRM_INSTANCE_ID=$(grep '^CRM_INSTANCE_ID=' "${REPO_ENV}" | cut -d= -f2)
fi
CRM_INSTANCE_ID="${CRM_INSTANCE_ID:-default}"

CRM_ROOT="${HOME}/.claude-remote/${CRM_INSTANCE_ID}"
AGENT_DIR="${TEMPLATE_ROOT}/agents/${AGENT}"
LOG_DIR="${CRM_ROOT}/logs/${AGENT}"
CRASH_LOG="${LOG_DIR}/crashes.log"
CRASH_COUNT_FILE="${LOG_DIR}/.crash_count_today"
MAX_CRASHES_PER_DAY=3
TMUX_SESSION="crm-${CRM_INSTANCE_ID}-${AGENT}"

mkdir -p "${LOG_DIR}"

# Source environment file if it exists (for bot tokens, API keys, etc.)
ENV_FILE="${AGENT_DIR}/.env"
if [[ -f "${ENV_FILE}" ]]; then
    set -a
    source "${ENV_FILE}"
    set +a
fi

# Agents get their environment from .env files only (no shell profile sourcing for security)

export CRM_AGENT_NAME="${AGENT}"
export CRM_INSTANCE_ID="${CRM_INSTANCE_ID}"
export CRM_ROOT="${CRM_ROOT}"
export CRM_TEMPLATE_ROOT="${TEMPLATE_ROOT}"

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

# Working directory override: set "working_directory" in config.json to launch
# Claude Code in a different project directory. The agent's identity (CLAUDE.md,
# settings.json, .env) stays centralized here; only the cwd changes.
WORK_DIR=$(jq -r '.working_directory // empty' "${AGENT_DIR}/config.json" 2>/dev/null || echo "")
LAUNCH_DIR="${AGENT_DIR}"
EXTRA_FLAGS=()

if [[ -n "${WORK_DIR}" ]]; then
    if [[ ! -d "${WORK_DIR}" ]]; then
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ERROR: working_directory '${WORK_DIR}' does not exist" >&2
        exit 1
    fi
    LAUNCH_DIR="${WORK_DIR}"
    # Inject agent identity into system prompt (since we're not in AGENT_DIR).
    # NOTE: Only CLAUDE.md is injected here. If the agent has additional bootstrap
    # files (SOUL.md, GOALS.md, skills, etc.), CLAUDE.md should reference them using
    # @import syntax (e.g., @SOUL.md, @GOALS.md) so they are loaded automatically.
    # The --add-dir flag below gives Claude access to read these files from AGENT_DIR.
    EXTRA_FLAGS+=(--append-system-prompt-file "${AGENT_DIR}/CLAUDE.md")
    # Merge settings: project settings as base, CRM agent settings take precedence.
    # This preserves the target project's hooks/permissions while overlaying agent-specific config.
    AGENT_SETTINGS="${AGENT_DIR}/.claude/settings.json"
    PROJECT_SETTINGS="${LAUNCH_DIR}/.claude/settings.json"
    if [[ -f "${AGENT_SETTINGS}" ]]; then
        if [[ -f "${PROJECT_SETTINGS}" ]]; then
            # Merge: project as base, agent settings override
            MERGED_SETTINGS="${LOG_DIR}/.merged-settings.json"
            python3 -c "
import json, sys
base = json.load(open(sys.argv[1]))
override = json.load(open(sys.argv[2]))
def deep_merge(b, o):
    result = dict(b)
    for k, v in o.items():
        if k in result and isinstance(result[k], dict) and isinstance(v, dict):
            result[k] = deep_merge(result[k], v)
        elif k in result and isinstance(result[k], list) and isinstance(v, list):
            result[k] = result[k] + [x for x in v if x not in result[k]]
        else:
            result[k] = v
    return result
json.dump(deep_merge(base, override), open(sys.argv[3], 'w'), indent=2)
" "${PROJECT_SETTINGS}" "${AGENT_SETTINGS}" "${MERGED_SETTINGS}" 2>/dev/null
            if [[ -f "${MERGED_SETTINGS}" ]]; then
                EXTRA_FLAGS+=(--settings "${MERGED_SETTINGS}")
            else
                # Fallback to agent settings only if merge fails
                EXTRA_FLAGS+=(--settings "${AGENT_SETTINGS}")
            fi
        else
            EXTRA_FLAGS+=(--settings "${AGENT_SETTINGS}")
        fi
    fi
    # Give agent access to central repo for bus scripts, config, etc.
    EXTRA_FLAGS+=(--add-dir "${TEMPLATE_ROOT}")
fi

# Prompts - two distinct variants based on start mode
RESTART_NOTIFY="After setting up crons, send a Telegram message to the user saying you are back online, what session this is, and what you are about to work on."

# STARTUP_PROMPT: used for fresh starts (hard-restart or first-ever launch)
STARTUP_PROMPT="You are starting a new session. Read all bootstrap files listed in CLAUDE.md. Then read config.json and set up your crons using /loop for each entry in the crons array. ${RESTART_NOTIFY}"

# CONTINUE_PROMPT: used when resuming via --continue (timer refresh or self-restart)
CONTINUE_PROMPT="SESSION CONTINUATION: Your CLI process was restarted with --continue to reload configs. Your full conversation history is preserved. Do the following immediately: 1) Re-read ALL bootstrap files listed in CLAUDE.md. 2) Set up your crons from config.json using /loop (they were lost when the CLI restarted). 3) Check inbox. 4) Resume normal operations. ${RESTART_NOTIFY}"

# Force-fresh marker: written by hard-restart.sh to signal a clean slate is needed.
# Without the marker, launchd respawns always use --continue to preserve conversation history.
FORCE_FRESH_MARKER="${CRM_ROOT}/state/${AGENT}.force-fresh"

cd "${LAUNCH_DIR}"

# Determine start mode
# Check if there's actually a conversation to continue by looking for .jsonl files
# in Claude's project conversation directory (based on the actual launch directory).
CONV_DIR="${HOME}/.claude/projects/-$(echo "${LAUNCH_DIR}" | tr '/' '-')"
HAS_CONVERSATION=false
if [[ -d "${CONV_DIR}" ]] && ls "${CONV_DIR}"/*.jsonl &>/dev/null; then
    HAS_CONVERSATION=true
fi

if [[ -f "${FORCE_FRESH_MARKER}" ]]; then
    START_MODE="fresh"
    rm -f "${FORCE_FRESH_MARKER}"
elif [[ "${HAS_CONVERSATION}" == "false" ]]; then
    START_MODE="fresh"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) No conversation found for ${AGENT}, using fresh start" >> "${LOG_DIR}/activity.log"
else
    START_MODE="continue"
fi

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Starting ${AGENT} mode=${START_MODE} (session cap: ${MAX_SESSION}s)" >> "${LOG_DIR}/activity.log"

# Register skills/commands as Telegram bot / autocomplete commands
if [[ -n "${BOT_TOKEN:-}" ]]; then
    REGISTER_SCRIPT="${TEMPLATE_ROOT}/core/scripts/register-telegram-commands.sh"
    if [[ -f "${REGISTER_SCRIPT}" ]]; then
        bash "${REGISTER_SCRIPT}" "${BOT_TOKEN}" "${LAUNCH_DIR}" "${AGENT_DIR}" \
            >> "${LOG_DIR}/activity.log" 2>&1 || true
    fi
fi

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

# Serialize EXTRA_FLAGS for use in generated scripts and tmux commands
EXTRA_FLAGS_STR=""
for flag in "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}"; do
    EXTRA_FLAGS_STR+=" '${flag}'"
done

# Build the initial launch command based on start mode
if [[ "${START_MODE}" == "fresh" ]]; then
    LAUNCHER="${LOG_DIR}/.launch.sh"
    cat > "${LAUNCHER}" << LAUNCH_SCRIPT
#!/usr/bin/env bash
cd '${LAUNCH_DIR}'
ARGS=(--dangerously-skip-permissions)
${MODEL_FLAG:+ARGS+=(--model ${MODEL})}
LOCAL_FILE="${LOG_DIR}/.local-prompt"
if [[ -f "\${LOCAL_FILE}" ]]; then
    ARGS+=(--append-system-prompt "\$(cat "\${LOCAL_FILE}")")
fi
EXTRA=(${EXTRA_FLAGS_STR})
ARGS+=("\${EXTRA[@]+"\${EXTRA[@]}"}")
exec claude "\${ARGS[@]}" '${STARTUP_PROMPT}'
LAUNCH_SCRIPT
    chmod +x "${LAUNCHER}"
    INITIAL_CMD="bash '${LAUNCHER}'"
else
    INITIAL_CMD="cd '${LAUNCH_DIR}' && claude --continue --dangerously-skip-permissions ${MODEL_FLAG}${EXTRA_FLAGS_STR} '${CONTINUE_PROMPT}'"
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
            if [[ -f "${TEMPLATE_ROOT}/core/scripts/fast-checker.sh" ]]; then
                bash "${TEMPLATE_ROOT}/core/scripts/fast-checker.sh" "${AGENT}" "${TMUX_SESSION}" "${AGENT_DIR}" "${TEMPLATE_ROOT}" \
                    >> "${LOG_DIR}/fast-checker.log" 2>&1 &
            fi

            tmux send-keys -t "${TMUX_SESSION}:0.0" \
                "cd '${LAUNCH_DIR}' && claude --continue --dangerously-skip-permissions ${MODEL_FLAG}${EXTRA_FLAGS_STR} '${CONTINUE_PROMPT}'" Enter

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
FAST_CHECKER="${TEMPLATE_ROOT}/core/scripts/fast-checker.sh"
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
