#!/usr/bin/env bash
# generate-launchd.sh - Generate and load a launchd plist for an agent
# Usage: generate-launchd.sh <agent_name>

set -euo pipefail

AGENT="$1"
TEMPLATE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENT_DIR="${TEMPLATE_ROOT}/agents/${AGENT}"
CONFIG_FILE="${AGENT_DIR}/config.json"

# Load instance ID from repo .env
ENV_FILE="${TEMPLATE_ROOT}/.env"
if [[ -f "${ENV_FILE}" ]]; then
    BOS_INSTANCE_ID=$(grep '^BOS_INSTANCE_ID=' "${ENV_FILE}" | cut -d= -f2)
fi
BOS_INSTANCE_ID="${BOS_INSTANCE_ID:-default}"

PLIST_DIR="${HOME}/Library/LaunchAgents"
PLIST_NAME="com.business-os.${BOS_INSTANCE_ID}.${AGENT}"
PLIST_FILE="${PLIST_DIR}/${PLIST_NAME}.plist"
BOS_ROOT="${HOME}/.business-os/${BOS_INSTANCE_ID}"
LOG_DIR="${BOS_ROOT}/logs/${AGENT}"
WRAPPER="${TEMPLATE_ROOT}/scripts/agent-wrapper.sh"

mkdir -p "${PLIST_DIR}" "${LOG_DIR}"

# Auto-detect PATH: find where claude, jq, and python3 live
CLAUDE_BIN=$(which claude 2>/dev/null || echo "")
if [[ -z "${CLAUDE_BIN}" ]]; then
    echo "ERROR: 'claude' not found in PATH. Install Claude Code CLI first." >&2
    exit 1
fi
CLAUDE_DIR=$(dirname "${CLAUDE_BIN}")

# Build PATH with detected dirs + standard system dirs
LAUNCHD_PATH="${CLAUDE_DIR}:/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"

# Also include pyenv, fnm, or other version managers if present
for extra_dir in "${HOME}/.pyenv/shims" "${HOME}/.nvm/versions/node/"*/bin; do
    [[ -d "${extra_dir}" ]] && LAUNCHD_PATH="${extra_dir}:${LAUNCHD_PATH}"
done

# Generate plist
cat > "${PLIST_FILE}" <<ENDPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_NAME}</string>

    <key>ProgramArguments</key>
    <array>
        <string>${WRAPPER}</string>
        <string>${AGENT}</string>
        <string>${TEMPLATE_ROOT}</string>
    </array>

    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>${LOG_DIR}/stdout.log</string>

    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/stderr.log</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>${LAUNCHD_PATH}</string>
        <key>HOME</key>
        <string>${HOME}</string>
        <key>BOS_AGENT_NAME</key>
        <string>${AGENT}</string>
        <key>BOS_INSTANCE_ID</key>
        <string>${BOS_INSTANCE_ID}</string>
        <key>BOS_ROOT</key>
        <string>${BOS_ROOT}</string>
        <key>BOS_TEMPLATE_ROOT</key>
        <string>${TEMPLATE_ROOT}</string>
    </dict>

    <key>WorkingDirectory</key>
    <string>${AGENT_DIR}</string>

    <key>ThrottleInterval</key>
    <integer>10</integer>
</dict>
</plist>
ENDPLIST

echo "Generated: ${PLIST_FILE}"

# Load the plist
launchctl unload "${PLIST_FILE}" 2>/dev/null || true
launchctl load "${PLIST_FILE}"

echo "Loaded: ${PLIST_NAME}"
