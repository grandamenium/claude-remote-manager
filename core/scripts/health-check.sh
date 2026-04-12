#!/usr/bin/env bash
# health-check.sh - External watchdog for Claude Remote agents.
#
# Intended usage: drive this from launchd (or cron) at a ~30 min cadence so
# a failure in fast-checker or a dead Claude process inside a live tmux
# session does not go unnoticed. This script does NOT install its own
# LaunchAgent yet — wiring up the plist is a follow-up. Today it is meant
# to be invoked manually or from an external scheduler the operator
# already controls.
#
# Detection: for each enabled agent it inspects the tmux session and the
# fast-checker pid file, and if it sees a zombie it calls
# `enable-agent.sh <agent> --restart`. Independent of the agent itself
# (runs outside any of the agent's own tmux sessions).
#
# Usage: health-check.sh [agent_name]   (no arg = all enabled agents)

set -o pipefail

TEMPLATE_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REPO_ENV="${TEMPLATE_ROOT}/.env"
if [[ -f "${REPO_ENV}" ]]; then
    CRM_INSTANCE_ID=$(grep '^CRM_INSTANCE_ID=' "${REPO_ENV}" | cut -d= -f2)
fi
CRM_INSTANCE_ID="${CRM_INSTANCE_ID:-default}"
CRM_ROOT="${HOME}/.claude-remote/${CRM_INSTANCE_ID}"
ENABLED_FILE="${CRM_ROOT}/config/enabled-agents.json"
LOG_FILE="${CRM_ROOT}/logs/health-check.log"

mkdir -p "$(dirname "$LOG_FILE")"

# --- Singleton lock ---------------------------------------------------------
# Prevent overlapping invocations from double-triggering restarts. Uses mkdir
# as an atomic lock (same POSIX-portable pattern as fast-checker.sh). If this
# script is launched by launchd or cron and the previous run is still in
# flight (e.g. because an enable-agent.sh restart is slow), the second
# invocation exits immediately instead of evaluating the same unhealthy state
# and firing a redundant restart.
LOCKDIR="${CRM_ROOT}/state/health-check.lock"
mkdir -p "${CRM_ROOT}/state"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    # Lock exists — check if holder is still alive
    OLD_PID=""
    if [[ -f "${LOCKDIR}/pid" ]]; then
        OLD_PID=$(cat "${LOCKDIR}/pid" 2>/dev/null || echo "")
    fi
    if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [health-check] another instance running (pid $OLD_PID) — exiting" >> "$LOG_FILE"
        exit 0
    fi
    # Stale lock — previous run crashed without cleanup. Reclaim.
    rm -rf "$LOCKDIR"
    mkdir "$LOCKDIR" 2>/dev/null || { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [health-check] cannot acquire lock — exiting" >> "$LOG_FILE"; exit 1; }
fi
echo $$ > "${LOCKDIR}/pid"
# Clean up on any exit (normal, error, signal).
trap 'rm -rf "$LOCKDIR"' EXIT

log() {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [health-check] $1" >> "$LOG_FILE"
}

notify_telegram() {
    local agent="$1"
    local message="$2"
    local env_file="${TEMPLATE_ROOT}/agents/${agent}/.env"
    if [[ -f "$env_file" ]]; then
        local token chat_id
        token=$(grep '^BOT_TOKEN=' "$env_file" | cut -d= -f2)
        chat_id=$(grep '^CHAT_ID=' "$env_file" | cut -d= -f2)
        if [[ -n "$token" && -n "$chat_id" ]]; then
            curl -s -X POST "https://api.telegram.org/bot${token}/sendMessage" \
                -d chat_id="${chat_id}" \
                -d text="${message}" \
                > /dev/null 2>&1 || true
        fi
    fi
}

check_agent() {
    local agent="$1"
    local tmux_session="crm-${CRM_INSTANCE_ID}-${agent}"
    local status="OK"
    local action=""

    # 0. Grace period: skip check if agent was started/restarted in the last 5 min
    # This avoids false positives during bootstrap (tmux shows bash before Claude launches)
    local session_start_file="${CRM_ROOT}/state/${agent}.session-start"
    if [[ -f "$session_start_file" ]]; then
        local start_ts now_ts elapsed
        start_ts=$(cat "$session_start_file" 2>/dev/null || echo "0")
        now_ts=$(date +%s)
        elapsed=$((now_ts - start_ts))
        if [[ $elapsed -lt 300 ]]; then
            log "${agent}: grace period (${elapsed}s since start, need 300s) — skipping"
            return 0
        fi
    fi

    # 1. Check tmux session exists
    if ! tmux has-session -t "${tmux_session}" 2>/dev/null; then
        log "${agent}: tmux session missing — launchd should handle this"
        return 0
    fi

    # 2. Check if Claude is running inside tmux.
    #
    # Heuristic is intentionally POSITIVE: we look for evidence that the
    # Claude UI is still rendering, not for a catalog of dead-shell
    # prompts. Listing prompt shapes misses prompts that include cwd,
    # hostname, shell error text, or any locale-dependent formatting.
    # A positive check is bounded by what Claude itself always renders.
    # Markers below are stable across versions:
    #
    #   - "permissions"           status bar at the bottom
    #   - "bypass permissions"    same bar under --dangerously-skip-permissions
    #   - "Worked for" / "Cooked for" / "Baked for"   loop spinners
    #   - "context"               context bar (tokens/percent)
    #   - "❯" / "│"               input box / streaming block border
    #   - "(esc to interrupt)"    tool call indicator
    #
    # Double-sample with a 2-second gap to avoid transient false positives:
    # tmux capture-pane can race with pane redraws, and a single empty
    # capture during a screen clear would otherwise trigger a false
    # ZOMBIE classification. Only mark as zombie if BOTH samples lack
    # any UI marker. This costs 2s per check, acceptable for a 30 min
    # cadence watchdog.
    local ui_markers='(permissions|Worked for|Cooked for|Baked for|context|\(esc to interrupt\)|❯|│)'
    local pane_sample_1 pane_sample_2
    pane_sample_1=$(tmux capture-pane -t "${tmux_session}:0.0" -p 2>/dev/null)
    if [[ -n "$pane_sample_1" ]] && echo "$pane_sample_1" | grep -qE "$ui_markers"; then
        : # healthy — first sample already shows Claude UI
    else
        sleep 2
        pane_sample_2=$(tmux capture-pane -t "${tmux_session}:0.0" -p 2>/dev/null)
        if [[ -z "$pane_sample_1" && -z "$pane_sample_2" ]]; then
            # Both captures failed or pane is truly empty — treat as zombie.
            status="ZOMBIE_EMPTY_PANE"
            action="restart"
        elif ! echo "$pane_sample_2" | grep -qE "$ui_markers"; then
            # Confirmed: two samples 2s apart, neither shows Claude UI.
            status="ZOMBIE"
            action="restart"
        fi
    fi

    # 3. Check fast-checker is alive
    local fc_pid_file="${CRM_ROOT}/state/${agent}.fast-checker.pid"
    local fc_alive=false
    if [[ -f "$fc_pid_file" ]]; then
        local fc_pid
        fc_pid=$(cat "$fc_pid_file" 2>/dev/null || echo "")
        if [[ -n "$fc_pid" ]] && kill -0 "$fc_pid" 2>/dev/null; then
            fc_alive=true
        fi
    fi

    if [[ "$fc_alive" == "false" && "$status" == "OK" ]]; then
        status="FC_DEAD"
        action="restart"
    fi

    # Act on findings
    case "$action" in
        restart)
            log "${agent}: STATUS=${status} — auto-restarting"
            notify_telegram "$agent" "Health-check: ${agent} detectado como ${status}. Reiniciando automaticamente..."
            # Capture the restart exit code. `cd && …` returns the exit
            # code of the last command, but if `cd` itself fails we get
            # the `cd` failure, not a silent success. Either way we bail
            # into the failure branch below. This is the whole point of
            # the watchdog — a false-positive "restart succeeded" message
            # is worse than no message, because it hides the need for
            # operator intervention.
            local restart_rc
            if cd "$TEMPLATE_ROOT" && bash enable-agent.sh "$agent" --restart >> "$LOG_FILE" 2>&1; then
                restart_rc=0
                log "${agent}: restart succeeded"
                notify_telegram "$agent" "Health-check: ${agent} reiniciado com sucesso."
            else
                restart_rc=$?
                log "${agent}: restart FAILED (exit ${restart_rc}) — manual intervention required"
                notify_telegram "$agent" "Health-check: FALHA ao reiniciar ${agent} (status=${status}, exit=${restart_rc}). Intervenção manual necessária."
            fi
            ;;
        *)
            log "${agent}: STATUS=OK"
            ;;
    esac
}

