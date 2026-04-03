#!/usr/bin/env bash
# hook-post-commit-verify.sh - PostToolUse hook for Bash commands
# Detects git push to main/master and launches a background verification watcher.
# The watcher checks Railway deploy logs for errors and alerts Josh via Telegram.

set -o pipefail

INPUT=$(cat)

# Only trigger on Bash tool calls that include "git push"
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)
if [[ "$TOOL_NAME" != "Bash" ]]; then
    exit 0
fi

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)
if ! echo "$COMMAND" | grep -qE 'git\s+push'; then
    exit 0
fi

# Resolve agent name and paths
AGENT_NAME=$(basename "$(pwd)")
if [[ ! -f "config.json" ]]; then
    AGENT_NAME=$(basename "$(dirname "$(pwd)")")
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ENV="${SCRIPT_DIR}/../../.env"
CRM_INSTANCE_ID="default"
if [[ -f "${REPO_ENV}" ]]; then
    CRM_INSTANCE_ID=$(grep '^CRM_INSTANCE_ID=' "${REPO_ENV}" 2>/dev/null | cut -d= -f2)
    CRM_INSTANCE_ID="${CRM_INSTANCE_ID:-default}"
fi

CRM_ROOT="${HOME}/.claude-remote/${CRM_INSTANCE_ID}"
LOG_FILE="${CRM_ROOT}/logs/${AGENT_NAME}/post-commit-verify.log"
mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [post-commit-verify/${AGENT_NAME}] $1" >> "$LOG_FILE"
}

# Detect which repo was pushed (from git remote)
REPO_NAME=$(git remote get-url origin 2>/dev/null | sed 's|.*/||;s|\.git$||' || echo "unknown")

log "Detected git push by ${AGENT_NAME} in repo ${REPO_NAME}"
log "Command: ${COMMAND}"

# Map repo to Railway service URL for health check
declare -A HEALTH_URLS
HEALTH_URLS=(
    ["clearpath"]="https://clearpath-production-c86d.up.railway.app"
    ["lifecycle-killer"]="https://lifecycle-killer-production.up.railway.app"
    ["nonprofit-hub"]="https://nonprofit-hub-production.up.railway.app"
)

HEALTH_URL="${HEALTH_URLS[$REPO_NAME]:-}"

if [[ -z "$HEALTH_URL" ]]; then
    log "No health URL mapped for repo ${REPO_NAME} — skipping verification"
    exit 0
fi

# Load Telegram token for alerts
ENV_FILE="${SCRIPT_DIR}/../../agents/${AGENT_NAME}/.env"
TELEGRAM_TOKEN=""
if [[ -f "$ENV_FILE" ]]; then
    TELEGRAM_TOKEN=$(grep '^TELEGRAM_BOT_TOKEN=' "$ENV_FILE" 2>/dev/null | cut -d= -f2)
fi
# Fallback to frank's token
if [[ -z "$TELEGRAM_TOKEN" ]] && [[ -f "${SCRIPT_DIR}/../../agents/frank/.env" ]]; then
    TELEGRAM_TOKEN=$(grep '^TELEGRAM_BOT_TOKEN=' "${SCRIPT_DIR}/../../agents/frank/.env" 2>/dev/null | cut -d= -f2)
fi

JOSH_CHAT_ID="6690120787"

send_alert() {
    local msg="$1"
    if [[ -n "$TELEGRAM_TOKEN" ]]; then
        curl -sf -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
            -H "Content-Type: application/json" \
            -d "$(jq -n -c --arg cid "$JOSH_CHAT_ID" --arg txt "$msg" '{chat_id: $cid, text: $txt, parse_mode: "Markdown"}')" \
            > /dev/null 2>&1
    fi
    log "ALERT: $msg"
}

# Launch background verification (non-blocking)
(
    CHECKS=6          # check every 2.5 min for 15 min
    INTERVAL=150      # seconds between checks
    FAILURES=0
    LAST_STATUS=""

    # Wait 60s for Railway to start deploying
    sleep 60

    for i in $(seq 1 $CHECKS); do
        HTTP_STATUS=$(curl -sf -o /dev/null -w '%{http_code}' --max-time 10 "$HEALTH_URL" 2>/dev/null || echo "000")

        if [[ "$HTTP_STATUS" =~ ^[45] ]] || [[ "$HTTP_STATUS" == "000" ]]; then
            FAILURES=$((FAILURES + 1))
            LAST_STATUS="$HTTP_STATUS"
            log "Check ${i}/${CHECKS}: ${HEALTH_URL} returned ${HTTP_STATUS} (failure #${FAILURES})"
        else
            log "Check ${i}/${CHECKS}: ${HEALTH_URL} returned ${HTTP_STATUS} (ok)"
            # Reset failure count on success
            FAILURES=0
        fi

        # Alert after 2 consecutive failures
        if (( FAILURES >= 2 )); then
            send_alert "Deploy alert: *${REPO_NAME}* pushed by ${AGENT_NAME} may be broken. ${HEALTH_URL} returning ${LAST_STATUS} after ${FAILURES} consecutive checks."
            break
        fi

        if (( i < CHECKS )); then
            sleep $INTERVAL
        fi
    done

    if (( FAILURES == 0 )); then
        log "Verification passed: ${REPO_NAME} healthy after deploy by ${AGENT_NAME}"
    fi
) &

log "Background verification watcher launched (PID $!)"
exit 0
