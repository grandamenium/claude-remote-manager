#!/usr/bin/env bash
# check-inbox.sh - Check and process messages in this agent's inbox
# Usage: check-inbox.sh
# Outputs JSON array of messages, moves to inflight (awaiting ACK)
# Messages are ACK'd via ack-inbox.sh or auto-ACK'd on reply (send-message.sh)
# Stale inflight messages (>5 min) are recovered back to inbox for re-delivery

set -euo pipefail

# Resolve CRM_ROOT with instance ID
if [[ -z "${CRM_ROOT:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    TEMPLATE_ROOT="${CRM_TEMPLATE_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
    REPO_ENV="${TEMPLATE_ROOT}/.env"
    if [[ -f "${REPO_ENV}" ]]; then
        CRM_INSTANCE_ID=$(grep '^CRM_INSTANCE_ID=' "${REPO_ENV}" | cut -d= -f2)
    fi
    CRM_INSTANCE_ID="${CRM_INSTANCE_ID:-default}"
    CRM_ROOT="${HOME}/.claude-remote/${CRM_INSTANCE_ID}"
fi
CRM_AGENT_NAME="${CRM_AGENT_NAME:-$(basename "$(pwd)")}"
ME="${CRM_AGENT_NAME}"
INBOX_DIR="${CRM_ROOT}/inbox/${ME}"
INFLIGHT_DIR="${CRM_ROOT}/inflight/${ME}"

# Ensure directories exist
mkdir -p "${INBOX_DIR}" "${INFLIGHT_DIR}"

# Use mkdir lock (portable - works on macOS without flock)
LOCK_DIR="${INBOX_DIR}/.lock.d"
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
    LOCK_PID=$(cat "${LOCK_DIR}/pid" 2>/dev/null || echo "0")
    if kill -0 "${LOCK_PID}" 2>/dev/null; then
        echo "[]"
        exit 0
    fi
    rm -rf "${LOCK_DIR}"
    mkdir "${LOCK_DIR}" 2>/dev/null || { echo "[]"; exit 0; }
fi
echo $$ > "${LOCK_DIR}/pid"
trap 'rm -rf "${LOCK_DIR}" 2>/dev/null' EXIT

# Recover stale inflight messages (older than 5 minutes) back to inbox
NOW_EPOCH=$(date +%s)
STALE_THRESHOLD=300
for inflight_file in "${INFLIGHT_DIR}"/*.json; do
    [[ ! -f "${inflight_file}" ]] && continue
    # GNU stat (Linux/Windows Git Bash) uses -c %Y, BSD stat (macOS) uses -f %m
    FILE_MTIME=$(stat -c %Y "${inflight_file}" 2>/dev/null || stat -f %m "${inflight_file}" 2>/dev/null || echo "${NOW_EPOCH}")
    AGE=$(( NOW_EPOCH - FILE_MTIME ))
    if [[ ${AGE} -gt ${STALE_THRESHOLD} ]]; then
        BASENAME=$(basename "${inflight_file}")
        mv "${inflight_file}" "${INBOX_DIR}/${BASENAME}"
    fi
done

# Collect messages sorted by priority then timestamp
MESSAGES=()
while IFS= read -r msg_file || [[ -n "$msg_file" ]]; do
    [[ -z "$msg_file" ]] && continue
    if jq empty "${msg_file}" 2>/dev/null; then
        MESSAGES+=("${msg_file}")
    else
        mkdir -p "${INBOX_DIR}/.errors"
        mv "${msg_file}" "${INBOX_DIR}/.errors/"
    fi
done < <(ls -1 "${INBOX_DIR}"/*.json 2>/dev/null | sort)

if [[ ${#MESSAGES[@]} -eq 0 ]]; then
    echo "[]"
    exit 0
fi

# Move messages to inflight
MOVED_FILES=()
for msg_file in "${MESSAGES[@]}"; do
    BASENAME=$(basename "${msg_file}")
    mv "${msg_file}" "${INFLIGHT_DIR}/${BASENAME}"
    MOVED_FILES+=("${INFLIGHT_DIR}/${BASENAME}")
done

# Build JSON array
OUTPUT="["
FIRST=true
for msg_file in "${MOVED_FILES[@]}"; do
    if [[ "${FIRST}" == "true" ]]; then
        FIRST=false
    else
        OUTPUT+=","
    fi
    CONTENT=$(cat "${msg_file}")
    OUTPUT+="${CONTENT}"
done
OUTPUT+="]"

echo "${OUTPUT}"
