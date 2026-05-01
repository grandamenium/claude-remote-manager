#!/usr/bin/env bash
# hard-restart.sh — Kill and relaunch an agent (new session, no conversation history)
#
# Usage: bash ../../core/bus/hard-restart.sh --reason "why"
#
# Use this when the session is corrupted, context is exhausted, or you need a
# truly fresh start. For normal restarts that preserve conversation history,
# use self-restart.sh instead.
#
# Cross-platform: delegates to platform.sh's restart_agent_hard() abstraction
# (launchctl on macOS, PM2 on Windows). Conventionally invoked from inside an
# agent's directory so AGENT can be inferred from $(pwd).

set -euo pipefail

AGENT="$(basename "$(pwd)")"
TEMPLATE_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# shellcheck source=/dev/null
source "${TEMPLATE_ROOT}/core/scripts/platform.sh"

CRM_INSTANCE_ID="$(load_instance_id "${TEMPLATE_ROOT}/.env")"
CRM_INSTANCE_ID="${CRM_INSTANCE_ID:-default}"
CRM_ROOT="${CRM_ROOT:-${HOME}/.claude-remote/${CRM_INSTANCE_ID}}"

REASON="$(parse_reason "$@")"
# Sanitize: strip newlines/CR to prevent log forging
REASON="$(printf '%s' "$REASON" | tr -d '\n\r')"

restart_agent_hard "$CRM_INSTANCE_ID" "$AGENT" "$CRM_ROOT" "$REASON"
