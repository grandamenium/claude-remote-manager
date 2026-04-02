#!/usr/bin/env bash
# install.sh - Create the ~/.claude-remote/{instance-id}/ state directories
# Usage: install.sh [instance-id]

set -euo pipefail

# Load platform detection
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "${SCRIPT_DIR}/core/scripts/platform.sh" ]]; then
    source "${SCRIPT_DIR}/core/scripts/platform.sh"
else
    # Inline fallback for first-run before platform.sh exists
    is_windows() { [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "${OS:-}" == "Windows_NT" ]]; }
    is_macos() { [[ "$OSTYPE" == "darwin"* ]]; }
fi

# Dependency checks (platform-gated)
MISSING=""
if is_macos; then
    command -v tmux >/dev/null 2>&1 || MISSING="${MISSING} tmux"
elif is_windows; then
    command -v node >/dev/null 2>&1 || MISSING="${MISSING} node"
    command -v pm2 >/dev/null 2>&1 || MISSING="${MISSING} pm2"
fi
command -v claude >/dev/null 2>&1 || MISSING="${MISSING} claude"

# Auto-install jq on Windows if missing (not included with Git for Windows)
if ! command -v jq >/dev/null 2>&1; then
    if is_windows; then
        echo "jq not found. Installing automatically..."
        JQ_INSTALL_DIR="${HOME}/.local/bin"
        mkdir -p "${JQ_INSTALL_DIR}"
        if curl -sL "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-windows-amd64.exe" -o "${JQ_INSTALL_DIR}/jq.exe"; then
            chmod +x "${JQ_INSTALL_DIR}/jq.exe"
            if command -v jq >/dev/null 2>&1; then
                echo "  jq $(jq --version) installed to ${JQ_INSTALL_DIR}/jq.exe"
            else
                echo "  jq installed but not on PATH. Add ${JQ_INSTALL_DIR} to your PATH."
                MISSING="${MISSING} jq"
            fi
        else
            echo "  Failed to download jq. Install manually: https://jqlang.github.io/jq/"
            MISSING="${MISSING} jq"
        fi
    else
        MISSING="${MISSING} jq"
    fi
fi

if [[ -n "$MISSING" ]]; then
    echo "ERROR: Missing required dependencies:${MISSING}"
    echo ""
    if is_macos; then
        [[ "$MISSING" == *"tmux"* ]] && echo "  tmux:   brew install tmux"
        [[ "$MISSING" == *"jq"* ]] && echo "  jq:     brew install jq"
    elif is_windows; then
        [[ "$MISSING" == *"node"* ]] && echo "  node:   https://nodejs.org/ (v18+ required)"
        [[ "$MISSING" == *"pm2"* ]] && echo "  pm2:    npm install -g pm2"
        [[ "$MISSING" == *"jq"* ]] && echo "  jq:     https://jqlang.github.io/jq/"
    fi
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

# Windows: create inject directory and install node-pty
if is_windows; then
    mkdir -p "${CRM_ROOT}/inject" && chmod 700 "${CRM_ROOT}/inject"

    echo "Installing node-pty (Windows PTY support)..."
    PREV_DIR="$(pwd)"
    cd "${CRM_ROOT}"
    if [[ ! -d "node_modules/node-pty" ]]; then
        npm init -y > /dev/null 2>&1
        npm install node-pty 2>&1
        if [[ $? -ne 0 ]]; then
            echo ""
            echo "WARNING: node-pty installation failed."
            echo "  You may need to install it manually:"
            echo "    cd ${CRM_ROOT} && npm install node-pty"
            echo ""
            echo "  If prebuilt binaries aren't available for your Node version,"
            echo "  you'll need: npm install --global windows-build-tools"
            echo ""
        else
            echo "  node-pty installed successfully."
        fi
    else
        echo "  node-pty already installed."
    fi
    cd "${PREV_DIR}"
fi

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
