#!/usr/bin/env bash
# self-restart.sh — Restart Claude CLI with --continue (preserves conversation)
#
# Usage: bash ../../core/bus/self-restart.sh --reason "why"
#
# Reloads all configs (settings.json, hooks, CLAUDE.md) while preserving the
# full conversation history. Crons need to be re-set up after restart.
#
# For a hard restart (fresh session, no history), use: bash ../../core/bus/hard-restart.sh
#
# Cross-platform: delegates to platform.sh's restart_agent_soft() abstraction
# (tmux send-keys on macOS, PM2 restart on Windows). Conventionally invoked
# from inside an agent's directory so AGENT can be inferred from $(pwd).

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

restart_agent_soft "$CRM_INSTANCE_ID" "$AGENT" "$CRM_ROOT" "$TEMPLATE_ROOT" "$REASON"
