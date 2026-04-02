#!/usr/bin/env bash
# generate-pm2.sh — Generate PM2 ecosystem config and start agent (Windows)
# Usage: generate-pm2.sh <agent_name>
#
# Windows equivalent of generate-launchd.sh. Creates a PM2 ecosystem.config.cjs
# and starts the agent process via PM2.

set -euo pipefail

# ── Args ────────────────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
    echo "Usage: generate-pm2.sh <agent_name>" >&2
    exit 1
fi

AGENT="$1"
TEMPLATE_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AGENT_DIR="${TEMPLATE_ROOT}/agents/${AGENT}"
CONFIG_FILE="${AGENT_DIR}/config.json"

# Source platform utilities
source "${TEMPLATE_ROOT}/core/scripts/platform.sh"

# ── Instance ID ─────────────────────────────────────────────────────────────
ENV_FILE="${TEMPLATE_ROOT}/.env"
if [[ -f "${ENV_FILE}" ]]; then
    CRM_INSTANCE_ID=$(grep '^CRM_INSTANCE_ID=' "${ENV_FILE}" | cut -d= -f2)
fi
CRM_INSTANCE_ID="${CRM_INSTANCE_ID:-default}"

# ── Paths ───────────────────────────────────────────────────────────────────
PM2_NAME="crm-${CRM_INSTANCE_ID}-${AGENT}"
CRM_ROOT="${HOME}/.claude-remote/${CRM_INSTANCE_ID}"
LOG_DIR="${CRM_ROOT}/logs/${AGENT}"
CONFIG_DIR="${CRM_ROOT}/config"
ECOSYSTEM_FILE="${CONFIG_DIR}/${PM2_NAME}.ecosystem.config.cjs"
WRAPPER="${TEMPLATE_ROOT}/core/scripts/agent-wrapper.sh"

mkdir -p "${LOG_DIR}" "${CONFIG_DIR}"

# ── Validate agent exists ───────────────────────────────────────────────────
if [[ ! -d "${AGENT_DIR}" ]]; then
    echo "ERROR: Agent directory not found: ${AGENT_DIR}" >&2
    exit 1
fi

# ── Auto-detect PATH ───────────────────────────────────────────────────────
CLAUDE_BIN=$(which claude 2>/dev/null || echo "")
if [[ -z "${CLAUDE_BIN}" ]]; then
    echo "ERROR: 'claude' not found in PATH. Install Claude Code CLI first." >&2
    exit 1
fi
CLAUDE_DIR=$(dirname "${CLAUDE_BIN}")

NODE_BIN=$(which node 2>/dev/null || echo "")
if [[ -z "${NODE_BIN}" ]]; then
    echo "ERROR: 'node' not found in PATH. Install Node.js first." >&2
    exit 1
fi
NODE_DIR=$(dirname "${NODE_BIN}")

# Build PATH with active node + claude + Git Bash toolchain + standard dirs
# IMPORTANT: Do NOT glob all nvm/fnm versions — only the currently active one.
PM2_PATH="${NODE_DIR}:${CLAUDE_DIR}:/usr/local/bin:/usr/bin:/bin"

# On Windows, include the Git Bash/MSYS2 toolchain so bash, jq, curl, stat,
# date, mv etc. resolve when PM2 resurrects outside an interactive shell.
BASH_BIN=$(which bash 2>/dev/null || echo "")
if [[ -n "${BASH_BIN}" ]]; then
    BASH_DIR=$(dirname "${BASH_BIN}")
    PM2_PATH="${BASH_DIR}:${PM2_PATH}"
fi
# Also include Git's usr/bin which has most GNU utilities
GIT_BIN=$(which git 2>/dev/null || echo "")
if [[ -n "${GIT_BIN}" ]]; then
    GIT_USR_BIN="$(dirname "$(dirname "${GIT_BIN}")")/usr/bin"
    [[ -d "${GIT_USR_BIN}" ]] && PM2_PATH="${GIT_USR_BIN}:${PM2_PATH}"
