#!/usr/bin/env bash
# hook-heartbeat.sh - PostToolUse hook that writes a heartbeat timestamp
# Used by fast-checker for reliable freeze detection instead of tmux pane inspection.
# Writes: ~/.claude-remote/<instance>/state/<agent>.heartbeat with epoch seconds.

set -o pipefail

# Resolve agent name from CWD (agents/<name>/...)
AGENT_NAME=$(basename "$(pwd)")
# If we're in a subdirectory, walk up to find the agent dir
if [[ ! -f "config.json" ]]; then
    AGENT_NAME=$(basename "$(dirname "$(pwd)")")
fi

# Load instance ID
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ENV="${SCRIPT_DIR}/../../.env"
CRM_INSTANCE_ID="default"
if [[ -f "${REPO_ENV}" ]]; then
    CRM_INSTANCE_ID=$(grep '^CRM_INSTANCE_ID=' "${REPO_ENV}" 2>/dev/null | cut -d= -f2)
    CRM_INSTANCE_ID="${CRM_INSTANCE_ID:-default}"
fi

HEARTBEAT_FILE="${HOME}/.claude-remote/${CRM_INSTANCE_ID}/state/${AGENT_NAME}.heartbeat"
mkdir -p "$(dirname "$HEARTBEAT_FILE")"
date +%s > "$HEARTBEAT_FILE"
