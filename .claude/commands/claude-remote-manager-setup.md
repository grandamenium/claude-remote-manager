---
name: claude-remote-manager-setup
description: When setting up this project use this skill as onboarding
---

You are guiding the user through a complete interactive onboarding for claude-remote-manager. Walk through each step below in order, checking results before proceeding. Explain everything in casual plain English. If any step fails, diagnose and fix before moving on.

---

## Step 1: Welcome & System Overview

Start by explaining what this system does in plain English:

- **Persistent 24/7 sessions** - Claude Code runs on your computer 24/7, 365 with automatic recovery and continuing sessions so it never loses context.
- **Telegram** - Text back and forth with Claude Code through Telegram with all the features you love: plan mode, permissions, AskUserQuestion tool, and more.
- **Auto-restart** - Scheduled and recurring tasks are automatically reset every 71 hours to get around Claude's native limitations. Now you have fully persistent scheduled tasks, reminders, and recurring tasks.
- **Auto-continue on crash** - Claude Remote Manager is configured to automatically restart your sessions if anything goes wrong, for 24/7 uptime.
- **Scheduled tasks** - Just ask Claude Code to create a scheduled task, recurring task, or reminder and it will execute workflows proactively however you instruct it with no limitations. These are completely persistent, not limited to 3 days.
- **Multi-agent support** - You can run as many remote sessions as you want, and they have a full messaging system to communicate between each other however you want. Scheduling workflows to have your agents brainstorm together is recommended!
- **Spin up new agents** - If you ever want to create a new remote Claude agent, just ask your existing one to do so and it already knows how. You can have this session exist without a Telegram channel and just chat back and forth with your existing agent. This is a full Claude Code session, not a subagent. You can also create a new bot token to chat with this agent directly.
- **Tmux attaching** - Use the provided tmux attach commands in a terminal session to clock into your usual interactive terminal session with any of your remote agents when you're at your computer for normal usage.

Ask the user if they're ready to proceed.

---

## Step 2: Dependency Check

Check each dependency and install if missing. Run these checks:

1. **claude CLI** - Run `which claude`. If not found, tell the user to install it from https://docs.anthropic.com/en/docs/claude-code and come back.
2. **tmux** - Run `which tmux`. If not found, run `brew install tmux`.
3. **jq** - Run `which jq`. If not found, run `brew install jq`.
4. **curl** - Run `which curl`. Should already exist on macOS.
5. **macOS check** - Run `uname` and verify it says "Darwin". launchd is macOS only - if they're on Linux, warn them that launchd won't work and they'd need to adapt the service management.
6. **Claude version** - Run `claude --version` and show it to the user. Just confirm it's a recent version.

Report results for each check. If anything needs installing, do it and verify it succeeded.

---

## Step 3: Install

Run the install script to create the state directories:

```bash
cd ~/Projects/claude-remote-manager && bash install.sh
```

This creates `~/.claude-remote/default/` with subdirectories for inbox, outbox, logs, state, etc. Show the user the output. If it says "already exists", that's fine - explain they can either use the existing install or remove it and re-run.

---

## Step 4: First Agent Setup

Walk through these sub-steps interactively:

### 4a. Agent Name
Ask the user what they want to name their first agent. Suggest "assistant" as a sensible default. The name should be lowercase with no spaces (hyphens are ok).

### 4b. Create a Telegram Bot
Guide them through creating a Telegram bot:
1. Open Telegram on their phone or desktop
2. Search for **@BotFather** and start a chat
3. Send `/newbot`
4. BotFather will ask for a display name - they can pick anything (e.g., "My Claude Assistant")
5. BotFather will ask for a username - must end in "bot" (e.g., "my_claude_assistant_bot")
6. BotFather will reply with an HTTP API token - tell them to copy it

### 4c. Paste Bot Token
Ask the user to paste their bot token. Store it in a variable.

### 4d. Get Chat ID
Tell the user they MUST send any message (even just "hi") to their new bot on Telegram FIRST. This is required so the Telegram API has an update to read.

After they confirm they've sent a message, use curl to auto-detect their chat_id:

```bash
curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates" | jq '.result[0].message.chat.id'
```

If no result comes back, tell them to send another message and try again. Also extract the user ID from `.result[0].message.from.id` for the ALLOWED_USER field.

After extracting chat_id and user_id, flush the Telegram offset so the agent doesn't respond to these setup messages when it boots:

