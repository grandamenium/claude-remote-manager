#!/usr/bin/env bash
# agent-health-check.sh — Standalone cross-agent health monitor
# Called by Frank's heartbeat or manually. Returns JSON summary.
# Exit 0 = all healthy, Exit 1 = at least one agent needs attention.

set -euo pipefail

LOGS_DIR="$HOME/.claude-remote/default/logs"
HEARTBEAT_STALE_SECONDS=300  # 5 min — agent should be writing heartbeats more often
WORK_HOURS_START=8
WORK_HOURS_END=20
NOW_EPOCH=$(date +%s)
CURRENT_HOUR=$(TZ=America/Los_Angeles date +%H)
IS_WORK_HOURS=false
if (( CURRENT_HOUR >= WORK_HOURS_START && CURRENT_HOUR < WORK_HOURS_END )); then
  IS_WORK_HOURS=true
fi

has_issues=false

echo "{"
echo "  \"timestamp\": \"$(TZ=America/Los_Angeles date '+%Y-%m-%d %H:%M:%S %Z')\","
echo "  \"work_hours\": $IS_WORK_HOURS,"
echo "  \"agents\": ["

first=true
while IFS=$'\t' read -r pid status label; do
  # Extract agent name from label like com.claude-remote.default.frank
  agent_name="${label##*.}"

  if [ "$first" = true ]; then first=false; else echo "    ,"; fi

  # Determine health
  health="healthy"
  issue=""

  # Check if PID is '-' (not running)
  if [ "$pid" = "-" ]; then
    health="dead"
    issue="No PID — agent not running (last exit: $status)"
    has_issues=true
  elif [ "$status" = "-9" ] || [ "$status" = "-15" ]; then
    # Running but last exit was a kill signal — check if it's actually responsive
    # Check heartbeat file age
    hb_file="$LOGS_DIR/$agent_name/heartbeat"
    if [ -f "$hb_file" ]; then
      hb_epoch=$(stat -f %m "$hb_file" 2>/dev/null || echo 0)
      hb_age=$(( NOW_EPOCH - hb_epoch ))
      if [ "$hb_age" -gt "$HEARTBEAT_STALE_SECONDS" ] && [ "$IS_WORK_HOURS" = true ]; then
        health="stale"
        issue="Heartbeat is ${hb_age}s old (threshold: ${HEARTBEAT_STALE_SECONDS}s)"
        has_issues=true
      fi
    fi
  fi

  # Check restart log for recent zombie restarts
  restart_log="$LOGS_DIR/$agent_name/restarts.log"
  recent_restarts=0
  if [ -f "$restart_log" ]; then
    five_min_ago=$(( NOW_EPOCH - 300 ))
    recent_restarts=$(awk -v cutoff="$five_min_ago" '$1 > cutoff' "$restart_log" 2>/dev/null | wc -l | tr -d ' ')
  fi

  # Check activity log for last activity
  activity_log="$LOGS_DIR/$agent_name/activity.log"
  last_activity="unknown"
  if [ -f "$activity_log" ]; then
    last_line=$(tail -1 "$activity_log" 2>/dev/null || echo "")
    if [ -n "$last_line" ]; then
      last_activity=$(echo "$last_line" | cut -d' ' -f1-2)
    fi
  fi

  echo "    {"
  echo "      \"name\": \"$agent_name\","
  echo "      \"pid\": \"$pid\","
  echo "      \"last_exit\": \"$status\","
  echo "      \"health\": \"$health\","
  echo "      \"issue\": \"$issue\","
  echo "      \"recent_restarts\": $recent_restarts,"
  echo "      \"last_activity\": \"$last_activity\""
  echo "    }"

done < <(launchctl list 2>/dev/null | grep claude-remote | awk '{print $1"\t"$2"\t"$3}')

echo "  ]"
echo "}"

if [ "$has_issues" = true ]; then
  exit 1
fi
exit 0
