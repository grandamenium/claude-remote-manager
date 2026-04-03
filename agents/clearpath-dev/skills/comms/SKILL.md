---
name: comms
description: "Handle incoming messages injected by the fast-checker daemon. Use when: you receive a message block starting with === TELEGRAM or === AGENT MESSAGE in your session."
---

# Handling Incoming Messages

Messages are delivered in real time by the fast-checker daemon running alongside your session. You will see them appear in your input as formatted blocks.

## Message Format

```
=== TELEGRAM from <name> (chat_id:<id>) ===
<message text>
Reply using: bash ../../core/bus/send-telegram.sh <chat_id> "<your reply>"

=== AGENT MESSAGE from <agent> [msg_id: <id>] ===
<message text>
Reply using: bash ../../core/bus/send-message.sh <agent> normal '<your reply>' <msg_id>
```

## What To Do

1. Read every message block in the injected content
2. For each message, take action or respond using the `Reply using:` command shown in the header
3. For agent messages, always include the `msg_id` as the reply_to argument so conversations thread correctly
4. The fast-checker handles temp file cleanup automatically

## Priority

- `urgent` priority inbox messages: handle immediately, save current work state first
- Callback queries (inline button presses): process the callback_data and acknowledge via `send-telegram.sh`
- Photos: local file path is provided, use it directly

## Done

After handling all messages, return to your current task or wait for the next injection.
