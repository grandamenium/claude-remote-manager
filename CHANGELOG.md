# Changelog

## [Unreleased] — Windows Support

### Added (restart scripts port — 2026-04-05)
- `platform.sh`: `load_instance_id()` — CRLF-safe `.env` parser (prevents `\r` contamination on Windows)
- `platform.sh`: `parse_reason()` — proper `--reason` flag parser (replaces fragile positional arg parsing)
- `platform.sh`: `validate_agent_name()`, `validate_instance_id()`, `validate_crm_root()` — input sanitization guards (blocks command injection via agent names, path traversal via `../../`)
- `platform.sh`: `write_fresh_marker()`, `get_fresh_marker_path()` — secure marker management with `umask 077`
- `platform.sh`: `check_restart_cooldown()` — 30-second restart cooldown with lockfile (prevents restart loops)
- `platform.sh`: `is_agent_running()` — cross-platform agent health check (launchctl on macOS, PM2 on Windows)
- `platform.sh`: `restart_agent_hard()` — cross-platform hard restart abstraction (launchctl unload/load on macOS, PM2 restart + force-fresh marker on Windows)
- `platform.sh`: `restart_agent_soft()` — cross-platform soft restart abstraction (tmux send-keys on macOS, PM2 restart without marker on Windows)

### Changed (restart scripts port — 2026-04-05)
- **`hard-restart.sh`** — rewritten as thin caller to `restart_agent_hard()` (was macOS-only, now cross-platform)
- **`self-restart.sh`** — rewritten as thin caller to `restart_agent_soft()` (was macOS-only, now cross-platform)
- **`pm2_is_running()`** — replaced `jq` dependency with `pm2 describe` + `grep` (jq commonly absent in Git Bash)
- Platform existence checks (plist/PM2 process) now run before any state mutation (cooldown lock, force-fresh marker) to prevent stale state files on failure

### Security (restart scripts port — 2026-04-05)
- Agent names and instance IDs validated against `^[a-zA-Z0-9_-]+$` regex before use in shell commands (prevents command injection)
- Restart reasons sanitized via `tr '\n\r'` before log append (prevents log forging)
- Force-fresh markers created with `umask 077` (owner-only on POSIX systems)
- Corrupted cooldown lockfile content handled gracefully (non-numeric defaults to 0 instead of arithmetic error)

### Added
- **Windows support** — CortextOS now runs on Windows 10 (1809+) and Windows 11
- `core/scripts/platform.sh` — shared platform detection library (is_windows, is_macos, path conversion, inject dir helpers)
- `core/scripts/win-agent-wrapper.js` — Node.js PTY manager using node-pty (ConPTY), with built-in Telegram and inbox polling
- `core/scripts/generate-pm2.sh` — PM2 ecosystem config generator (Windows equivalent of generate-launchd.sh)
- `core/scripts/IPC-PROTOCOL.md` — typed command protocol specification for Windows message injection
- `ADR-001-windows-support.md` — architecture decision record documenting the PM2 + node-pty approach
- Platform-gated dependency checks in `install.sh` (node, pm2 on Windows; tmux on macOS)
- Auto-install of jq on Windows during `install.sh` (downloads from GitHub releases)
- Auto-install of node-pty on Windows during `install.sh` (npm install with prebuilt binaries)
- NTFS ACL hardening via `icacls` for inject queue directories on Windows
- Windows sections in README: requirements, quick start, architecture diagram, management commands, platform differences table
- PM2 post-install instructions for reboot persistence (`pm2 startup` + `pm2 save`)

### Changed
- **Graceful 71-hour restart** — both macOS and Windows now send a 5-minute warning before the session restart, giving Claude time to finish current work, save state, and notify the user. Previously, the restart happened immediately with no warning.
- `install.sh` — platform-gated dependency checks and auto-installation
- `setup.sh` — generates PM2 config on Windows, launchd plist on macOS; platform-specific post-setup instructions
- `enable-agent.sh` — uses `pm2 restart` on Windows, `launchctl load` on macOS
- `disable-agent.sh` — uses `pm2 stop/delete` on Windows, `launchctl unload` on macOS
- `core/scripts/agent-wrapper.sh` — delegates to `win-agent-wrapper.js` on Windows via `exec node`; exports `NODE_PATH` for node-pty resolution; uses `printf '%q'` for safe flag serialization
- `core/scripts/fast-checker.sh` — all 25 tmux calls platform-gated; Windows uses typed IPC command files + `jq -Rsc` for safe JSON encoding; `CHAT_ID` variable shadowing fixed
- `core/scripts/crash-alert.sh` — platform-gated respawn method in alert message (PM2 vs launchd)
- `core/bus/check-inbox.sh` — GNU `stat -c %Y` fallback for cross-platform mtime detection; word-splitting fix with `while IFS= read`
- `.gitignore` — added `.test/`, `.state/`, `node_modules/`

### Security
- All `execSync` calls with string interpolation replaced with `execFileSync` array form (prevents shell injection)
- `stripControlChars()` sanitizes all user-supplied content before PTY injection (prevents terminal escape sequence attacks)
- Telegram API callback IDs use `encodeURIComponent()` (prevents query string injection)
- NTFS ACLs applied idempotently via `icacls` (restricts inject queue to current user)
- `CHAT_ID` variable shadowing fixed in fast-checker.sh (prevents message routing to wrong chat)
- `isPlannedRestart` flag prevents 71-hour refresh from being counted as a crash
- HTTPS timeout handler with `req.destroy()` prevents stalled connection leaks

### Architecture
- **macOS path unchanged** — zero regressions to existing launchd + tmux architecture
- **Windows uses node-pty** instead of piped stdin/stdout (Claude Code's TUI requires a real TTY)
- **Telegram polling on Windows runs in Node.js** natively instead of bash (avoids Git Bash fork instability / cygheap corruption)
- **PM2 replaces launchd** for process management on Windows
- **File-based IPC** with typed JSON commands for external tool integration (hooks, AskUserQuestion)
