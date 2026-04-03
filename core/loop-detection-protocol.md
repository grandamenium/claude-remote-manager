# Agent Loop Detection Protocol

## Problem

Agents get stuck retrying the same failing action (e.g., `git push` failing 5x in a row) or juggling too many tasks without progress. External heartbeats (launchd PID checks) only detect dead agents, not stuck ones.

## Architecture

```
Domain Agent → self-reports → LARRY (engineering lead) → escalates → FRANK (fleet commander)
```

### 1. Agent Self-Monitoring (every agent's CLAUDE.md)

Add to each agent's CLAUDE.md:

```
## Loop Detection

Track your last 3 tool calls mentally. If you notice:
- Same tool + same target + failure 3x in a row → STOP. Do not retry.
- Same task described in 3 consecutive heartbeats with no measurable progress → STOP.
- More than 3 tasks open simultaneously → Pick ONE, park the rest in pending_tasks.

When stopped:
1. Write current state to your state.json (what failed, what you tried, error messages)
2. Send to LARRY: "LOOP_DETECTED agent=<you> action=<what failed> attempts=<N> error=<summary>"
3. Move to next pending task or idle. Do NOT re-attempt the failed action.
```

### 2. LARRY Aggregation

LARRY runs a fleet-health cron (every 15m) that:
- Checks agent message bus for LOOP_DETECTED messages
- Reads each agent's state.json for `status: blocked` or stale `current_task`
- Attempts diagnosis: is it a transient error (retry once) or persistent (escalate)?

LARRY actions:
- **Transient** (network timeout, API rate limit): Wait 5 min, retry once via agent message
- **Persistent** (auth failure, missing env var, code bug): Escalate to FRANK with diagnosis
- **Context exhaustion** (agent restarting every 15 min): Flag for FRANK to investigate CLAUDE.md or handoff issues

### 3. FRANK Escalation

FRANK receives LARRY's report and:
- **Auto-fix**: Restart agent, clear stuck state, send corrected instructions
- **Escalate to Josh**: Only for issues requiring human action (missing API keys, auth tokens, business decisions)

### 4. Message Bus Format

```
Agent → LARRY:
LOOP_DETECTED agent=auditos-dev action="git push origin main" attempts=3 error="remote: Permission denied" since=2026-03-31T02:30:00Z

LARRY → FRANK:
FLEET_ALERT agent=auditos-dev type=persistent_failure action="git push" diagnosis="SSH key or permission issue" recommendation="check deploy keys"

FRANK → Josh (Telegram):
"auditos-dev stuck on git push — permission denied 3x. Likely SSH key issue. Can you check deploy keys for clearworks-ai/auditos?"
```

### 5. State.json Additions

Each agent's state.json gets a new field:

```json
{
  "loop_guard": {
    "last_3_actions": [
      {"tool": "Bash", "target": "git push origin main", "result": "fail", "at": "ISO"},
      {"tool": "Bash", "target": "git push origin main", "result": "fail", "at": "ISO"},
      {"tool": "Bash", "target": "git push origin main", "result": "fail", "at": "ISO"}
    ],
    "loop_detected_at": "ISO or null",
    "escalated_to": "larry or frank or null"
  }
}
```

### 6. Multi-Task Guard

Agents must not work on more than 2 tasks simultaneously. Rule for CLAUDE.md:

```
## Task Discipline

- Maximum 2 active tasks. All others go to pending_tasks in state.json.
- Finish or explicitly park a task before starting a new one.
- "Park" means: write what you learned to state.json working_knowledge, set status to "parked", move to pending.
- When Josh sends a new task while you're working: ACK it, add to pending, finish current task first (unless Josh says "drop everything").
```

## Implementation Order

1. **Now**: Add Loop Detection and Task Discipline sections to all agent CLAUDE.md files
2. **Phase 2**: LARRY aggregation cron (requires LARRY agent to be operational)
3. **Phase 3**: Automated state.json loop_guard tracking (requires hook or wrapper)
