#!/usr/bin/env bash
# ack-inbox.sh - Acknowledge a processed message (moves from inflight to processed)
# Usage: ack-inbox.sh <msg_id>
# Idempotent: exits 0 if message already processed or not found.

set -euo pipefail

BOS_ROOT="${BOS_ROOT:-${HOME}/.business-os}"
BOS_AGENT_NAME="$(basename "$(pwd)")"
ME="${BOS_AGENT_NAME}"

MSG_ID="${1:-}"
if [[ -z "${MSG_ID}" ]]; then
    echo "Usage: ack-inbox.sh <msg_id>" >&2
    exit 1
fi

INFLIGHT_DIR="${BOS_ROOT}/inflight/${ME}"
PROCESSED_DIR="${BOS_ROOT}/processed/${ME}"
mkdir -p "${PROCESSED_DIR}"

# Find the message file in inflight by msg_id
FOUND=""
for f in "${INFLIGHT_DIR}"/*.json; do
    [[ ! -f "$f" ]] && continue
    if [[ "$(basename "$f")" == *"${MSG_ID}"* ]]; then
        FOUND="$f"
        break
    fi
    FILE_ID=$(jq -r '.id // ""' "$f" 2>/dev/null || true)
    if [[ "${FILE_ID}" == "${MSG_ID}" ]]; then
        FOUND="$f"
        break
    fi
done

if [[ -z "${FOUND}" ]]; then
    exit 0
fi

BASENAME=$(basename "${FOUND}")
mv "${FOUND}" "${PROCESSED_DIR}/${BASENAME}"
