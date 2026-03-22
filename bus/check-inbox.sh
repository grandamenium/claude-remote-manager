#!/usr/bin/env bash
# check-inbox.sh - Check and process messages in this agent's inbox
# Usage: check-inbox.sh
# Outputs JSON array of messages, moves to inflight (awaiting ACK)
# Messages are ACK'd via ack-inbox.sh or auto-ACK'd on reply (send-message.sh)
# Stale inflight messages (>5 min) are recovered back to inbox for re-delivery

set -euo pipefail

BOS_ROOT="${BOS_ROOT:-${HOME}/.business-os}"
BOS_AGENT_NAME="$(basename "$(pwd)")"
ME="${BOS_AGENT_NAME}"
INBOX_DIR="${BOS_ROOT}/inbox/${ME}"
INFLIGHT_DIR="${BOS_ROOT}/inflight/${ME}"

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
    FILE_MTIME=$(stat -f %m "${inflight_file}" 2>/dev/null || echo "${NOW_EPOCH}")
    AGE=$(( NOW_EPOCH - FILE_MTIME ))
    if [[ ${AGE} -gt ${STALE_THRESHOLD} ]]; then
        BASENAME=$(basename "${inflight_file}")
        mv "${inflight_file}" "${INBOX_DIR}/${BASENAME}"
    fi
done

# Collect messages sorted by priority then timestamp
MESSAGES=()
for msg_file in $(ls -1 "${INBOX_DIR}"/*.json 2>/dev/null | sort); do
    if jq empty "${msg_file}" 2>/dev/null; then
        MESSAGES+=("${msg_file}")
    else
        mkdir -p "${INBOX_DIR}/.errors"
        mv "${msg_file}" "${INBOX_DIR}/.errors/"
    fi
done

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
