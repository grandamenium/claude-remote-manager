#!/usr/bin/env bash
# platform.sh — Shared platform detection and utility functions
# Source this file: source "$(dirname "$0")/platform.sh" (or appropriate path)
#
# Safe to source multiple times — only defines functions, no side effects.
# No set -euo pipefail here; callers set their own error handling.

# ---------------------------------------------------------------------------
# Platform Detection
# ---------------------------------------------------------------------------

is_windows() {
  case "${OSTYPE:-}" in
    msys*|cygwin*) return 0 ;;
  esac
  if [[ "${OS:-}" == "Windows_NT" ]]; then
    return 0
  fi
  local uname_s
  uname_s="$(uname -s 2>/dev/null || echo "")"
  case "$uname_s" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
  esac
  return 1
}

is_macos() {
  case "${OSTYPE:-}" in
    darwin*) return 0 ;;
  esac
  local uname_s
  uname_s="$(uname -s 2>/dev/null || echo "")"
  if [[ "$uname_s" == "Darwin" ]]; then
    return 0
  fi
  return 1
}

get_platform() {
  if is_windows; then
    echo "windows"
  elif is_macos; then
    echo "macos"
  else
    echo "unknown"
  fi
}

require_platform() {
  if ! is_windows && ! is_macos; then
    echo "[platform.sh] FATAL: Unsupported platform (OSTYPE=${OSTYPE:-unset}, uname=$(uname -s 2>/dev/null || echo N/A))" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# PM2 Utility Functions (Windows-only)
# ---------------------------------------------------------------------------

get_pm2_name() {
  local instance_id="${1:?get_pm2_name: instance_id required}"
  local agent_name="${2:?get_pm2_name: agent_name required}"
  echo "crm-${instance_id}-${agent_name}"
}

pm2_is_running() {
  local pm2_name="${1:?pm2_is_running: pm2 process name required}"
  local status
  status="$(pm2 jlist 2>/dev/null | jq -r --arg name "$pm2_name" '.[] | select(.name == $name) | .pm2_env.status' 2>/dev/null)"
  [[ "$status" == "online" ]]
}

pm2_stop_agent() {
  local pm2_name="${1:?pm2_stop_agent: pm2 process name required}"
  pm2 stop "$pm2_name" 2>/dev/null
  pm2 delete "$pm2_name" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# Path Utility Functions
# ---------------------------------------------------------------------------

to_posix_path() {
  local win_path="${1:?to_posix_path: path required}"
  local result="$win_path"

  # Convert backslashes to forward slashes
  result="${result//\\//}"

  # Convert drive letter: C:/... -> /c/...
  if [[ "$result" =~ ^([A-Za-z]):(/.*) ]]; then
    local drive="${BASH_REMATCH[1]}"
    local rest="${BASH_REMATCH[2]}"
    # Lowercase the drive letter
    drive="$(echo "$drive" | tr '[:upper:]' '[:lower:]')"
    result="/${drive}${rest}"
  fi

  echo "$result"
}

to_win_path() {
  local posix_path="${1:?to_win_path: path required}"
  local result="$posix_path"

  # Convert /c/... -> C:\...
  if [[ "$result" =~ ^/([A-Za-z])(/.*) ]]; then
    local drive="${BASH_REMATCH[1]}"
    local rest="${BASH_REMATCH[2]}"
    # Uppercase the drive letter
    drive="$(echo "$drive" | tr '[:lower:]' '[:upper:]')"
    result="${drive}:${rest}"
  fi

  # Convert forward slashes to backslashes
  result="${result//\//\\}"

  echo "$result"
}

get_inject_dir() {
  local crm_root="${1:?get_inject_dir: CRM_ROOT required}"
  local agent_name="${2:?get_inject_dir: agent_name required}"
  local inject_dir="${crm_root}/inject/${agent_name}"

  mkdir -p "$inject_dir"
  chmod 700 "$inject_dir"
  # On Windows, chmod is a no-op for NTFS. Use icacls to restrict to current user.
  # Applied idempotently on every call — re-hardens even if ACLs were loosened.
  if is_windows; then
    icacls "$(cygpath -w "$inject_dir")" /inheritance:r /grant:r "${USERNAME}:(OI)(CI)F" > /dev/null 2>&1 || true
  fi

  echo "$inject_dir"
}

# ---------------------------------------------------------------------------
# Message Injection (Windows)
# ---------------------------------------------------------------------------

inject_message_file() {
  local inject_dir="${1:?inject_message_file: inject_dir required}"
  local message="${2:?inject_message_file: message content required}"

  # Epoch milliseconds: use date +%s%N and trim, or fallback
  local epoch_ms
  if date +%s%N >/dev/null 2>&1; then
    epoch_ms="$(date +%s%N)"
    epoch_ms="${epoch_ms:0:13}"
  else
    epoch_ms="$(date +%s)000"
  fi

  local filename="${epoch_ms}-${RANDOM}.msg"
  local tmp_file="${inject_dir}/.tmp.${filename}"
  local final_file="${inject_dir}/${filename}"

  # Write to temp file, then atomic rename
  printf '%s' "$message" > "$tmp_file"
  mv "$tmp_file" "$final_file"

  echo "$filename"
}

# ---------------------------------------------------------------------------
# Logging Helper
# ---------------------------------------------------------------------------

log_platform() {
  local log_file="${1:?log_platform: log_file path required}"

  local platform
  platform="$(get_platform)"

  local shell_type="${BASH_VERSION:+bash ${BASH_VERSION}}"
  shell_type="${shell_type:-unknown shell}"

  local node_ver
  node_ver="$(node --version 2>/dev/null || echo "not found")"

  local pm2_ver
  pm2_ver="$(pm2 --version 2>/dev/null || echo "not found")"

  local jq_ver
  jq_ver="$(jq --version 2>/dev/null || echo "not found")"

  local claude_ver
  claude_ver="$(claude --version 2>/dev/null || echo "not found")"

  {
    echo "=== Platform Info ($(date -u '+%Y-%m-%dT%H:%M:%SZ')) ==="
    echo "  Platform : ${platform}"
    echo "  OSTYPE   : ${OSTYPE:-unset}"
    echo "  Shell    : ${shell_type}"
    echo "  Node     : ${node_ver}"
    echo "  PM2      : ${pm2_ver}"
    echo "  jq       : ${jq_ver}"
    echo "  Claude   : ${claude_ver}"
    echo "================================================"
  } >> "$log_file"
}
