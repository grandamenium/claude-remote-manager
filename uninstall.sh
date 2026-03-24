#!/usr/bin/env bash
# uninstall.sh - Remove Claude Remote Manager instance (launchd, tmux, state)
# Usage: uninstall.sh [instance-id]
#   --keep-agents   Remove services and state but leave agents/ directories intact
#   --yes           Skip confirmation prompt

set -euo pipefail

TEMPLATE_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Parse flags
KEEP_AGENTS=false
AUTO_YES=false
for arg in "$@"; do
    case "$arg" in
        --keep-agents) KEEP_AGENTS=true ;;
        --yes|-y) AUTO_YES=true ;;
        --*) echo "Unknown flag: $arg"; exit 1 ;;
    esac
done

# Get instance ID from first positional arg, .env, or default
POSITIONAL_ARG=""
for arg in "$@"; do
    [[ "$arg" == --* ]] && continue
    POSITIONAL_ARG="$arg"
    break
done

if [[ -n "${POSITIONAL_ARG}" ]]; then
    CRM_INSTANCE_ID="${POSITIONAL_ARG}"
elif [[ -f "${TEMPLATE_ROOT}/.env" ]]; then
    CRM_INSTANCE_ID=$(grep '^CRM_INSTANCE_ID=' "${TEMPLATE_ROOT}/.env" | cut -d= -f2 || echo "default")
else
    CRM_INSTANCE_ID="default"
fi

CRM_ROOT="${HOME}/.claude-remote/${CRM_INSTANCE_ID}"

echo "========================================="
echo "  Claude Remote Manager - Uninstall"
echo "========================================="
echo ""
echo "  Instance ID: ${CRM_INSTANCE_ID}"
echo "  State dir:   ${CRM_ROOT}"
echo ""

if [[ ! -d "${CRM_ROOT}" ]] && [[ ! -f "${TEMPLATE_ROOT}/.env" ]]; then
    echo "Nothing to uninstall — no state directory or .env found."
    exit 0
fi

# Discover agents from enabled-agents.json or agent directories
AGENTS=()
ENABLED_FILE="${CRM_ROOT}/config/enabled-agents.json"
if [[ -f "${ENABLED_FILE}" ]] && command -v jq >/dev/null 2>&1; then
    while IFS= read -r name; do
        [[ -n "$name" ]] && AGENTS+=("$name")
    done < <(jq -r 'keys[]' "${ENABLED_FILE}" 2>/dev/null)
fi

# Also check agent directories in case some weren't registered
if [[ -d "${TEMPLATE_ROOT}/agents" ]]; then
    for d in "${TEMPLATE_ROOT}/agents"/*/; do
        name=$(basename "$d")
        [[ "${name}" == "agent-template" ]] && continue
        # Add if not already in list
        local_found=false
        for existing in "${AGENTS[@]+"${AGENTS[@]}"}"; do
            [[ "$existing" == "$name" ]] && local_found=true && break
        done
        [[ "$local_found" == false ]] && AGENTS+=("$name")
    done
fi

echo "  Agents found: ${AGENTS[*]:-none}"
echo ""

# Show what will be removed
echo "This will:"
echo "  - Stop and unload all launchd services for this instance"
echo "  - Kill all tmux sessions for this instance"
echo "  - Remove state directory: ${CRM_ROOT}"
echo "  - Remove repo .env file"
if [[ "${KEEP_AGENTS}" == true ]]; then
    echo "  - Keep agents/ directories (--keep-agents)"
else
    echo "  - Remove agent .env files (bot tokens)"
fi
echo ""

if [[ "${AUTO_YES}" != true ]]; then
    read -rp "Continue? [y/N] " CONFIRM
    if [[ "${CONFIRM}" != "y" && "${CONFIRM}" != "Y" ]]; then
        echo "Aborted."
        exit 0
    fi
    echo ""
fi

# 1. Stop launchd services and remove plists
echo "Stopping services..."
PLIST_DIR="${HOME}/Library/LaunchAgents"
for agent in "${AGENTS[@]+"${AGENTS[@]}"}"; do
    PLIST="${PLIST_DIR}/com.claude-remote.${CRM_INSTANCE_ID}.${agent}.plist"
    if [[ -f "${PLIST}" ]]; then
        launchctl unload "${PLIST}" 2>/dev/null || true
        rm -f "${PLIST}"
        echo "  launchd: removed ${agent}"
    fi
done

# Also catch any plists matching this instance that weren't in the agent list
for plist in "${PLIST_DIR}"/com.claude-remote."${CRM_INSTANCE_ID}".*.plist; do
    [[ -f "$plist" ]] || continue
    launchctl unload "$plist" 2>/dev/null || true
    rm -f "$plist"
    echo "  launchd: removed $(basename "$plist")"
done

# 2. Kill tmux sessions
echo "Killing tmux sessions..."
for agent in "${AGENTS[@]+"${AGENTS[@]}"}"; do
    SESSION="crm-${CRM_INSTANCE_ID}-${agent}"
    if tmux has-session -t "${SESSION}" 2>/dev/null; then
        tmux kill-session -t "${SESSION}"
        echo "  tmux: killed ${SESSION}"
    fi
done

# 3. Remove state directory
if [[ -d "${CRM_ROOT}" ]]; then
    echo "Removing state directory..."
    rm -rf "${CRM_ROOT}"
    echo "  removed: ${CRM_ROOT}"
fi

# Clean up parent if empty
PARENT="${HOME}/.claude-remote"
if [[ -d "${PARENT}" ]] && [[ -z "$(ls -A "${PARENT}" 2>/dev/null)" ]]; then
    rmdir "${PARENT}"
    echo "  removed: ${PARENT} (empty)"
fi

# 4. Remove agent .env files (contain bot tokens)
if [[ "${KEEP_AGENTS}" != true ]]; then
    echo "Removing agent credentials..."
    for agent in "${AGENTS[@]+"${AGENTS[@]}"}"; do
        AGENT_ENV="${TEMPLATE_ROOT}/agents/${agent}/.env"
        if [[ -f "${AGENT_ENV}" ]]; then
            rm -f "${AGENT_ENV}"
            echo "  removed: agents/${agent}/.env"
        fi
    done
fi

# 5. Remove repo .env
if [[ -f "${TEMPLATE_ROOT}/.env" ]]; then
    rm -f "${TEMPLATE_ROOT}/.env"
    echo "  removed: .env"
fi

echo ""
echo "========================================="
echo "  Uninstall complete"
echo "========================================="
echo ""
if [[ "${KEEP_AGENTS}" == true ]]; then
    echo "  Agent directories preserved. To reinstall:"
else
    echo "  To reinstall:"
fi
echo "    ./install.sh ${CRM_INSTANCE_ID}"
echo ""