```bash
# Get the latest update_id and acknowledge it
LATEST=$(curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates" | jq '.result[-1].update_id + 1')
curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates?offset=${LATEST}" > /dev/null
```

### 4e. Create Agent Directory
Copy the template and configure it:

```bash
cp -r ~/Projects/claude-remote-manager/agents/agent-template ~/Projects/claude-remote-manager/agents/<agent_name>
```

### 4f. Write the .env File
Write the .env file to the new agent directory:

```
BOT_TOKEN=<the token they pasted>
CHAT_ID=<the chat_id from getUpdates>
ALLOWED_USER=<the user_id from getUpdates>
```

### 4g. Update config.json
Update the agent's config.json to set the agent_name field:

```bash
cd ~/Projects/claude-remote-manager && jq --arg name "<agent_name>" '.agent_name = $name' "agents/<agent_name>/config.json" > /tmp/config_tmp.json && mv /tmp/config_tmp.json "agents/<agent_name>/config.json"
```

### 4h. Generate launchd plist and enable
Run the generate-launchd and enable-agent scripts:

```bash
cd ~/Projects/claude-remote-manager && bash core/scripts/generate-launchd.sh <agent_name>
cd ~/Projects/claude-remote-manager && bash enable-agent.sh <agent_name>
```

---

## Step 5: Test the First Agent

Wait about 10 seconds for the agent to boot up, then verify:

1. **Check tmux session** - Run `tmux ls | grep crm` and confirm a session named `crm-default-<agent_name>` exists.
2. **Check launchd service** - Run `launchctl list | grep claude-remote` and confirm the service is loaded.
3. **Test Telegram** - Tell the user to send "hello" to their Telegram bot and wait for a response. The agent needs a minute or two to fully bootstrap (read CLAUDE.md, set up crons, etc.) before it starts responding.

If tmux session doesn't exist, check the logs at `~/.claude-remote/default/logs/<agent_name>/activity.log` and `~/.claude-remote/default/logs/<agent_name>/fast-checker.log` to diagnose.

**If the agent isn't responding:** Claude Code may be waiting for a directory trust approval. Tell the user to attach to the tmux session and check:

```
tmux attach -t crm-default-<agent_name>
```

If they see a "Do you trust the files in this folder?" prompt, approve it, then detach with `Ctrl-b d`. The agent will continue booting. This only happens once per agent directory.

If the test passes, congratulate them and IMMEDIATELY continue to Step 6 below. Do NOT wait for the user to confirm the Telegram test - just proceed.

---

## Step 6: You're Live - Here's What You Can Do

IMPORTANT: Always show this section. Do not stop at Step 5. Present this entire section to the user right after confirming tmux and launchd are running.

**Telegram is your remote control.** Everything you'd normally do in the terminal, you can now do from your phone:

- **Ask it to do anything** - Code, research, file management, git operations - same Claude Code you're used to, just through Telegram
- **Approve permissions from your phone** - When Claude needs to edit a file or run a command, you get Approve/Deny buttons right in Telegram. No need to be at your computer
- **Review plans remotely** - Claude can enter plan mode and send you the plan to approve or deny from Telegram
- **Answer questions** - When Claude needs your input (single choice, multi-select, or multi-step questions), it shows up as tappable buttons in Telegram
- **Scheduled tasks that actually persist** - Tell your agent "check for new PRs every 30 minutes" or "send me a daily summary at 9am" and it just works. Tasks survive crashes and restarts automatically
- **Spin up more agents from Telegram** - Just message your agent "create a new agent called devbot" and it walks you through creating another bot with @BotFather. Now you have two persistent agents that can message each other
- **Agent-to-agent workflows** - Your agents have a built-in messaging system. You can have one agent delegate tasks to another, have them brainstorm together on a schedule, or build any multi-agent workflow you want
- **Use CLI commands from Telegram** - Send `/compact`, `/clear`, or other built-in commands directly from Telegram chat

**One thing to know:** To jump into the full terminal experience with any agent, run:
```
tmux attach -t crm-default-<agent_name>
```

**Ideas to try:**
- "Set up a cron every hour to check my GitHub notifications and summarize them"
- "Create a second agent and have it research competitors while you work on code"
- "Monitor a log file and alert me on Telegram if errors spike"
- "Run my test suite every 2 hours and message me if anything breaks"
- "Check my email every 30 minutes and draft replies for me to review"

That's it - you're all set. Your agent is running 24/7 and you can control it from anywhere.
