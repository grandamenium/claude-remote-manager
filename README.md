# Claude Remote Manager

Persistent 24/7 Claude Code agents controlled from Telegram. Full feature support — permissions, plan mode, AskUserQuestion, scheduled tasks, auto-restart, multi-agent communication.

**Works on macOS and Windows.**

## What This Does

- Run Claude Code sessions that never die (auto-restart every 71 hours)
- Control everything from your phone via Telegram
- Approve/deny permissions from Telegram (no need to be at your computer)
- Answer Claude's questions from Telegram (single-select, multi-select, multi-question)
- Approve/deny plans from Telegram
- Scheduled tasks via cron loops that survive restarts
- Spin up multiple agents that talk to each other via a message bus
- Built-in CLI command support (`/compact`, `/clear`, etc. from Telegram)

## Requirements

### macOS
- macOS 10.15+
- Claude Code CLI installed and authenticated
- tmux (`brew install tmux`)
- jq (`brew install jq`)
- A Telegram bot token (free from @BotFather)

### Windows
- Windows 10 (1809+) or Windows 11
- [Git for Windows](https://git-scm.com/download/win) (provides Git Bash)
- Claude Code CLI installed and authenticated
- Node.js 18+ (https://nodejs.org/)
- PM2 (`npm install -g pm2`)
- jq (auto-installed by `install.sh` if missing)
- A Telegram bot token (free from @BotFather)

> **How it works on Windows:** Instead of tmux, Windows uses [node-pty](https://github.com/microsoft/node-pty) (Microsoft's ConPTY wrapper) to provide a real terminal for Claude Code's TUI. PM2 replaces launchd for process management. Telegram polling runs natively in Node.js instead of bash to avoid Git Bash fork instability.

## Quick Start

### macOS
```bash
git clone https://github.com/grandamenium/claude-remote-manager.git
cd claude-remote-manager
./install.sh
./setup.sh
```

### Windows (in Git Bash)
```bash
git clone https://github.com/grandamenium/claude-remote-manager.git
cd claude-remote-manager
./install.sh
./setup.sh
```

`setup.sh` walks you through:
- Naming your agent
- Creating a Telegram bot with @BotFather
- Configuring the bot token and chat ID
- Generating the service (launchd on macOS, PM2 on Windows)
- Starting the agent

Once running, message your Telegram bot and Claude responds.

> **First-time setup:** On first boot, Claude Code may prompt you to trust the agent directory. On macOS, attach to the tmux session (`tmux attach -t crm-default-<agent-name>`), approve the trust prompt, then detach with `Ctrl-b d`. On Windows, check PM2 logs (`pm2 logs crm-default-<agent-name>`) — you may need to run `claude` manually once to accept terms. This only happens once per agent directory.

## How It Works

### macOS
```
You (Telegram) <-> fast-checker.sh (polls Telegram) <-> tmux session <-> Claude Code
                                                              ^
                                                         launchd (keeps alive)
```

### Windows
```
You (Telegram) <-> win-agent-wrapper.js (polls Telegram natively) <-> node-pty <-> Claude Code
                                                                          ^
                                                                     PM2 (keeps alive)
```

### Lifecycle

1. **launchd** (macOS) or **PM2** (Windows) starts `agent-wrapper.sh`
2. On macOS, a tmux session is created and Claude Code runs inside it
3. On Windows, `win-agent-wrapper.js` spawns Claude in a node-pty PTY (ConPTY)
4. **Message polling** checks Telegram every few seconds for new messages:
   - macOS: `fast-checker.sh` (bash) polls and injects via `tmux send-keys`
   - Windows: `win-agent-wrapper.js` polls natively via Node.js `https` and writes directly to the PTY
5. When Claude needs permission, a hook sends the prompt to Telegram with Approve/Deny buttons
6. If Claude crashes, launchd/PM2 restarts everything automatically
7. Every ~71 hours, the session soft-restarts with `--continue` to stay fresh

### Graceful 71-Hour Restart

Claude Code's `/loop` crons expire after 72 hours. To keep them active, the agent soft-restarts every 71 hours:

1. **5 minutes before restart:** Claude receives a warning message: *"SESSION RESTART in 5 minutes. Finish your current task, save your work, and report your status."*
2. **At restart:** The current Claude process is stopped and a new one starts with `--continue`, preserving full conversation history
3. **After restart:** Claude re-reads its bootstrap files, re-registers crons, checks inbox, and resumes operations

This ensures no work is lost mid-task. Claude has time to finish what it's doing, save state, and notify the user before the restart happens.

## Project Structure

```
claude-remote-manager/
├── core/
│   ├── bus/                       # Message bus (Telegram, inbox, hooks)
│   ├── scripts/
│   │   ├── agent-wrapper.sh       # Agent lifecycle (delegates to platform-specific code)
│   │   ├── fast-checker.sh        # Telegram + inbox poller (macOS: bash, Windows: platform-gated)
│   │   ├── platform.sh            # [NEW] Shared platform detection (is_windows, is_macos, path helpers)
│   │   ├── win-agent-wrapper.js   # [NEW] Windows PTY manager + native Telegram poller
│   │   ├── generate-launchd.sh    # macOS: launchd plist generator
│   │   ├── generate-pm2.sh        # [NEW] Windows: PM2 ecosystem config generator
│   │   ├── crash-alert.sh         # SessionEnd crash notification
│   │   └── IPC-PROTOCOL.md        # [NEW] Windows IPC command specification
│   └── skills/                    # Core skills (comms, cron-management)
├── agents/
│   └── agent-template/            # Default agent template
│       ├── CLAUDE.md              # Agent instructions
│       ├── .claude/settings.json  # Hook configuration
│       ├── config.json            # Crons and settings
│       └── skills/                # Agent-local skills
├── install.sh                     # Create state directories (+ node-pty on Windows)
├── setup.sh                       # Interactive agent onboarding
├── enable-agent.sh                # Start an agent
├── disable-agent.sh               # Stop an agent
└── ADR-001-windows-support.md     # [NEW] Architecture decision record
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

### macOS
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

### Windows
```bash
# Check running agents
pm2 list

# View agent logs (live)
pm2 logs crm-default-<agent-name>

# View PTY output (what Claude sees)
tail -f ~/.claude-remote/default/logs/<agent-name>/stdout.log

# Stop an agent
./disable-agent.sh <agent-name>

# Restart an agent
./enable-agent.sh <agent-name> --restart

# View activity logs
tail -f ~/.claude-remote/default/logs/<agent-name>/activity.log

# PM2 monitoring dashboard
pm2 monit
```

### Windows Post-Install (Required)
After installation, run these once to ensure PM2 survives reboots:
```bash
pm2 startup    # Follow the printed instructions
pm2 save       # Save current process list
```

> **Important:** Set your Windows power plan to "Never sleep" if you want true 24/7 operation. Windows will suspend PM2 agents during sleep/hibernate.

## Platform Differences

| Feature | macOS | Windows |
|---------|-------|---------|
| Process manager | launchd | PM2 |
| Terminal session | tmux | node-pty (ConPTY) |
| Telegram polling | fast-checker.sh (bash) | win-agent-wrapper.js (Node.js native) |
| Message injection | tmux send-keys | pty.write() |
| Dependencies | tmux, jq | Node.js, PM2, jq, node-pty (auto-installed) |
| Sleep prevention | caffeinate | Manual (power plan setting) |
| Attach to session | `tmux attach -t ...` | `pm2 logs ...` (view only) |

## Onboarding Skill

If you're already in a Claude Code session inside this repo, run:

```
/claude-remote-manager-setup
```

This walks you through the full setup interactively.

## Security Considerations

This system runs Claude Code sessions with full access to your machine. Here's what to be aware of:

**Telegram authentication** — Each agent filters messages by `ALLOWED_USER` (your Telegram user ID). Only messages from your account are processed. If `ALLOWED_USER` is not configured, the agent rejects all messages. Keep your Telegram account secured with two-factor authentication.

**Bot tokens** — Your Telegram bot tokens are stored in `.env` files which are gitignored by default. Never commit `.env` files to version control. If a token is compromised, revoke it immediately via @BotFather and generate a new one.

**Headless permissions** — Agents run with `--dangerously-skip-permissions` because Claude Code requires this for non-interactive operation. This means the agent can read and write files, run commands, and access network resources without per-action approval. The Telegram-based permission hooks provide an additional layer of oversight for sensitive operations, but they are advisory rather than enforced at the CLI level.

**Input sanitization** — Telegram usernames are sanitized to alphanumeric characters only. Message content is wrapped in code blocks before injection to reduce parsing ambiguity. On Windows, terminal control characters and ANSI escape sequences are stripped from all user-supplied content before PTY injection. Built-in CLI commands (`/compact`, `/clear`, etc.) are matched against a strict whitelist.

**File permissions** — On macOS, temporary files and state directories use `chmod 700`/`chmod 600` (owner-only). On Windows, NTFS ACLs are applied via `icacls` to restrict the inject queue directory to the current user. State directories at `~/.claude-remote/` inherit your user permissions.

**Multi-agent messaging** — The inter-agent inbox system is file-based and scoped to your user account. Messages between agents are not encrypted at rest but are only accessible to your user account on the local filesystem.

**Recommendations:**
- Enable two-factor authentication on your Telegram account
- Review agent CLAUDE.md instructions to understand what each agent is authorized to do
- Monitor agent logs periodically (`~/.claude-remote/default/logs/`)
- Use separate Telegram bots for each agent so you can revoke access individually

## License

MIT
