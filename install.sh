#!/usr/bin/env bash
# install.sh - Create the ~/.business-os/{instance-id}/ state directories
# Usage: install.sh [instance-id]

set -euo pipefail

TEMPLATE_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Get instance ID from argument, .env, or default
if [[ -n "${1:-}" ]]; then
    BOS_INSTANCE_ID="$1"
elif [[ -f "${TEMPLATE_ROOT}/.env" ]]; then
    BOS_INSTANCE_ID=$(grep '^BOS_INSTANCE_ID=' "${TEMPLATE_ROOT}/.env" | cut -d= -f2 || echo "default")
else
    BOS_INSTANCE_ID="default"
fi

BOS_ROOT="${HOME}/.business-os/${BOS_INSTANCE_ID}"

echo "========================================="
echo "  Claude Remote Manager - Installation"
echo "========================================="
echo ""
echo "  Instance ID: ${BOS_INSTANCE_ID}"
echo "  State dir:   ${BOS_ROOT}"
echo ""

# Check if already installed
if [[ -d "${BOS_ROOT}" ]]; then
    echo "Directory ${BOS_ROOT} already exists."
    echo "This instance appears to be already installed."
    echo ""
    echo "To reinstall, remove it first: rm -rf ${BOS_ROOT}"
    echo "Or choose a different instance ID: ./install.sh <new-id>"
    exit 1
fi

echo "Creating directory structure..."

# Core state directories
mkdir -p "${BOS_ROOT}/config"
mkdir -p "${BOS_ROOT}/state/heartbeat"
mkdir -p "${BOS_ROOT}/inbox"
mkdir -p "${BOS_ROOT}/outbox"
mkdir -p "${BOS_ROOT}/processed"
mkdir -p "${BOS_ROOT}/inflight"
mkdir -p "${BOS_ROOT}/logs"

# Initialize enabled-agents.json (empty - agents added via setup.sh)
cat > "${BOS_ROOT}/config/enabled-agents.json" << 'EOF'
{}
EOF

# Write .env to repo root
cat > "${TEMPLATE_ROOT}/.env" << EOF
BOS_INSTANCE_ID=${BOS_INSTANCE_ID}
BOS_ROOT=${BOS_ROOT}
EOF

# Copy .env.example if .env doesn't already exist
if [[ ! -f "${TEMPLATE_ROOT}/.env" ]]; then
    cp "${TEMPLATE_ROOT}/.env.example" "${TEMPLATE_ROOT}/.env"
fi

# Make all scripts executable
chmod +x "${TEMPLATE_ROOT}/"*.sh 2>/dev/null || true
chmod +x "${TEMPLATE_ROOT}/scripts/"*.sh 2>/dev/null || true
chmod +x "${TEMPLATE_ROOT}/bus/"*.sh 2>/dev/null || true

echo ""
echo "========================================="
echo "  Installation complete"
echo "========================================="
echo ""
echo "  State directory: ${BOS_ROOT}"
echo "  Instance ID:     ${BOS_INSTANCE_ID}"
echo "  .env written:    ${TEMPLATE_ROOT}/.env"
echo ""
echo "  Next step: Run ./setup.sh to create your first agent"
echo ""
