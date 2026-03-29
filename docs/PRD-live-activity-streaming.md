# PRD: Live Activity Streaming to Telegram

## Problem

When an agent processes a message, the user sees "typing..." for up to 5 minutes with no visibility into what's happening. The only feedback is a generic "Got it, processing..." auto-reply. This is frustrating — the user can't tell if the agent is stuck, doing something useful, or about to finish.

## Solution

Enhance fast-checker.sh to capture the agent's live activity from the tmux pane and forward condensed status updates to Telegram while the agent is working.

## How It Works Today

```
User sends message → fast-checker injects into tmux → typing indicator every 5s → agent responds
```

The fast-checker already:
- Captures the tmux pane via `tmux capture-pane` every 1s poll cycle
- Tracks `HUMAN_MSG_PENDING` state (knows when a human message is being processed)
- Sends typing indicators every 5s while agent is busy
- Detects idle state via `is_agent_idle()` (checks for `>` prompt)

## Proposed Flow

```
User sends message → fast-checker injects into tmux
→ While HUMAN_MSG_PENDING:
  - Every 5s: capture pane, extract current activity
  - If activity changed since last update: send condensed status to Telegram
  - Otherwise: send typing indicator (existing behavior)
→ Agent responds (existing flow)
```

## Implementation

### 1. Activity Extractor Function

New function in fast-checker.sh: `extract_activity()`

Captures the tmux pane and parses Claude Code's output format to detect:

| Pane Pattern | Status Message |
|---|---|
| `Read <path>` | `Reading {filename}...` |
| `Bash: <desc>` or `$ <cmd>` | `Running: {description or cmd}` |
| `Grep` / `Glob` | `Searching codebase...` |
| `Write <path>` | `Writing {filename}...` |
| `Edit <path>` | `Editing {filename}...` |
| `Agent` | `Dispatching sub-agent...` |
| `WebSearch` / `WebFetch` | `Searching the web...` |
| `mcp__google-workspace__search_gmail` | `Checking Gmail...` |
| `mcp__google-workspace__get_events` | `Checking calendar...` |
| `send-telegram.sh` | (skip — don't echo telegram sends) |
| Spinner / progress text | `Working...` |

### 2. State Tracking

```bash
LAST_ACTIVITY=""          # last status sent
ACTIVITY_UPDATE_INTERVAL=8  # min seconds between status messages
LAST_ACTIVITY_SENT=0      # timestamp
```

Only send when:
- `HUMAN_MSG_PENDING == true` (user is waiting)
- Activity text changed from `LAST_ACTIVITY`
- At least `ACTIVITY_UPDATE_INTERVAL` seconds since last status
- Activity is not a telegram send (avoid echo loops)

### 3. Telegram Format

Status updates sent as plain text, no notification sound:

```
🔍 Searching Gmail...
```

Single emoji prefix + short description. Uses `disable_notification: true` so the user sees it in-chat but doesn't get pinged per update.

### 4. Configuration

New fields in agent `config.json`:

```json
{
  "activity_streaming": true,
  "activity_interval_seconds": 8
}
```

Defaults: `activity_streaming: false`, `activity_interval_seconds: 8`. Opt-in per agent.

### 5. Integration Points

All changes in one file: `core/scripts/fast-checker.sh`

- New function: `extract_activity()` (~30 lines)
- New function: `send_activity_update()` (~15 lines)
- Modified section: typing indicator block (lines 607-634) — add activity extraction before typing send
- New state vars: 3 variables at top of file

### 6. Edge Cases

| Case | Handling |
|---|---|
| Agent sends its own Telegram reply | Pattern-match `send-telegram.sh` in pane → skip, don't echo |
| Rapid tool calls (<1s each) | Throttled by `ACTIVITY_UPDATE_INTERVAL` — only latest shown |
| Agent idle but no response yet | Falls through to existing typing indicator |
| Pane capture fails | Graceful fallback to typing indicator only |
| Very long tool descriptions | Truncate to 60 chars |
| Agent working on cron (no human msg) | No streaming — only activates when `HUMAN_MSG_PENDING` |

## Scope

- **In scope:** fast-checker enhancement, config flag, Telegram status messages
- **Out of scope:** Clearpath command center integration (separate feature), web UI streaming, historical activity log

## Effort

~50 lines of bash added to fast-checker.sh. No new files, no new dependencies. Config flag makes it opt-in. Testable by enabling on Frank and sending a multi-step request.

## Success Criteria

When Josh sends a message that triggers multi-step work, he sees 2-4 brief status updates in Telegram showing what the agent is doing, instead of just "typing..." for minutes.
