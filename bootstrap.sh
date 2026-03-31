#!/usr/bin/env bash
# bootstrap.sh — One-command setup for Claude Remote Manager
# Run this from any directory to clone and launch setup.
# Usage: bash <(curl -s https://raw.githubusercontent.com/grandamenium/claude-remote-manager/main/bootstrap.sh)
#   or:  curl -s ... | bash
#   or:  ./bootstrap.sh [--dir ~/my-agents]

set -euo pipefail

REPO_URL="https://github.com/grandamenium/claude-remote-manager.git"
INSTALL_DIR="${HOME}/claude-remote-manager"

# Parse optional --dir argument
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir) INSTALL_DIR="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

echo "========================================="
echo "  Claude Remote Manager Bootstrap"
echo "========================================="
echo ""

# Check dependencies
MISSING=""
command -v git >/dev/null 2>&1 || MISSING="${MISSING} git"
command -v claude >/dev/null 2>&1 || MISSING="${MISSING} claude"
if [[ -n "$MISSING" ]]; then
    echo "ERROR: Missing required dependencies:${MISSING}"
    [[ "$MISSING" == *"claude"* ]] && echo "  claude: https://docs.anthropic.com/en/docs/claude-code"
    exit 1
fi

# Clone if not already present
if [[ -d "${INSTALL_DIR}/.git" ]]; then
    echo "Repo already cloned at ${INSTALL_DIR}. Pulling latest..."
    git -C "${INSTALL_DIR}" pull --ff-only
else
    echo "Cloning into ${INSTALL_DIR}..."
    git clone "${REPO_URL}" "${INSTALL_DIR}"
fi

echo ""
echo "========================================="
echo "  NEXT STEP"
echo "========================================="
echo ""
echo "  Run these two commands:"
echo ""
echo "    cd ${INSTALL_DIR}"
echo "    claude ."
echo ""
echo "  Once Claude Code opens, type:"
echo "    /claude-remote-manager-setup"
echo ""
echo "  That walks you through creating your first agent."
echo ""
