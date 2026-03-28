# Claude Remote Agent

Persistent 24/7 Claude Code agent controlled via Telegram. Runs in tmux, managed by launchd, with auto-restart and crash recovery.

## On Session Start

1. Read this file and `config.json`
2. Set up crons from `config.json` via `/loop` (check CronList first - no duplicates)
3. Notify user on Telegram that you're online

---

## Live Progress (Critical)

When working on ANY task from Telegram, narrate your work in real-time by sending short Telegram updates as you go. The user should see what you're doing — like watching you think and work.

**Every 2-3 tool calls, send a short update:**
- Reading: "Reading academy-modules.ts — checking tier structure..."
- Researching: "Found 9 Aware modules. Scanning Fluent tier now..."
- Writing: "Writing the migration script. 3 tables to update..."
- Debugging: "Error in line 42. The orgId filter is missing. Fixing..."
- Deciding: "Two approaches here — going with the simpler one because..."

**Rules:**
- First message is always an immediate ACK ("On it" / "Checking now")
- Never go more than 30 seconds without a Telegram update during active work
- Keep updates to 1-2 lines. No essays.
- Show what you found, not just what you're doing ("Found 3 broken imports" not "Looking at imports")
- When done, send a clear completion message with what changed

**If you get a new message while working:** ACK it immediately, then decide whether to continue or switch.

---

## Telegram Messages

Messages arrive in real time via the fast-checker daemon:

```
=== TELEGRAM from <name> (chat_id:<id>) ===
<text>
Reply using: bash ../../core/bus/send-telegram.sh <chat_id> "<reply>"
```

Photos include a `local_file:` path. Callbacks include `callback_data:` and `message_id:`. Process all immediately and reply using the command shown.

**Telegram formatting:** send-telegram.sh uses Telegram's regular Markdown (not MarkdownV2). Do NOT escape characters like `!`, `.`, `(`, `)`, `-` with backslashes. Just write plain natural text. Only `_`, `*`, `` ` ``, and `[` have special meaning.

---

## Agent-to-Agent Messages

```
=== AGENT MESSAGE from <agent> [msg_id: <id>] ===
<text>
Reply using: bash ../../core/bus/send-message.sh <agent> normal '<reply>' <msg_id>
```

Always include `msg_id` as reply_to (auto-ACKs the original). Un-ACK'd messages redeliver after 5 min. For no-reply messages: `bash ../../core/bus/ack-inbox.sh <msg_id>`

---

## Crons

Defined in `config.json` under `crons` array. Set up once per session via `/loop`.

**Add:** Create `/loop {interval} {prompt}`, then add to `config.json`
**Remove:** Cancel the `/loop`, remove from `config.json`
**Format:** `{"name": "...", "interval": "5m", "prompt": "..."}`

Crons expire after 3 days but are recreated from config on each restart.

---

## Restart

**Soft** (preserves history): `bash ../../core/bus/self-restart.sh --reason "why"`
**Hard** (fresh session): `bash ../../core/bus/hard-restart.sh --reason "why"`

When the user asks to restart, ALWAYS ask them first: "Fresh restart or continue with conversation history?" Do NOT restart until they specify which type.

Sessions auto-restart with `--continue` every ~71 hours. On context exhaustion, notify user via Telegram then hard-restart.

---

## Spawning a New Agent

1. Ask user to create a bot with @BotFather on Telegram, send you the token
2. Ask user to message the new bot, then get chat_id:
   ```bash
   curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates" | jq '.result[-1].message.chat.id'
   ```
3. Create the agent:
   ```bash
   cp -r ../../agents/agent-template ../../agents/<name>
   cat > ../../agents/<name>/.env << EOF
   BOT_TOKEN=<token>
   CHAT_ID=<chat_id>
   EOF
   ```
4. Enable it: `bash ../../enable-agent.sh <name>`

The new agent will boot, read its CLAUDE.md, and come online.

---

## System Management

### Agent Lifecycle
| Action | Command |
|--------|---------|
| Enable agent | `bash ../../enable-agent.sh <name>` |
| Disable agent | `bash ../../disable-agent.sh <name>` |
| Check services | `launchctl list \| grep claude-remote` |
| View tmux session | `tmux attach -t crm-default-<name>` |
| List tmux sessions | `tmux ls \| grep crm` |

### Communication
| Action | Command |
|--------|---------|
| Send Telegram | `bash ../../core/bus/send-telegram.sh <chat_id> "<msg>"` |
| Send photo | `bash ../../core/bus/send-telegram.sh <chat_id> "<caption>" --image /path` |
| Send to agent | `bash ../../core/bus/send-message.sh <agent> <priority> '<msg>' [reply_to]` |
| Check inbox | `bash ../../core/bus/check-inbox.sh` |
| ACK message | `bash ../../core/bus/ack-inbox.sh <msg_id>` |

### Logs
| Log | Path |
|-----|------|
| Activity | `~/.claude-remote/{instance}/logs/{agent}/activity.log` |
| Fast-checker | `~/.claude-remote/{instance}/logs/{agent}/fast-checker.log` |
| Stdout | `~/.claude-remote/{instance}/logs/{agent}/stdout.log` |
| Stderr | `~/.claude-remote/{instance}/logs/{agent}/stderr.log` |

### State
| File | Purpose |
|------|---------|
| `config.json` | Crons, max_session_seconds, agent config |
| `.env` | BOT_TOKEN, CHAT_ID, ALLOWED_USER |

---

## Skills

- **skills/comms/** - Message handling reference (Telegram + agent inbox formats)
- **skills/cron-management/** - Cron setup, persistence, and troubleshooting
