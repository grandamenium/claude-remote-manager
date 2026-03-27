#!/usr/bin/env bash
# install.sh - Create the ~/.claude-remote/{instance-id}/ state directories
# Usage: install.sh [instance-id]

set -euo pipefail

# Dependency checks
MISSING=""
command -v tmux >/dev/null 2>&1 || MISSING="${MISSING} tmux"
command -v jq >/dev/null 2>&1 || MISSING="${MISSING} jq"
command -v claude >/dev/null 2>&1 || MISSING="${MISSING} claude"

if [[ -n "$MISSING" ]]; then
    echo "ERROR: Missing required dependencies:${MISSING}"
    echo ""
    [[ "$MISSING" == *"tmux"* ]] && echo "  tmux:   brew install tmux"
    [[ "$MISSING" == *"jq"* ]] && echo "  jq:     brew install jq"
    [[ "$MISSING" == *"claude"* ]] && echo "  claude: https://docs.anthropic.com/en/docs/claude-code"
    echo ""
    echo "Install the missing dependencies and run this again."
    exit 1
fi

# Check that claude is authenticated (must have been run interactively at least once)
if ! claude --version >/dev/null 2>&1; then
    echo "ERROR: Claude CLI is installed but may not be set up."
    echo "  Run 'claude' in a terminal first to accept terms and log in."
    echo "  Once that works, run this again."
    exit 1
fi

TEMPLATE_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Get instance ID from argument, .env, or default
if [[ -n "${1:-}" ]]; then
    CRM_INSTANCE_ID="$1"
elif [[ -f "${TEMPLATE_ROOT}/.env" ]]; then
    CRM_INSTANCE_ID=$(grep '^CRM_INSTANCE_ID=' "${TEMPLATE_ROOT}/.env" | cut -d= -f2 || echo "default")
else
    CRM_INSTANCE_ID="default"
fi

CRM_ROOT="${HOME}/.claude-remote/${CRM_INSTANCE_ID}"

echo "========================================="
echo "  Claude Remote Manager - Installation"
echo "========================================="
echo ""
echo "  Instance ID: ${CRM_INSTANCE_ID}"
echo "  State dir:   ${CRM_ROOT}"
echo ""

# Check if already installed
if [[ -d "${CRM_ROOT}" ]]; then
    echo "Directory ${CRM_ROOT} already exists."
    echo "This instance appears to be already installed."
    echo ""
    echo "To reinstall, remove it first: rm -rf ${CRM_ROOT}"
    echo "Or choose a different instance ID: ./install.sh <new-id>"
    exit 1
fi

echo "Creating directory structure..."

# Core state directories (700 = owner-only access)
mkdir -p "${CRM_ROOT}" && chmod 700 "${CRM_ROOT}"
mkdir -p "${CRM_ROOT}/config" && chmod 700 "${CRM_ROOT}/config"
mkdir -p "${CRM_ROOT}/state" && chmod 700 "${CRM_ROOT}/state"
mkdir -p "${CRM_ROOT}/inbox" && chmod 700 "${CRM_ROOT}/inbox"
mkdir -p "${CRM_ROOT}/outbox" && chmod 700 "${CRM_ROOT}/outbox"
mkdir -p "${CRM_ROOT}/processed" && chmod 700 "${CRM_ROOT}/processed"
mkdir -p "${CRM_ROOT}/inflight" && chmod 700 "${CRM_ROOT}/inflight"
mkdir -p "${CRM_ROOT}/logs" && chmod 700 "${CRM_ROOT}/logs"

# Initialize enabled-agents.json (empty - agents added via setup.sh)
cat > "${CRM_ROOT}/config/enabled-agents.json" << 'EOF'
{}
EOF

# Write .env to repo root (only if it doesn't already exist, to preserve custom config)
if [[ ! -f "${TEMPLATE_ROOT}/.env" ]]; then
    cat > "${TEMPLATE_ROOT}/.env" << EOF
CRM_INSTANCE_ID=${CRM_INSTANCE_ID}
CRM_ROOT=${CRM_ROOT}
EOF
fi

# Make all scripts executable
chmod +x "${TEMPLATE_ROOT}/"*.sh 2>/dev/null || true
chmod +x "${TEMPLATE_ROOT}/core/scripts/"*.sh 2>/dev/null || true
chmod +x "${TEMPLATE_ROOT}/core/bus/"*.sh 2>/dev/null || true

echo ""
echo "========================================="
echo "  Installation complete"
echo "========================================="
echo ""
echo "  State directory: ${CRM_ROOT}"
echo "  Instance ID:     ${CRM_INSTANCE_ID}"
echo "  .env written:    ${TEMPLATE_ROOT}/.env"
echo ""
echo "  Next step: Run ./setup.sh to create your first agent"
echo ""
