# Windows IPC Protocol — fast-checker.sh ↔ win-agent-wrapper.js

## Overview

On macOS, fast-checker.sh communicates with Claude Code via tmux commands
(send-keys, load-buffer, paste-buffer, capture-pane). On Windows, fast-checker.sh
writes typed JSON command files to a queue directory, and win-agent-wrapper.js
reads them and translates to pty.write() calls.

## Queue Directory

Location: `${CRM_ROOT}/inject/${AGENT}/`
Processed files: `${CRM_ROOT}/inject/${AGENT}/processed/`
Permissions: `chmod 700` (owner-only)

## Command File Format

Filename: `{epoch_ms}-{random}.cmd`
Content: Single line of JSON

### Command Types

#### inject — Paste text and submit (most common)
```json
{"type":"inject","content":"Hello, this is a message from Telegram"}
```
Wrapper action: `pty.write(content)` then `pty.write('\r')`

#### paste — Paste text without submitting
```json
{"type":"paste","content":"partial text"}
```
Wrapper action: `pty.write(content)` only (no Enter)

#### key — Send a single keystroke
```json
{"type":"key","key":"Enter"}
```
Supported keys: `Enter`, `Down`, `Up`, `Space`, `Escape`, `Tab`, `Backspace`
Wrapper action: map to appropriate escape sequence and `pty.write()`

Key mapping:
- Enter → `\r`
- Down → `\x1b[B`
- Up → `\x1b[A`
- Space → ` `
- Escape → `\x1b`
- Tab → `\t`
- Backspace → `\x7f`
- C-c → `\x03`

#### ctrl — Send a control character
```json
{"type":"ctrl","char":"c"}
```
Wrapper action: `pty.write(String.fromCharCode(char.charCodeAt(0) - 96))`

#### sequence — Send multiple operations atomically
```json
{"type":"sequence","ops":[{"type":"key","key":"Down"},{"type":"key","key":"Down"},{"type":"key","key":"Enter"}]}
```
Wrapper action: execute ops in order with 100ms delay between each

#### resize — Resize the PTY
```json
{"type":"resize","cols":120,"rows":30}
```
Wrapper action: `pty.resize(cols, rows)`

## Processing Rules

1. Watch directory using fs.watch (hint) + 2s setInterval (reconciliation)
2. Process `.cmd` files in sorted order (epoch prefix = chronological)
3. Validate JSON before executing (reject malformed commands)
4. Max file size: 1MB (reject larger with error log)
5. Move processed files to `processed/` subdirectory
6. Clean up `processed/` files older than 24h (hourly sweep)

## Readiness Detection

The wrapper uses a dual strategy to detect when Claude's TUI is ready:
1. win-agent-wrapper.js writes `${CRM_ROOT}/logs/${AGENT}/status` = `starting` at spawn
2. PTY output is scanned for the "permissions" indicator (same keyword macOS uses)
3. When detected, status is updated to `ready` immediately
4. Fallback: if "permissions" is never seen, status becomes `ready` after 30s
5. fast-checker.sh polls the status file instead of tmux capture-pane

Note: PTY output scanning is used ONLY for this one readiness signal. All other
control flow uses state files, PID files, and the IPC command queue — never
parsed terminal output.

## Session Liveness (NO tmux has-session)

1. win-agent-wrapper.js writes PID to `${CRM_ROOT}/logs/${AGENT}/claude.pid`
2. fast-checker.sh checks if PID is alive: `kill -0 $(cat pidfile) 2>/dev/null`
3. Alternative: check PM2 process status via `pm2 jlist`

## Logging

PTY output is streamed to `${CRM_ROOT}/logs/${AGENT}/stdout.log`
- Streaming write (append mode), never accumulated in memory
- No built-in log rotation — for long-running agents, this file will grow unbounded
- Used for debugging only, NOT for control flow (except the one-time readiness scan above)
- Used for debugging only, NOT for control flow (except the one-time readiness scan above)
