# ADR-001: Windows Support for CortextOS (claude-remote-manager)

**Status:** Accepted
**Date:** 2026-04-02
**Deciders:** Steven Vasquez (project owner), upstream maintainer (grandamenium)

## Context

CortextOS is a system for running persistent 24/7 Claude Code agents controlled via Telegram. It currently only supports macOS, using launchd for process keep-alive and tmux for persistent terminal sessions with message injection.

We need Windows support because:
- Our primary development machine runs Windows 11
- The upstream project has expressed need for a Windows port
- Claude Code CLI works on Windows with full feature parity
- PM2 (Node.js process manager) provides equivalent keep-alive functionality on Windows
- Git Bash (MSYS2) provides a compatible bash environment for the existing scripts

## Requirements Summary
- **Functional:** All CortextOS features working on Windows — persistent agents, Telegram control, permissions, plan mode, AskUserQuestion, scheduled tasks, multi-agent messaging, crash recovery
- **Compatibility:** Zero changes to existing macOS behavior — all modifications are additive
- **Shell:** Git Bash (MSYS2) on Windows — all scripts must work in this environment
- **Dependencies:** Node.js 18+, PM2, jq, Claude Code CLI, Git Bash
- **PR-ready:** Clean enough for upstream contribution

## Options Considered

### Option A: PM2 + Node.js stdin wrapper (Recommended)

Replace launchd with PM2 for process management. Replace tmux with a Node.js wrapper that spawns Claude Code as a child process with piped stdin/stdout, using file-based message injection.

| Dimension | Assessment |
|-----------|------------|
| Complexity | Medium — 3 new files, 8 modified files |
| Cost | Free (PM2 is MIT, already installed) |
| Scalability | Same as macOS — multiple agents via PM2 process list |
| Team Familiarity | High — Node.js is our primary scripting language |
| Time to Implement | 4-6 hours |

**Pros:**
- PM2 is battle-tested, handles auto-restart, log rotation, process monitoring
- Node.js child_process gives full control over stdin/stdout piping
- File-based message injection is simple, debuggable, and race-condition free with atomic writes
- All existing bash scripts work in Git Bash without modification
- PM2 ecosystem.config.cjs is a clean equivalent to launchd plist

**Cons:**
- Node.js wrapper is a new component to maintain (~200 lines)
- File watcher has slight latency vs tmux send-keys (50-100ms, imperceptible for Telegram use)
- Claude Code's TUI behavior with piped stdin needs validation — may need `--dangerously-skip-permissions` or similar flag for non-interactive mode

### Option B: WSL2 + native tmux

Run CortextOS inside WSL2 (Windows Subsystem for Linux) where tmux and launchd-equivalent (systemd) are available natively.

| Dimension | Assessment |
|-----------|------------|
| Complexity | Low — almost zero code changes |
| Cost | Free |
| Scalability | Same |
| Team Familiarity | Medium — WSL2 adds a layer |
| Time to Implement | 1-2 hours |

**Pros:**
- Virtually zero code changes — WSL2 is a full Linux environment
- tmux works natively
- systemd available in modern WSL2

**Cons:**
- Requires WSL2 installed and configured — significant user setup burden
- Claude Code may behave differently in WSL2 vs native Windows
- File system bridging between WSL2 and Windows adds complexity for MCP servers and project directories
- Not a "real" Windows port — it's a workaround
- Users who want Windows-native operation are not served

### Option C: ConPTY + Windows Services

Use Windows ConPTY (Pseudo Console API) for terminal emulation and Windows Services (via NSSM) for process management.

| Dimension | Assessment |
|-----------|------------|
| Complexity | High — ConPTY requires C/C++ or complex FFI |
| Cost | Free (NSSM is public domain) |
| Scalability | Same |
| Team Familiarity | Low — ConPTY is Windows-specific, poorly documented |
| Time to Implement | 2-4 weeks |

**Pros:**
- Most "native" Windows solution
- NSSM is proven for Windows service management
- ConPTY provides true terminal emulation

**Cons:**
- ConPTY is complex — requires native code or node-pty bindings
- NSSM hasn't been updated since 2017
- Massive implementation effort for marginal benefit over PM2
- node-pty adds native compilation dependency (node-gyp, Python, Visual Studio Build Tools)

## Trade-off Analysis

The key tension is **implementation effort vs. nativeness**. Option B (WSL2) is easy but isn't a real port. Option C (ConPTY) is the most native but requires weeks of work and adds native compilation dependencies. Option A (PM2 + Node.js wrapper) hits the sweet spot: truly Windows-native, reasonable implementation effort, and uses tools the community already knows.

The critical design question is **message injection without tmux**. On macOS, fast-checker.sh writes to Claude's stdin via `tmux load-buffer` + `paste-buffer` + `send-keys Enter`. On Windows, the Node.js wrapper replaces this: it spawns Claude as a child process with piped stdin, and the fast-checker writes messages to a **queue directory** at `${CRM_ROOT}/inject/${agent}/`. The protocol:
1. fast-checker writes message to a temp file, renames atomically to `{timestamp}-{random}.msg`
2. wrapper uses `fs.watch` as a **hint** + periodic directory scan (every 2s) as reconciliation
3. wrapper processes `.msg` files in sorted order (timestamp ensures ordering)
4. after reading, wrapper moves file to `${CRM_ROOT}/inject/${agent}/processed/` (not delete)
5. wrapper honors `stdin.write()` backpressure — pauses queue on `false`, resumes on `drain`
6. queue directory is under CRM_ROOT with `chmod 700` (owner-only), not `/tmp`