fi

# Include pyenv shims if present
[[ -d "${HOME}/.pyenv/shims" ]] && PM2_PATH="${HOME}/.pyenv/shims:${PM2_PATH}"

# ── Create inject queue directories (using platform.sh helper for NTFS hardening) ──
INJECT_DIR="$(get_inject_dir "${CRM_ROOT}" "${AGENT}")"
INJECT_PROCESSED="${INJECT_DIR}/processed"
mkdir -p "${INJECT_PROCESSED}"
chmod 700 "${INJECT_PROCESSED}"
# get_inject_dir already handles chmod + icacls on the parent inject dir

# ── Generate ecosystem.config.cjs ──────────────────────────────────────────
# PM2 runs on Node.js which needs Windows-native paths for cwd, out_file,
# error_file. Script args stay POSIX since they're passed to bash.

# Escape single quotes for safe JS string interpolation (e.g., O'Brien → O\'Brien)
esc() { printf '%s' "$1" | sed "s/'/\\\\'/g"; }

# Convert POSIX paths to Windows for PM2 (Node.js) consumption
# /c/Users/steve → C:/Users/steve (forward slashes work in Node.js)
win() { printf '%s' "$1" | sed 's|^/\([a-zA-Z]\)/|\U\1:/|'; }

cat > "${ECOSYSTEM_FILE}" <<ENDCONFIG
module.exports = {
  apps: [{
    name: '$(esc "${PM2_NAME}")',
    script: 'bash',
    args: ['$(esc "${WRAPPER}")', '$(esc "${AGENT}")', '$(esc "${TEMPLATE_ROOT}")'],
    cwd: '$(esc "$(win "${AGENT_DIR}")")',
    autorestart: true,
    max_restarts: 10,
    restart_delay: 10000,
    out_file: '$(esc "$(win "${LOG_DIR}")")/stdout.log',
    error_file: '$(esc "$(win "${LOG_DIR}")")/stderr.log',
    merge_logs: true,
    env: {
      PATH: '$(esc "${PM2_PATH}")',
      HOME: '$(esc "$(win "${HOME}")")',
      CRM_AGENT_NAME: '$(esc "${AGENT}")',
      CRM_INSTANCE_ID: '$(esc "${CRM_INSTANCE_ID}")',
      CRM_ROOT: '$(esc "${CRM_ROOT}")',
      CRM_TEMPLATE_ROOT: '$(esc "${TEMPLATE_ROOT}")'
    }
  }]
};
ENDCONFIG

echo "Generated: ${ECOSYSTEM_FILE}"

# ── Stop existing process if running ───────────────────────────────────────
pm2 stop "${PM2_NAME}" 2>/dev/null || true
pm2 delete "${PM2_NAME}" 2>/dev/null || true

# ── Start agent via PM2 ───────────────────────────────────────────────────
pm2 start "${ECOSYSTEM_FILE}"

# ── Save PM2 state (survives reboots if pm2-startup configured) ────────────
pm2 save

# ── Status summary ─────────────────────────────────────────────────────────
echo ""
echo "=== PM2 Agent Started ==="
echo "  Agent      : ${AGENT}"
echo "  Instance   : ${CRM_INSTANCE_ID}"
echo "  PM2 Name   : ${PM2_NAME}"
echo "  Config     : ${ECOSYSTEM_FILE}"
echo "  Logs       : ${LOG_DIR}/"
echo "  Inject Dir : ${INJECT_DIR}/"
echo "  Wrapper    : ${WRAPPER}"
echo ""
echo "Useful commands:"
echo "  pm2 logs ${PM2_NAME}     — tail logs"
echo "  pm2 stop ${PM2_NAME}     — stop agent"
echo "  pm2 restart ${PM2_NAME}  — restart agent"
echo "  pm2 delete ${PM2_NAME}   — remove from PM2"
echo "=========================="
