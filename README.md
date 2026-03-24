# Claude Remote Manager

Persistent 24/7 Claude Code agents controlled from Telegram. Full feature support - permissions, plan mode, AskUserQuestion, scheduled tasks, auto-restart, multi-agent communication.

## What This Does

- Run Claude Code sessions that never die (launchd + tmux + auto-restart every 71 hours)
- Control everything from your phone via Telegram
- Approve/deny permissions from Telegram (no need to be at your computer)
- Answer Claude's questions from Telegram (single-select, multi-select, multi-question)
- Approve/deny plans from Telegram
- Scheduled tasks via cron loops that survive restarts
- Spin up multiple agents that talk to each other via a message bus
- Built-in CLI command support (`/compact`, `/clear`, etc. from Telegram)

## Requirements

- macOS (uses launchd for persistence)
- Claude Code CLI installed
- tmux (`brew install tmux`)
- jq (`brew install jq`)
- A Telegram bot token (free from @BotFather)

## Quick Start

```bash
# 1. Clone
git clone https://github.com/grandamenium/claude-remote-manager.git
cd claude-remote-manager

# 2. Install (creates state directories)
./install.sh

# 3. Set up your first agent
./setup.sh
```

`setup.sh` walks you through:
- Naming your agent
- Creating a Telegram bot with @BotFather
- Configuring the bot token and chat ID
- Generating the launchd service
- Starting the agent

Once running, message your Telegram bot and Claude responds.

> **First-time setup:** On first boot, Claude Code may prompt you to trust the agent directory. If your agent doesn't come online, attach to the tmux session (`tmux attach -t crm-default-<agent-name>`), approve the trust prompt, then detach with `Ctrl-b d`. This only happens once per agent directory.

## How It Works

```
You (Telegram) <-> fast-checker (polls Telegram) <-> tmux session <-> Claude Code
                                                         ^
                                                    launchd (keeps alive)
```

1. **launchd** starts `agent-wrapper.sh` which creates a tmux session and launches Claude Code inside it
2. **fast-checker** runs alongside, polling Telegram every few seconds for new messages
3. When you send a message, fast-checker injects it into the tmux session
4. When Claude needs permission, a hook sends the prompt to Telegram with Approve/Deny buttons
5. If Claude crashes, launchd restarts everything automatically
6. Every ~71 hours, the session soft-restarts with `--continue` to stay fresh

## Project Structure

```
claude-remote-manager/
├── core/                          # Framework infrastructure
│   ├── bus/                       # Message bus (Telegram, inbox, hooks)
│   ├── scripts/                   # Agent lifecycle (wrapper, fast-checker, launchd)
│   └── skills/                    # Core skills (comms, cron-management)
├── agents/
│   └── agent-template/            # Default agent template
│       ├── CLAUDE.md              # Agent instructions
│       ├── .claude/settings.json  # Hook configuration
│       ├── config.json            # Crons and settings
│       └── skills/                # Agent-local skills
├── install.sh                     # Create state directories
├── setup.sh                       # Interactive agent onboarding
├── enable-agent.sh                # Start an agent
└── disable-agent.sh               # Stop an agent
```

## Multi-Agent Setup

Your first agent can spawn more agents directly from Telegram:

1. Tell your agent "create a new agent called devbot"
2. It asks you to create a bot with @BotFather and send the token
3. It configures and starts the new agent
4. Both agents can message each other via the inbox system

## Agent Commands

From inside an agent session:

| Action | Command |
|--------|---------|
| Send Telegram message | `bash ../../core/bus/send-telegram.sh <chat_id> "<msg>"` |
| Send to another agent | `bash ../../core/bus/send-message.sh <agent> <priority> '<msg>'` |
| Soft restart | `bash ../../core/bus/self-restart.sh --reason "why"` |
| Hard restart | `bash ../../core/bus/hard-restart.sh --reason "why"` |

## Management

```bash
# Check running agents
launchctl list | grep claude-remote

# View an agent's tmux session
tmux attach -t crm-default-<agent-name>

# Stop an agent
./disable-agent.sh <agent-name>

# Restart an agent
./disable-agent.sh <agent-name> && ./enable-agent.sh <agent-name>

# View logs
tail -f ~/.claude-remote/default/logs/<agent-name>/activity.log
```

## Onboarding Skill

If you're already in a Claude Code session inside this repo, run:

```
/claude-remote-manager-setup
```

This walks you through the full setup interactively.

## Security Considerations

This system runs Claude Code sessions with full access to your machine. Here's what to be aware of:

**Telegram authentication** - Each agent filters messages by `ALLOWED_USER` (your Telegram user ID). Only messages from your account are processed. If `ALLOWED_USER` is not configured, the agent rejects all messages. Keep your Telegram account secured with two-factor authentication.

**Bot tokens** - Your Telegram bot tokens are stored in `.env` files which are gitignored by default. Never commit `.env` files to version control. If a token is compromised, revoke it immediately via @BotFather and generate a new one.

**Headless permissions** - Agents run with `--dangerously-skip-permissions` because Claude Code requires this for non-interactive operation. This means the agent can read and write files, run commands, and access network resources without per-action approval. The Telegram-based permission hooks provide an additional layer of oversight for sensitive operations, but they are advisory rather than enforced at the CLI level.

**Input sanitization** - Telegram usernames are sanitized to alphanumeric characters only. Message content is wrapped in code blocks before injection to reduce parsing ambiguity. Built-in CLI commands (`/compact`, `/clear`, etc.) are matched against a strict whitelist.

**File permissions** - Temporary files and response files are created with `600` permissions (owner-only read/write). State directories at `~/.claude-remote/` inherit your user permissions.

**Multi-agent messaging** - The inter-agent inbox system is file-based and scoped to your user account. Messages between agents are not encrypted at rest but are only accessible to your user account on the local filesystem.

**Recommendations:**
- Enable two-factor authentication on your Telegram account
- Review agent CLAUDE.md instructions to understand what each agent is authorized to do
- Monitor agent logs periodically (`~/.claude-remote/default/logs/`)
- Use separate Telegram bots for each agent so you can revoke access individually

## License

MIT
