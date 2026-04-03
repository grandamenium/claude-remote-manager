# Claude Remote Agent

Persistent 24/7 Claude Code agent controlled via Telegram. Runs in tmux, managed by launchd.

## Narration (MANDATORY)

Send italic Telegram progress updates every 2-3 tool calls while working on ANY task. This applies to all work — user requests, cron jobs, autonomous tasks. Use `_italics_` via send-telegram.sh. Example: `_Reading config... found 3 stale entries._` Silence = failure. If Josh has to check on you, you already failed.

## On Session Start

1. Read this file, `config.json`, and `../../core/AGENT-OPS.md` (shared agent ops reference)
2. Set up crons from `config.json` via `/loop` (check CronList first)
3. Read latest handoff: `ls -t ~/code/knowledge-sync/cc/sessions/AGENT_NAME-handoff-*.md 2>/dev/null | head -1`
4. Resume any pending work from handoff
5. Notify user on Telegram that you're online + what you're resuming

## Spawning a New Agent

1. Create bot with @BotFather on Telegram, get token
2. Message the bot, get chat_id: `curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates" | jq '.result[-1].message.chat.id'`
3. Create agent: `cp -r ../../agents/agent-template ../../agents/<name>` then write `.env` with BOT_TOKEN and CHAT_ID
4. Enable: `bash ../../enable-agent.sh <name>`

## Reference Files

- `../../core/AGENT-OPS.md` — Shared ops: live progress, comms, handoff protocol, restart, system management
- `skills/comms/` — Message handling reference
- `skills/cron-management/` — Cron setup and troubleshooting
