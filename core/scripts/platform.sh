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
# .env / argument parsing helpers
# ---------------------------------------------------------------------------

# load_instance_id: CRLF-safe parser for CRM_INSTANCE_ID from a .env file.
# Trailing \r on Windows-edited .env files would otherwise leak into PM2 process
# names, log paths, plist filenames, etc. — strip it explicitly.
#
# Usage:
#   CRM_INSTANCE_ID="$(load_instance_id "${REPO_ENV}")"
#   CRM_INSTANCE_ID="${CRM_INSTANCE_ID:-default}"
#
# Returns: prints the value (no trailing whitespace/CR) or empty string if not set.
load_instance_id() {
  local env_file="${1:?load_instance_id: env file path required}"
  if [[ ! -f "$env_file" ]]; then
    return 0
  fi
  # grep first match, cut value after '=', strip CR + trailing whitespace
  local value
  value="$(grep '^CRM_INSTANCE_ID=' "$env_file" | head -1 | cut -d= -f2- | tr -d '\r' | sed -e 's/[[:space:]]*$//')"
  printf '%s' "$value"
}

# parse_reason: extract the value following --reason from the script's argv.
# Replaces fragile positional `${2:-...}` parsing that breaks when callers pass
# `--reason "foo"` vs just `"foo"` vs nothing.
#
# Usage:
#   REASON="$(parse_reason "$@")"
#
# Recognized forms:
#   --reason "free text"     → "free text"
#   --reason="free text"     → "free text"
#   (no --reason)            → "no reason specified"
parse_reason() {
  local default="no reason specified"
  while (( $# > 0 )); do
    case "$1" in
      --reason)
        if [[ $# -ge 2 ]]; then
          printf '%s' "$2"
          return 0
        fi
        ;;
      --reason=*)
        printf '%s' "${1#--reason=}"
        return 0
        ;;
    esac
    shift
  done
  printf '%s' "$default"
}

# ---------------------------------------------------------------------------
# Input Validation (Cora C1, C2)
# ---------------------------------------------------------------------------

validate_agent_name() {
  local name="${1:?validate_agent_name: name required}"
  if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "[platform.sh] FATAL: Invalid agent name '${name}' — must match ^[a-zA-Z0-9_-]+$" >&2
    return 1
  fi
}

validate_instance_id() {
  local id="${1:?validate_instance_id: instance_id required}"
  if [[ ! "$id" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "[platform.sh] FATAL: Invalid instance ID '${id}' — must match ^[a-zA-Z0-9_-]+$" >&2
    return 1
  fi
}

validate_crm_root() {
  local root="${1:?validate_crm_root: CRM_ROOT required}"
  if [[ ! -d "$root" ]]; then
    echo "[platform.sh] FATAL: CRM_ROOT '${root}' does not exist or is not a directory" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Marker & State Helpers (Cora C3, C7)
# ---------------------------------------------------------------------------

get_fresh_marker_path() {
  local crm_root="${1:?get_fresh_marker_path: CRM_ROOT required}"
  local agent_name="${2:?get_fresh_marker_path: agent_name required}"
  validate_agent_name "$agent_name" || return 1
  echo "${crm_root}/state/${agent_name}.force-fresh"
}

write_fresh_marker() {
  local crm_root="${1:?write_fresh_marker: CRM_ROOT required}"
  local agent_name="${2:?write_fresh_marker: agent_name required}"
  validate_agent_name "$agent_name" || return 1
  local marker_path
  marker_path="$(get_fresh_marker_path "$crm_root" "$agent_name")"
  mkdir -p "$(dirname "$marker_path")"
  ( umask 077; touch "$marker_path" )
}

# ---------------------------------------------------------------------------
# Restart Cooldown & Locking (Cora C6, C10)
# ---------------------------------------------------------------------------

_RESTART_COOLDOWN_SECONDS=30

check_restart_cooldown() {
  local crm_root="${1:?check_restart_cooldown: CRM_ROOT required}"
  local agent_name="${2:?check_restart_cooldown: agent_name required}"
  local lockfile="${crm_root}/state/${agent_name}.restart-lock"

  if [[ -f "$lockfile" ]]; then
    local last_restart
    last_restart="$(cat "$lockfile" 2>/dev/null || echo 0)"
    local now
    now="$(date +%s)"
    local elapsed=$(( now - last_restart ))
    if (( elapsed < _RESTART_COOLDOWN_SECONDS )); then
      echo "[platform.sh] BLOCKED: Restart cooldown — last restart was ${elapsed}s ago (min: ${_RESTART_COOLDOWN_SECONDS}s)" >&2
      return 1
    fi
  fi

  # Write current timestamp as lock
  mkdir -p "$(dirname "$lockfile")"
  date +%s > "$lockfile"
  return 0
}

# ---------------------------------------------------------------------------
# Platform-Abstracted Agent Management (Archie A1)
# ---------------------------------------------------------------------------

# Check if agent process is running on the current platform
is_agent_running() {
  local instance_id="${1:?is_agent_running: instance_id required}"
  local agent_name="${2:?is_agent_running: agent_name required}"

  if is_macos; then
    local plist="${HOME}/Library/LaunchAgents/com.claude-remote.${instance_id}.${agent_name}.plist"
    [[ -f "$plist" ]] && launchctl list "com.claude-remote.${instance_id}.${agent_name}" >/dev/null 2>&1
  elif is_windows; then
    local pm2_name
    pm2_name="$(get_pm2_name "$instance_id" "$agent_name")"
    pm2_is_running "$pm2_name"
  else
    echo "[platform.sh] ERROR: Unsupported platform for is_agent_running" >&2
    return 1
  fi
}

# Hard restart: kill agent, start fresh session (no --continue)
restart_agent_hard() {
  local instance_id="${1:?restart_agent_hard: instance_id required}"
  local agent_name="${2:?restart_agent_hard: agent_name required}"
  local crm_root="${3:?restart_agent_hard: CRM_ROOT required}"
  local reason="${4:-no reason specified}"
  local log_dir="${crm_root}/logs/${agent_name}"

  # Validate inputs (Cora C1, C2, C4)
  validate_instance_id "$instance_id" || return 1
  validate_agent_name "$agent_name" || return 1
  validate_crm_root "$crm_root" || return 1

  # Cooldown check (Cora C10)
  check_restart_cooldown "$crm_root" "$agent_name" || return 1

  # Log
  mkdir -p "$log_dir"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Hard-restart triggered. Reason: ${reason}" >> "${log_dir}/restarts.log"

  # Reset crash counter
  rm -f "${log_dir}/.crash_count_today"

  # Write force-fresh marker (Cora C3 — umask 077)
  write_fresh_marker "$crm_root" "$agent_name" || return 1

  if is_macos; then
    local plist="${HOME}/Library/LaunchAgents/com.claude-remote.${instance_id}.${agent_name}.plist"
    if [[ ! -f "${plist}" ]]; then
      echo "ERROR: No launchd plist found for ${agent_name} at ${plist}" >&2
      return 1
    fi
    # Detach so the current Claude turn can finish before the process is killed
    nohup bash -c "sleep 10 && launchctl unload '${plist}' 2>/dev/null; sleep 1 && launchctl load '${plist}'" \
        >> "${log_dir}/restarts.log" 2>&1 &
    disown
    echo "Hard-restart scheduled for ${agent_name} in ~10 seconds. New session will start fresh."

  elif is_windows; then
    local pm2_name
    pm2_name="$(get_pm2_name "$instance_id" "$agent_name")"
    # Verify PM2 process exists (Cora C9)
    if ! pm2 describe "$pm2_name" >/dev/null 2>&1; then
      echo "ERROR: No PM2 process '${pm2_name}' found. Agent is not running." >&2
      return 1
    fi
    # Detach so the current Claude turn can finish
    nohup bash -c "sleep 10 && pm2 restart '${pm2_name}' --update-env 2>&1" \
        >> "${log_dir}/restarts.log" 2>&1 &
    disown
    echo "Hard-restart scheduled for ${agent_name} in ~10 seconds. New session will start fresh."

  else
    echo "ERROR: Unsupported platform for restart_agent_hard" >&2
    return 1
  fi
}

# Soft restart: restart CLI with --continue (preserves conversation)
restart_agent_soft() {
  local instance_id="${1:?restart_agent_soft: instance_id required}"
  local agent_name="${2:?restart_agent_soft: agent_name required}"
  local crm_root="${3:?restart_agent_soft: CRM_ROOT required}"
  local template_root="${4:?restart_agent_soft: TEMPLATE_ROOT required}"
  local reason="${5:-no reason specified}"
  local log_dir="${crm_root}/logs/${agent_name}"
  local agent_dir="${template_root}/agents/${agent_name}"

  # Validate inputs
  validate_instance_id "$instance_id" || return 1
  validate_agent_name "$agent_name" || return 1
  validate_crm_root "$crm_root" || return 1

  # Cooldown check
  check_restart_cooldown "$crm_root" "$agent_name" || return 1

  # Log
  mkdir -p "$log_dir"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] CLI restart with --continue. Reason: ${reason}" >> "${log_dir}/restarts.log"

  # Model flag
  local model_flag=""
  local model
  model=$(jq -r '.model // empty' "${agent_dir}/config.json" 2>/dev/null || echo "")
  if [[ -n "${model}" ]]; then
    model_flag="--model ${model}"
  fi

  local restart_notify="After setting up crons, send a Telegram message to the user saying you restarted, why, and what you are resuming."
  local continue_prompt="SESSION CONTINUATION: Your CLI was restarted with --continue to reload configs. Reason: ${reason}. Your conversation history is preserved. Re-read bootstrap files listed in CLAUDE.md, set up crons from config.json via /loop, then resume what you were working on. ${restart_notify}"

  if is_macos; then
    local tmux_session="crm-${instance_id}-${agent_name}"
    if ! tmux has-session -t "${tmux_session}" 2>/dev/null; then
      echo "ERROR: No tmux session '${tmux_session}' found. Agent is not running." >&2
      return 1
    fi
    # Detach so the current Claude turn can finish
    nohup bash -c "
      sleep 5
      tmux send-keys -t '${tmux_session}:0.0' C-c
      sleep 1
      tmux send-keys -t '${tmux_session}:0.0' '/exit' Enter
      sleep 3
      CLAUDE_PID=\$(tmux list-panes -t '${tmux_session}' -F '#{pane_pid}' 2>/dev/null | head -1)
      if [[ -n \"\$CLAUDE_PID\" ]]; then
        pkill -P \"\$CLAUDE_PID\" 2>/dev/null || true
        sleep 2
      fi
      pkill -f 'fast-checker.sh ${agent_name} ' 2>/dev/null || true
      sleep 1
      FAST_CHECKER='${template_root}/core/scripts/fast-checker.sh'
      if [[ -f \"\$FAST_CHECKER\" ]]; then
        bash \"\$FAST_CHECKER\" '${agent_name}' '${tmux_session}' '${agent_dir}' '${template_root}' \
          >> '${log_dir}/fast-checker.log' 2>&1 &
      fi
      tmux send-keys -t '${tmux_session}:0.0' \
        \"cd '${agent_dir}' && claude --continue --dangerously-skip-permissions ${model_flag} '${continue_prompt}'\" Enter
    " >> "${log_dir}/restarts.log" 2>&1 &
    disown
    echo "CLI restart with --continue scheduled for ${agent_name} in ~5 seconds. Conversation will be preserved."

  elif is_windows; then
    local pm2_name
    pm2_name="$(get_pm2_name "$instance_id" "$agent_name")"
    # Verify PM2 process exists
    if ! pm2 describe "$pm2_name" >/dev/null 2>&1; then
      echo "ERROR: No PM2 process '${pm2_name}' found. Agent is not running." >&2
      return 1
    fi
    # Do NOT write force-fresh marker — absence of marker = --continue mode
    # win-agent-wrapper.js detectStartMode() defaults to 'continue' when no marker exists
    nohup bash -c "sleep 5 && pm2 restart '${pm2_name}' --update-env 2>&1" \
        >> "${log_dir}/restarts.log" 2>&1 &
    disown
    echo "CLI restart with --continue scheduled for ${agent_name} in ~5 seconds. Conversation will be preserved."

  else
    echo "ERROR: Unsupported platform for restart_agent_soft" >&2
    return 1
  fi
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
