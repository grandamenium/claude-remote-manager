#!/usr/bin/env bash
# hard-restart.sh - Kill and relaunch an agent (new session, no conversation history)
# Usage: bash ../../bus/hard-restart.sh --reason "why"
#
# Use this when the session is corrupted, context is exhausted, or you
# need a truly fresh start. For normal restarts, use self-restart.sh instead.

set -euo pipefail

AGENT="$(basename "$(pwd)")"
TEMPLATE_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Load instance ID
REPO_ENV="${TEMPLATE_ROOT}/.env"
if [[ -f "${REPO_ENV}" ]]; then
    CRM_INSTANCE_ID=$(grep '^CRM_INSTANCE_ID=' "${REPO_ENV}" | cut -d= -f2)
fi
CRM_INSTANCE_ID="${CRM_INSTANCE_ID:-default}"
CRM_ROOT="${CRM_ROOT:-${HOME}/.claude-remote/${CRM_INSTANCE_ID}}"

PLIST="${HOME}/Library/LaunchAgents/com.claude-remote.${CRM_INSTANCE_ID}.${AGENT}.plist"
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

# Send Telegram notification before restart (if credentials available)
if [[ -n "${BOT_TOKEN:-}" && -n "${CHAT_ID:-}" ]]; then
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="${CHAT_ID}" \
        -d text="Restarting ${AGENT}: ${REASON}" \
        > /dev/null 2>&1 || true
fi

if [[ ! -f "${PLIST}" ]]; then
    echo "ERROR: No launchd plist found for ${AGENT} at ${PLIST}" >&2
    exit 1
fi

# Log the restart
LOG_DIR="${CRM_ROOT}/logs/${AGENT}"
mkdir -p "${LOG_DIR}"
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Hard-restart triggered. Reason: ${REASON}" >> "${LOG_DIR}/restarts.log"

# Reset crash counter so launchd doesn't throttle
rm -f "${LOG_DIR}/.crash_count_today"

# Write force-fresh marker so agent-wrapper.sh uses STARTUP_PROMPT (no --continue)
mkdir -p "${CRM_ROOT}/state"
touch "${CRM_ROOT}/state/${AGENT}.force-fresh"

# Clear context tracking state so new session starts fresh
rm -f "${CRM_ROOT}/state/${AGENT}.session-start"

# Detach a subprocess to perform the restart after a short delay.
# Use kickstart -k (kill + restart) which is atomic and reliable on modern macOS.
# Falls back to bootstrap if kickstart fails, and unload/load as last resort.
DOMAIN_TARGET="gui/$(id -u)/com.claude-remote.${CRM_INSTANCE_ID}.${AGENT}"
SERVICE_TARGET="com.claude-remote.${CRM_INSTANCE_ID}.${AGENT}"
nohup bash -c "
    sleep 10
    # Method 1: kickstart -k (most reliable — atomic kill+restart)
    if launchctl kickstart -k '${DOMAIN_TARGET}' 2>>'${LOG_DIR}/restarts.log'; then
        echo '[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Restarted via kickstart -k' >> '${LOG_DIR}/restarts.log'
    else
        echo '[$(date -u +%Y-%m-%dT%H:%M:%SZ)] kickstart failed, trying bootout/bootstrap' >> '${LOG_DIR}/restarts.log'
        # Method 2: bootout + bootstrap (modern replacement for unload/load)
        launchctl bootout '${DOMAIN_TARGET}' 2>>'${LOG_DIR}/restarts.log' || true
        sleep 2
        if launchctl bootstrap 'gui/$(id -u)' '${PLIST}' 2>>'${LOG_DIR}/restarts.log'; then
            echo '[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Restarted via bootstrap' >> '${LOG_DIR}/restarts.log'
        else
            echo '[$(date -u +%Y-%m-%dT%H:%M:%SZ)] bootstrap failed, trying legacy unload/load' >> '${LOG_DIR}/restarts.log'
            # Method 3: legacy unload/load (last resort)
            launchctl unload '${PLIST}' 2>/dev/null || true
            sleep 1
            launchctl load '${PLIST}' 2>>'${LOG_DIR}/restarts.log'
        fi
    fi
" >> "${LOG_DIR}/restarts.log" 2>&1 &
disown

# Post-restart verification: check if agent comes back within 2 minutes
nohup bash -c "
    sleep 90
    TMUX_NAME='crm-${CRM_INSTANCE_ID}-${AGENT}'
    if tmux has-session -t \"\${TMUX_NAME}\" 2>/dev/null; then
        PANE_CONTENT=\$(tmux capture-pane -t \"\${TMUX_NAME}:0.0\" -p 2>/dev/null | tail -10)
        if echo \"\$PANE_CONTENT\" | grep -qE 'permissions|bypass|❯'; then
            if [[ -n '${BOT_TOKEN:-}' && -n '${CHAT_ID:-}' ]]; then
                curl -s -X POST 'https://api.telegram.org/bot${BOT_TOKEN}/sendMessage' \
                    -d chat_id='${CHAT_ID}' \
                    -d text='${AGENT} is back online.' \
                    > /dev/null 2>&1 || true
            fi
            echo '[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Post-restart verification PASSED' >> '${LOG_DIR}/restarts.log'
        else
            echo '[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Post-restart verification: tmux exists but agent not ready yet' >> '${LOG_DIR}/restarts.log'
        fi
    else
        if [[ -n '${BOT_TOKEN:-}' && -n '${CHAT_ID:-}' ]]; then
            curl -s -X POST 'https://api.telegram.org/bot${BOT_TOKEN}/sendMessage' \
                -d chat_id='${CHAT_ID}' \
                -d text='ALERT: ${AGENT} FAILED to restart. Manual intervention needed.' \
                > /dev/null 2>&1 || true
        fi
        echo '[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Post-restart verification FAILED: no tmux session' >> '${LOG_DIR}/restarts.log'
    fi
" >> "${LOG_DIR}/restarts.log" 2>&1 &
disown

echo "Hard-restart scheduled for ${AGENT} in ~10 seconds. New session will start fresh."
