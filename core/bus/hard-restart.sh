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

# Detach a subprocess to perform the restart after a short delay
nohup bash -c "sleep 10 && launchctl unload '${PLIST}' 2>/dev/null; sleep 1 && launchctl load '${PLIST}'" \
    >> "${LOG_DIR}/restarts.log" 2>&1 &
disown

echo "Hard-restart scheduled for ${AGENT} in ~10 seconds. New session will start fresh."