**Revised after Codex adversarial review (2026-04-02):** The original single-file design had critical race conditions (concurrent writes lose messages, fs.watch unreliable on Windows, /tmp is insecure). The queue directory pattern resolves all of these.

## Risk Assessment

**Updated 2026-04-02 after Codex adversarial review (24 risks identified, architecture revised).**

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Claude Code TUI doesn't accept piped stdin properly | **Validated OK** | High | `echo "what is 2+2" \| claude --continue` returns `4`. Single-message works. Long-running soak test still needed. |
| Long-running TUI stability with piped stdin | Medium | Critical | Need multi-day soak test before shipping. Stdout watchdog detects hangs. |
| Permission/AskUserQuestion TUI deadlock | Medium | Critical | `--dangerously-skip-permissions` avoids permission prompts. AskUserQuestion handled by fast-checker's Telegram callbacks. Watchdog as safety net. |
| Message loss from concurrent injection writes | **Eliminated** | Critical | Queue directory with per-message UUID files. No single-file race possible. |
| fs.watch unreliable on Windows (double/missed events) | High | High | Watch is a hint only. Periodic 2s directory scan as reconciliation. Idempotent processing. |
| Windows file locking (antivirus, indexer) | Medium | High | Bounded retry with backoff on file operations. Queue under CRM_ROOT (not /tmp). |
| Injection file security (local privilege escalation) | Medium | Critical | Queue directory under CRM_ROOT with chmod 700. Not in /tmp. Message size limit. |
| PM2 Windows daemon reliability / reboot | Medium | High | Document `pm2 startup` + `pm2 save`. Test cold boot recovery. |
| PM2 log rotation | High | High | Configure PM2 log rotation: 10MB max, 5 files retained. |
| Orphaned child processes on Windows | Medium | High | Explicit process-tree kill via `taskkill /T /F /PID` on wrapper exit. |
| Sleep/hibernate breaks 24/7 assumption | High | High | Document Windows power plan requirement. No `caffeinate` equivalent in v1. |
| Windows path translation (Git Bash vs Node) | High | High | `to_posix_path()` and `to_win_path()` in platform.sh. Convert once at boundary. Test spaces, Unicode, long paths. |
| OSTYPE detection brittle in non-interactive contexts | Medium | Medium | Check `$OSTYPE`, `$OS`, and `uname` as fallback chain. Log resolved platform at startup. |
| stdin backpressure not handled | Medium | High | Wrapper honors `write()` return value. Pause queue on `false`, resume on `drain`. |
| Cross-platform code drift | High | Medium | Shared platform.sh helpers. Future: abstract to platform-neutral message model. |
| 71h restart can lose in-flight messages | Medium | High | Queue is durable (files on disk). Unprocessed messages survive restart. |

## Decision

**Option A: PM2 + Node.js stdin wrapper.**

Primary reasons: It's a genuine Windows-native solution that uses tools the Node.js community already knows, requires no native compilation dependencies, and can be implemented in a single session. The Node.js wrapper for stdin injection is clean, testable, and debuggable.

## Consequences

**What becomes easier:**
- Windows users can run CortextOS without WSL2 or any Linux layer
- PM2's built-in monitoring (`pm2 monit`, `pm2 logs`) provides better observability than launchd
- The Node.js wrapper is more debuggable than tmux scripting (structured logging, error handling)

**What becomes harder:**
- Two code paths to maintain (macOS tmux vs Windows Node.js wrapper)
- Message injection behavior may differ slightly between platforms (tmux paste vs stdin pipe)
- Testing requires both platforms

**What we must revisit:**
- If Claude Code adds native daemon/service mode, this entire layer may become unnecessary
- If Anthropic releases a Windows terminal API, the Node.js wrapper could be simplified
- If tmux becomes available on Windows (via MSYS2 improvements), Option A could be simplified to match macOS exactly

## Implementation Plan

### Phase 1: Foundation (Tasks #2-4, parallel)
- `core/scripts/platform.sh` — shared platform detection
- `core/scripts/win-agent-wrapper.js` — Node.js Claude Code wrapper with stdin pipe
- `core/scripts/generate-pm2.sh` — PM2 ecosystem config generator

### Phase 2: Script Porting (Tasks #5-11, parallel where possible)
- Port all scripts with platform gates
- Update documentation

### Phase 3: Review (Tasks #12-14, parallel)
- Cora: Security + Correctness review
- Archie: Architecture + Maintainability review
- Codex: Adversarial review

### Phase 4: Test + Ship (Task #15)
- Live test on Windows
- Fix issues from reviews
- Push to fork, create PR

## Action Items
1. [ ] Create platform.sh — Archie Architect (foundation)
2. [ ] Create win-agent-wrapper.js — Benny Backend (core component)
3. [ ] Create generate-pm2.sh — Danny DevOps (infrastructure)
4. [ ] Port 6 existing scripts — parallel implementation
5. [ ] Triple code review — Cora, Archie, Codex in parallel
6. [ ] Live Windows test — end-to-end validation
7. [ ] PR to upstream — grandamenium/claude-remote-manager
