# Changelog

## [Unreleased] — Windows Support

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
