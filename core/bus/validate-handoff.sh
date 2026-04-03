#!/usr/bin/env bash
# validate-handoff.sh - Block restart if agent state file is missing working knowledge
# Called by self-restart.sh and hard-restart.sh before proceeding.
# Returns 0 if state is adequate, 1 if not.
#
# Checks:
# 1. frank-state.json exists and was updated in the last 5 minutes
# 2. mental_context field is >= 200 chars
# 3. working_knowledge object exists and is non-empty

set -euo pipefail

AGENT="${1:-}"
if [[ -z "${AGENT}" ]]; then
    echo "Usage: validate-handoff.sh <agent-name>" >&2
    exit 1
fi

STATE_FILE="${HOME}/code/knowledge-sync/cc/sessions/${AGENT}-state.json"

# Check 1: State file exists
if [[ ! -f "${STATE_FILE}" ]]; then
    echo "BLOCKED: ${STATE_FILE} does not exist. Write state before restarting." >&2
    exit 1
fi

# Check 2: Updated within last 5 minutes (300 seconds)
if [[ "$(uname)" == "Darwin" ]]; then
    FILE_MOD=$(stat -f %m "${STATE_FILE}")
else
    FILE_MOD=$(stat -c %Y "${STATE_FILE}")
fi
NOW=$(date +%s)
AGE=$(( NOW - FILE_MOD ))

if [[ ${AGE} -gt 300 ]]; then
    echo "BLOCKED: ${STATE_FILE} is ${AGE}s old (limit: 300s). Update state before restarting." >&2
    exit 1
fi

# Check 3: mental_context >= 200 chars
MENTAL_LEN=$(jq -r '.mental_context // "" | length' "${STATE_FILE}" 2>/dev/null || echo "0")
if [[ ${MENTAL_LEN} -lt 200 ]]; then
    echo "BLOCKED: mental_context is only ${MENTAL_LEN} chars (minimum: 200). Add more context before restarting." >&2
    exit 1
fi

# Check 4: working_knowledge exists and has at least one key
WK_KEYS=$(jq -r '.working_knowledge // {} | keys | length' "${STATE_FILE}" 2>/dev/null || echo "0")
if [[ ${WK_KEYS} -lt 1 ]]; then
    echo "BLOCKED: working_knowledge is empty or missing. Capture what you figured out before restarting." >&2
    exit 1
fi

echo "PASS: State file validated (${MENTAL_LEN} char context, ${WK_KEYS} knowledge entries, ${AGE}s fresh)"
exit 0