# Main: check specific agent or all enabled
if [[ -n "${1:-}" ]]; then
    check_agent "$1"
else
    if [[ ! -f "$ENABLED_FILE" ]]; then
        log "No enabled-agents.json found"
        exit 0
    fi
    # Validate the config file is a non-empty JSON **object** before
    # iterating. We check the actual schema the watchdog expects rather
    # than just "is it valid JSON?", because:
    #   - Empty file    → jq '.' exits 0 → silent no-op (wrong)
    #   - JSON array [] → jq '.' exits 0, to_entries on array is valid
    #     but semantically wrong → misleading "no enabled agents" (wrong)
    #   - Truncated {   → jq '.' exits 1 → caught (good)
    # The expression `type == "object"` covers all three bad cases in one
    # check. If the file is empty, jq reads nothing and exits non-zero.
    # If it is a non-object JSON value, the type check fails.
    if ! jq -e 'type == "object"' "$ENABLED_FILE" > /dev/null 2>&1; then
        log "ERROR: enabled-agents.json is missing, empty, or not a JSON object — watchdog cannot determine which agents to check"
        exit 1
    fi
    # Get all enabled agents. No `local` here — we are at top level,
    # not inside a function, and bash 3.2 emits a runtime warning for
    # `local` outside functions even though it parses cleanly under -n.
    agents=$(jq -r 'to_entries[] | select(.value.enabled == true) | .key' "$ENABLED_FILE" 2>/dev/null)
    if [[ -z "$agents" ]]; then
        log "No enabled agents found in enabled-agents.json"
        exit 0
    fi
    for agent in $agents; do
        check_agent "$agent"
    done
fi
