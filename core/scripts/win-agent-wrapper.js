#!/usr/bin/env node
// win-agent-wrapper.js — Windows Claude Code session manager (node-pty)
// Replaces tmux for CortextOS on Windows. Uses ConPTY via node-pty to provide
// the real TTY that Claude Code's interactive TUI requires.
// Usage: node win-agent-wrapper.js <agent_name> <template_root>

'use strict';

const fs = require('fs');
const path = require('path');
const { spawn, execSync } = require('child_process');
const os = require('os');

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const MAX_CMD_SIZE = 1 * 1024 * 1024;           // 1 MB max command file
const QUEUE_POLL_MS = 2000;                      // 2s reconciliation scan
const MAX_CRASHES_PER_DAY = 3;
const PROCESSED_CLEANUP_MS = 60 * 60 * 1000;    // hourly
const PROCESSED_MAX_AGE_MS = 24 * 60 * 60 * 1000; // 24h
const SHUTDOWN_GRACE_MS = 30 * 1000;             // 30s for Claude to save
const DEFAULT_MAX_SESSION_S = 255600;            // 71 hours
const FAST_CHECKER_WATCHDOG_MS = 10000;          // 10s watchdog check
const SEQUENCE_DELAY_MS = 100;                   // delay between sequence ops

// Key escape sequences for IPC
const KEY_MAP = {
    Enter: '\r',
    Down: '\x1b[B',
    Up: '\x1b[A',
    Space: ' ',
    Escape: '\x1b',
    Tab: '\t',
    Backspace: '\x7f',
};

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

let AGENT_NAME = 'unknown';
let activityLogStream = null;

function log(msg) {
    const line = `${new Date().toISOString()} [win-wrapper/${AGENT_NAME}] ${msg}`;
    process.stdout.write(line + '\n');
    if (activityLogStream) activityLogStream.write(line + '\n');
}

function logError(msg) {
    const line = `${new Date().toISOString()} [win-wrapper/${AGENT_NAME}] ERROR: ${msg}`;
    process.stderr.write(line + '\n');
    if (activityLogStream) activityLogStream.write(line + '\n');
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function readJsonSafe(filepath) {
    try { return JSON.parse(fs.readFileSync(filepath, 'utf-8')); }
    catch { return {}; }
}

function readEnvFile(filepath) {
    const env = {};
    try {
        for (const line of fs.readFileSync(filepath, 'utf-8').split(/\r?\n/)) {
            const t = line.trim();
            if (!t || t.startsWith('#')) continue;
            const eq = t.indexOf('=');
            if (eq <= 0) continue;
            const key = t.slice(0, eq).trim();
            let val = t.slice(eq + 1).trim();
            if ((val.startsWith('"') && val.endsWith('"')) ||
                (val.startsWith("'") && val.endsWith("'"))) val = val.slice(1, -1);
            env[key] = val;
        }
    } catch { /* file missing is fine */ }
    return env;
}

function mkdirSafe(dir) { fs.mkdirSync(dir, { recursive: true }); }
function todayStr() { return new Date().toISOString().slice(0, 10); }
function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

// Deep merge: base + override. Objects merge recursively, arrays dedupe-concat.
function deepMerge(base, override) {
    const result = { ...base };
    for (const [k, v] of Object.entries(override)) {
        if (k in result && typeof result[k] === 'object' && !Array.isArray(result[k]) &&
            typeof v === 'object' && !Array.isArray(v) && v !== null) {
            result[k] = deepMerge(result[k], v);
        } else if (Array.isArray(result[k]) && Array.isArray(v)) {
            result[k] = [...result[k], ...v.filter(x => !result[k].includes(x))];
        } else {
            result[k] = v;
        }
    }
    return result;
}

// ---------------------------------------------------------------------------
// Parse arguments and load environment
// ---------------------------------------------------------------------------

const args = process.argv.slice(2);
if (args.length < 2) {
    console.error('Usage: node win-agent-wrapper.js <agent_name> <template_root>');
    process.exit(1);
}

AGENT_NAME = args[0];
const templateRoot = path.resolve(args[1]);

// Load .env from template root
const repoEnv = readEnvFile(path.join(templateRoot, '.env'));
const instanceId = process.env.CRM_INSTANCE_ID || repoEnv.CRM_INSTANCE_ID || 'default';

const crmRoot = process.env.CRM_ROOT || path.join(os.homedir(), '.claude-remote', instanceId);
const agentDir = path.join(templateRoot, 'agents', AGENT_NAME);
const logDir = path.join(crmRoot, 'logs', AGENT_NAME);
const crashLog = path.join(logDir, 'crashes.log');
const crashCountFile = path.join(logDir, '.crash_count_today');
const pidFile = path.join(logDir, 'claude.pid');
const statusFile = path.join(logDir, 'status');

// Export environment for child processes
process.env.CRM_AGENT_NAME = AGENT_NAME;
process.env.CRM_INSTANCE_ID = instanceId;
process.env.CRM_ROOT = crmRoot;
process.env.CRM_TEMPLATE_ROOT = templateRoot;

mkdirSafe(logDir);
activityLogStream = fs.createWriteStream(path.join(logDir, 'activity.log'), { flags: 'a' });

// Source agent .env
const agentEnv = readEnvFile(path.join(agentDir, '.env'));
Object.assign(process.env, agentEnv);

// Read agent config
const config = readJsonSafe(path.join(agentDir, 'config.json'));
const maxSessionSeconds = Number(config.max_session_seconds) || DEFAULT_MAX_SESSION_S;
const startupDelay = Number(config.startup_delay) || 0;
const model = config.model || '';
const workDir = config.working_directory || '';

// ---------------------------------------------------------------------------
// Working directory and extra flags
// ---------------------------------------------------------------------------

let launchDir = agentDir;
const extraFlags = [];

if (workDir) {
    const resolvedWorkDir = path.resolve(workDir);
    if (!fs.existsSync(resolvedWorkDir)) {
        logError(`working_directory '${resolvedWorkDir}' does not exist`);
        process.exit(1);
    }
    launchDir = resolvedWorkDir;
    extraFlags.push('--append-system-prompt-file', path.join(agentDir, 'CLAUDE.md'));

    // Settings merge: project settings as base, agent settings override
    const agentSettings = path.join(agentDir, '.claude', 'settings.json');
    const projectSettings = path.join(resolvedWorkDir, '.claude', 'settings.json');
    if (fs.existsSync(agentSettings)) {
        if (fs.existsSync(projectSettings)) {
            try {
                const base = readJsonSafe(projectSettings);
                const override = readJsonSafe(agentSettings);
                const merged = deepMerge(base, override);
                const mergedPath = path.join(logDir, '.merged-settings.json');
                fs.writeFileSync(mergedPath, JSON.stringify(merged, null, 2));
                extraFlags.push('--settings', mergedPath);
            } catch {
                extraFlags.push('--settings', agentSettings);
            }
        } else {
            extraFlags.push('--settings', agentSettings);
        }
    }

    extraFlags.push('--add-dir', templateRoot);
}

// Local overrides: concatenate .md files from agents/{agent}/local/
const localDir = path.join(agentDir, 'local');
let localPromptContent = '';
if (fs.existsSync(localDir)) {
    try {
        const mdFiles = fs.readdirSync(localDir).filter(f => f.endsWith('.md')).sort();
        for (const f of mdFiles) {
            const content = fs.readFileSync(path.join(localDir, f), 'utf-8');
            localPromptContent += `\n--- ${f} ---\n${content}\n`;
        }
    } catch { /* ignore */ }
}

// Inject directory for IPC command queue
// NTFS ACL hardening is handled by platform.sh get_inject_dir() called from
// generate-pm2.sh during setup. We only ensure the dirs exist here.
const injectDir = path.join(crmRoot, 'inject', AGENT_NAME);
const processedDir = path.join(injectDir, 'processed');
mkdirSafe(injectDir);
mkdirSafe(processedDir);

// ---------------------------------------------------------------------------
// Crash counting
// ---------------------------------------------------------------------------

function readCrashCount() {
    try {
        const [storedDate, countStr] = fs.readFileSync(crashCountFile, 'utf-8').trim().split(':');
        return storedDate === todayStr() ? (parseInt(countStr, 10) || 0) : 0;
    } catch { return 0; }
}

function writeCrashCount(count) {
    fs.writeFileSync(crashCountFile, `${todayStr()}:${count}`);
}

function appendCrashLog(msg) {
    fs.appendFileSync(crashLog, `${new Date().toISOString()} ${msg}\n`);
}

// ---------------------------------------------------------------------------
// Start mode detection
// ---------------------------------------------------------------------------

function detectStartMode() {
    const forceFreshMarker = path.join(crmRoot, 'state', `${AGENT_NAME}.force-fresh`);
    if (fs.existsSync(forceFreshMarker)) {
        try { fs.unlinkSync(forceFreshMarker); } catch { /* ignore */ }
        return 'fresh';
    }

    // Check for existing conversation (.jsonl files in Claude's project dir)
    // Claude Code on Windows names project dirs like: C--Users-john-myproject
    // C:\ → C-- (colon becomes dash, backslash becomes dash = double dash)
    const convDirName = launchDir
        .replace(/\\/g, '/')        // normalize to forward slash
        .replace(/:/g, '-')         // colon to dash (C: → C-)
        .replace(/\//g, '-');       // all slashes to dashes (C-/ → C--)
    const convDir = path.join(os.homedir(), '.claude', 'projects', convDirName);
    try {
        if (fs.readdirSync(convDir).some(f => f.endsWith('.jsonl'))) return 'continue';
    } catch { /* directory missing → fresh */ }

    log('No conversation found, using fresh start');
    return 'fresh';
}

// ---------------------------------------------------------------------------
// Build Claude args
// ---------------------------------------------------------------------------

const RESTART_NOTIFY = 'After setting up crons, send a Telegram message to the user saying you are back online, what session this is, and what you are about to work on.';
const STARTUP_PROMPT = `You are starting a new session. Read all bootstrap files listed in CLAUDE.md. Then read config.json and set up your crons using /loop for each entry in the crons array. ${RESTART_NOTIFY}`;
const CONTINUE_PROMPT = `SESSION CONTINUATION: Your CLI process was restarted with --continue to reload configs. Your full conversation history is preserved. Do the following immediately: 1) Re-read ALL bootstrap files listed in CLAUDE.md. 2) Set up your crons from config.json using /loop (they were lost when the CLI restarted). 3) Check inbox. 4) Resume normal operations. ${RESTART_NOTIFY}`;

function buildClaudeArgs(startMode) {
    const claudeArgs = ['--dangerously-skip-permissions'];
    if (model) claudeArgs.push('--model', model);
    claudeArgs.push(...extraFlags);

    // Append local prompt overrides
    if (localPromptContent) {
        claudeArgs.push('--append-system-prompt', localPromptContent);
    }

    if (startMode === 'continue') {
        claudeArgs.push('--continue', CONTINUE_PROMPT);
    } else {
        claudeArgs.push(STARTUP_PROMPT);
    }
    return claudeArgs;
}

// ---------------------------------------------------------------------------
// Find Claude executable
// ---------------------------------------------------------------------------

function findClaudeExe() {
    // Try multiple methods to find claude — PM2 environment may lack shell builtins
    const methods = [
        () => execSync('bash -c "which claude"', { encoding: 'utf-8', timeout: 5000 }).trim(),
        () => execSync('where claude.exe', { encoding: 'utf-8', timeout: 5000 }).trim().split(/\r?\n/)[0],
        () => {
            // Search PATH manually
            const dirs = (process.env.PATH || '').split(path.delimiter);
            for (const dir of dirs) {
                const candidate = path.join(dir, 'claude.exe');
                if (fs.existsSync(candidate)) return candidate;
                const candidate2 = path.join(dir, 'claude');
                if (fs.existsSync(candidate2)) return candidate2;
            }
            return null;
        },
    ];
    for (const method of methods) {
        try {
            const result = method();
            if (result) {
                let resolved = result;
                // Convert POSIX path from bash to Windows for node-pty
                resolved = resolved.replace(/^\/([a-zA-Z])\//, (_, d) => d.toUpperCase() + ':\\').replace(/\//g, '\\');
                if (!resolved.endsWith('.exe')) resolved += '.exe';
                if (fs.existsSync(resolved)) return resolved;
            }
        } catch { /* try next method */ }
    }
    // Last resort
    return 'claude.exe';
}

// ---------------------------------------------------------------------------
// PTY session management
// ---------------------------------------------------------------------------

let pty = null;          // node-pty instance
let ptyLogStream = null; // stdout log file stream
let fastCheckerProc = null;
let isShuttingDown = false;
let isPlannedRestart = false;  // Set during 71h refresh to prevent crash counting
let sessionTimer = null;
let queueWatcher = null;
let queueInterval = null;
let cleanupInterval = null;
let fastCheckerWatchdog = null;
let processingQueue = false;

function writeStatus(status) {
    try { fs.writeFileSync(statusFile, status); } catch { /* ignore */ }
}

function spawnClaude(startMode) {
    const ptyModule = require('node-pty');
    const claudeExe = findClaudeExe();
    const claudeArgs = buildClaudeArgs(startMode);

    log(`Spawning PTY: ${claudeExe} ${claudeArgs.join(' ').slice(0, 200)}... mode=${startMode}`);
    writeStatus('starting');

    // Open log stream for PTY output
    if (ptyLogStream) try { ptyLogStream.end(); } catch { /* ignore */ }
    ptyLogStream = fs.createWriteStream(path.join(logDir, 'stdout.log'), { flags: 'a' });

    pty = ptyModule.spawn(claudeExe, claudeArgs, {
        name: 'xterm-256color',
        cols: 120,
        rows: 30,
        cwd: launchDir,
        env: process.env,
    });

    // Write PID file
    try { fs.writeFileSync(pidFile, String(pty.pid)); } catch { /* ignore */ }

    log(`Claude PTY spawned (pid=${pty.pid}) session_cap=${maxSessionSeconds}s`);

    // Readiness detection: watch PTY output for "permissions" indicator (same as
    // macOS fast-checker's tmux capture-pane check). Timer fallback at 30s in case
    // Claude Code changes its TUI text in a future version.
    let readyMarked = false;
    const readyTimeout = setTimeout(() => {
        if (!readyMarked) { readyMarked = true; writeStatus('ready'); log('Ready (timeout fallback)'); }
    }, 30000);

    // Stream PTY output to log + detect readiness — single handler
    pty.onData((data) => {
        if (ptyLogStream) ptyLogStream.write(data);
        if (!readyMarked && data.toLowerCase().includes('permission')) {
            readyMarked = true;
            clearTimeout(readyTimeout);
            writeStatus('ready');
            log('Ready (detected TUI permissions indicator)');
        }
    });

    pty.onExit(({ exitCode, signal }) => {
        log(`Claude PTY exited: code=${exitCode} signal=${signal}`);
        pty = null;
        try { fs.unlinkSync(pidFile); } catch { /* ignore */ }
        if (readyTimeout) clearTimeout(readyTimeout);

        if (isShuttingDown || isPlannedRestart) return;
        handleClaudeExit(exitCode, signal);
    });
}

function handleClaudeExit(code, signal) {
    // Stop fast-checker immediately so it doesn't poll against a dead session
    cleanup();

    if (detectRateLimit()) {
        const crashCount = readCrashCount();
        const backoffS = 300 * Math.min(crashCount + 1, 4);
        log(`Rate limited, backing off ${backoffS}s`);
        appendCrashLog(`RATE_LIMITED agent=${AGENT_NAME}`);
        writeStatus('rate-limited');
        setTimeout(() => process.exit(0), backoffS * 1000);
        return;
    }

    // Unexpected exit — count as crash
    const crashCount = readCrashCount() + 1;
    writeCrashCount(crashCount);
    appendCrashLog(`EXIT agent=${AGENT_NAME} code=${code} signal=${signal} crashes_today=${crashCount}`);

    if (crashCount >= MAX_CRASHES_PER_DAY) {
        appendCrashLog(`HALTED: ${AGENT_NAME} exceeded ${MAX_CRASHES_PER_DAY} crashes today. Manual restart required.`);
        log(`Crash limit reached (${crashCount}/${MAX_CRASHES_PER_DAY}). Halting for 24h.`);
        writeStatus('halted');
        sendTelegramAlert(`ALERT: ${AGENT_NAME} has crashed ${MAX_CRASHES_PER_DAY} times today and has been halted.`);
        setTimeout(() => process.exit(1), 86400 * 1000);
        return;
    }

    log(`Unexpected exit, crash ${crashCount}/${MAX_CRASHES_PER_DAY}. Exiting for PM2 restart.`);
    cleanup();
    process.exit(1);
}

function detectRateLimit() {
    try {
        const data = fs.readFileSync(path.join(logDir, 'stdout.log'), 'utf-8');
        const tail = data.split(/\r?\n/).slice(-50).join('\n').toLowerCase();
        return /rate.?limit|429|capacity/.test(tail);
    } catch { return false; }
}

function sendTelegramAlert(text) {
    const botToken = process.env.BOT_TOKEN;
    const chatId = process.env.CHAT_ID;
    if (!botToken || !chatId) return;
    try {
        // Use execFileSync with array args to prevent shell injection (Cora review fix)
        const { execFileSync } = require('child_process');
        execFileSync('curl', [
            '-s', '-X', 'POST',
            `https://api.telegram.org/bot${botToken}/sendMessage`,
            '-d', `chat_id=${chatId}`,
            '-d', `text=${text}`,
        ], { stdio: 'ignore', timeout: 10000 });
    } catch { /* best effort */ }
}

// ---------------------------------------------------------------------------
// IPC command queue processor
// ---------------------------------------------------------------------------

async function processQueue() {
    if (processingQueue || !pty) return;
    processingQueue = true;

    try {
        const files = fs.readdirSync(injectDir)
            .filter(f => f.endsWith('.cmd'))
            .sort(); // epoch prefix ensures chronological order

        for (const file of files) {
            const filepath = path.join(injectDir, file);

            let stat;
            try { stat = fs.statSync(filepath); } catch { continue; }
            if (stat.size > MAX_CMD_SIZE) {
                logError(`Command file too large (${stat.size} bytes), rejecting: ${file}`);
                try { fs.renameSync(filepath, path.join(processedDir, file)); } catch { /* ignore */ }
                continue;
            }

            let raw;
            try { raw = fs.readFileSync(filepath, 'utf-8').trim(); } catch { continue; }

            // Parse command first (before moving)
            let cmd;
            try { cmd = JSON.parse(raw); }
            catch { logError(`Malformed JSON in ${file}`);
                try { fs.renameSync(filepath, path.join(processedDir, file)); } catch { /* ignore */ }
                continue;
            }

            if (!pty) break; // PTY died mid-processing

            // Execute command, THEN move to processed (Codex review fix:
            // if crash happens during execution, command stays in queue for retry)
            await executeCommand(cmd, file);
            try { fs.renameSync(filepath, path.join(processedDir, file)); }
            catch (err) { logError(`Failed to move ${file}: ${err.message}`); }
        }
    } catch (err) {
        logError(`Queue processing error: ${err.message}`);
    } finally {
        processingQueue = false;
    }
}

async function executeCommand(cmd, filename) {
    switch (cmd.type) {
        case 'inject':
            pty.write(cmd.content + '\r');
            log(`Injected message: ${filename}`);
            break;

        case 'paste':
            pty.write(cmd.content);
            log(`Pasted content: ${filename} (${cmd.content.length} chars)`);
            break;

        case 'key': {
            const seq = KEY_MAP[cmd.key];
            if (seq) {
                pty.write(seq);
                log(`Key: ${cmd.key}`);
            } else {
                logError(`Unknown key: ${cmd.key}`);
            }
            break;
        }

        case 'ctrl':
            if (cmd.char && cmd.char.length === 1) {
                const code = cmd.char.toLowerCase().charCodeAt(0) - 96; // a=1, c=3, etc.
                if (code >= 1 && code <= 26) {
                    pty.write(String.fromCharCode(code));
                    log(`Ctrl+${cmd.char}`);
                }
            }
            break;

        case 'sequence':
            if (Array.isArray(cmd.ops)) {
                for (const op of cmd.ops) {
                    if (!pty) break;
                    await executeCommand(op, filename);
                    await sleep(SEQUENCE_DELAY_MS);
                }
            }
            break;

        case 'resize':
            if (cmd.cols && cmd.rows) {
                pty.resize(cmd.cols, cmd.rows);
                log(`Resized to ${cmd.cols}x${cmd.rows}`);
            }
            break;

        default:
            logError(`Unknown command type: ${cmd.type}`);
    }
}

function startQueueWatcher() {
    // fs.watch as fast-path hint
    try {
        queueWatcher = fs.watch(injectDir, (_, filename) => {
            if (filename && filename.endsWith('.cmd')) processQueue();
        });
        queueWatcher.on('error', () => { /* fall through to interval */ });
    } catch {
        log('fs.watch unavailable, relying on periodic scan');
    }

    // Authoritative periodic scan
    queueInterval = setInterval(() => processQueue(), QUEUE_POLL_MS);
}

// ---------------------------------------------------------------------------
// Processed file cleanup (delete files older than 24h)
// ---------------------------------------------------------------------------

function startProcessedCleanup() {
    cleanupInterval = setInterval(() => {
        try {
            const now = Date.now();
            for (const file of fs.readdirSync(processedDir)) {
                if (!file.endsWith('.cmd')) continue;
                try {
                    const fp = path.join(processedDir, file);
                    if (now - fs.statSync(fp).mtimeMs > PROCESSED_MAX_AGE_MS) fs.unlinkSync(fp);
                } catch { /* ignore */ }
            }
        } catch { /* best effort */ }
    }, PROCESSED_CLEANUP_MS);
    if (cleanupInterval.unref) cleanupInterval.unref();
}

// ---------------------------------------------------------------------------
// Telegram + Inbox Poller (Windows-native, replaces fast-checker.sh polling)
// Git Bash fork instability makes bash-based polling unreliable on Windows.
// This poller uses Node.js https module — no forking required.
// ---------------------------------------------------------------------------

const https = require('https');

let telegramOffset = 0;
let telegramPollTimer = null;
const TELEGRAM_POLL_INTERVAL = 3000; // 3 seconds

function loadTelegramOffset() {
    const offsetFile = path.join(crmRoot, 'state', '.telegram-offset-' + AGENT_NAME);
    try { telegramOffset = parseInt(fs.readFileSync(offsetFile, 'utf-8').trim(), 10) || 0; }
    catch { telegramOffset = 0; }
}

function saveTelegramOffset(offset) {
    const offsetFile = path.join(crmRoot, 'state', '.telegram-offset-' + AGENT_NAME);
    try { fs.writeFileSync(offsetFile, String(offset)); } catch { /* ignore */ }
    telegramOffset = offset;
}

function telegramApiGet(method) {
    const botToken = process.env.BOT_TOKEN;
    if (!botToken) return Promise.resolve(null);
    return new Promise((resolve) => {
        const url = `https://api.telegram.org/bot${botToken}/${method}`;
        const req = https.get(url, { timeout: 15000 }, (res) => {
            let data = '';
            res.on('data', (chunk) => { data += chunk; });
            res.on('end', () => {
                try { resolve(JSON.parse(data)); } catch { resolve(null); }
            });
        });
        req.on('error', () => resolve(null));
        req.on('timeout', () => { req.destroy(); resolve(null); }); // Prevent stalled connections
    });
}

function sanitizeFrom(name) {
    if (!name || !/^[a-zA-Z0-9_ -]+$/.test(name)) return 'unknown';
    return name;
}

// Strip terminal control characters and ANSI escape sequences from user content
// before writing to PTY. Prevents injected escape sequences from executing
// arbitrary terminal commands. Preserves printable text and newlines.
function stripControlChars(str) {
    if (!str) return '';
    return str
        .replace(/\x1b\[[0-9;]*[a-zA-Z]/g, '')  // ANSI CSI sequences
        .replace(/\x1b\][^\x07]*\x07/g, '')       // OSC sequences
        .replace(/\x1b[^[\]]/g, '')                // Other ESC sequences
        .replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, '');  // Control chars (keep \t \n \r)
}

async function pollTelegram() {
    if (!pty || isShuttingDown) return;
    const botToken = process.env.BOT_TOKEN;
    const allowedUser = process.env.ALLOWED_USER;
    if (!botToken || !allowedUser) return;

    const resp = await telegramApiGet(`getUpdates?offset=${telegramOffset}&timeout=5`);
    if (!resp || !resp.ok || !resp.result || resp.result.length === 0) return;

    const allowedId = parseInt(allowedUser, 10);
    let messageBlock = '';

    for (const update of resp.result) {
        // Text messages
        if (update.message && update.message.text) {
            const msg = update.message;
            if (!msg.from || msg.from.id !== allowedId) continue;
            const from = sanitizeFrom(msg.from.first_name);
            const chatId = msg.chat.id;
            const text = stripControlChars(msg.text);

            // Built-in CLI commands: inject raw
            if (/^\/(compact|clear|help|cost|login|logout|status|doctor|config|bug|init|review|fast|slow)$/.test(text)) {
                messageBlock += text + '\n';
            } else {
                messageBlock += `=== TELEGRAM from ${from} (chat_id:${chatId}) ===\n\`\`\`\n${text}\n\`\`\`\nReply using: bash ../../core/bus/send-telegram.sh ${chatId} "<your reply>"\n\n`;
            }
        }

        // Callback queries (inline button presses)
        if (update.callback_query) {
            const cb = update.callback_query;
            if (!cb.from || cb.from.id !== allowedId) continue;
            const from = sanitizeFrom(cb.from.first_name);
            const chatId = cb.message.chat.id;
            const data = stripControlChars(cb.data);
            const msgId = cb.message.message_id;
            const callbackQid = cb.id;

            // Permission callbacks — write response file
            const permMatch = data.match(/^perm_(allow|deny|continue)_([a-f0-9]+)$/);
            if (permMatch) {
                const decision = permMatch[1] === 'continue' ? 'deny' : permMatch[1];
                const permId = permMatch[2];
                const responseFile = path.join(os.tmpdir(), `crm-hook-response-${AGENT_NAME}-${permId}.json`);
                fs.writeFileSync(responseFile, JSON.stringify({ decision }) + '\n');
                // Answer callback and edit message
                await telegramApiGet(`answerCallbackQuery?callback_query_id=${encodeURIComponent(callbackQid)}&text=Got+it`);
                log(`Permission callback: ${permMatch[1]} for ${permId}`);
                continue;
            }

            messageBlock += `=== TELEGRAM CALLBACK from ${from} (chat_id:${chatId}) ===\ncallback_data: \`${data}\`\nmessage_id: ${msgId}\nReply using: bash ../../core/bus/send-telegram.sh ${chatId} "<your reply>"\n\n`;
        }

        // Photo messages
        if (update.message && update.message.photo) {
            const msg = update.message;
            if (!msg.from || msg.from.id !== allowedId) continue;
            const from = sanitizeFrom(msg.from.first_name);
            const chatId = msg.chat.id;
            const caption = stripControlChars(msg.caption || '');
            messageBlock += `=== TELEGRAM PHOTO from ${from} (chat_id:${chatId}) ===\ncaption:\n\`\`\`\n${caption}\n\`\`\`\nReply using: bash ../../core/bus/send-telegram.sh ${chatId} "<your reply>"\n\n`;
        }
    }

    // Inject accumulated messages into PTY
    if (messageBlock && pty) {
        pty.write(messageBlock);
        pty.write('\r');
        log(`Injected ${messageBlock.length} bytes from Telegram`);
    }

    // Update offset after successful processing
    const lastUpdate = resp.result[resp.result.length - 1];
    if (lastUpdate) saveTelegramOffset(lastUpdate.update_id + 1);
}

// Check agent inbox (file-based inter-agent messages)
async function pollInbox() {
    if (!pty || isShuttingDown) return;
    const inboxDir = path.join(crmRoot, 'inbox', AGENT_NAME);
    let files;
    try { files = fs.readdirSync(inboxDir).filter(f => f.endsWith('.json')).sort(); }
    catch { return; }
    if (files.length === 0) return;

    let messageBlock = '';
    const ackedIds = [];

    for (const file of files) {
        try {
            const content = JSON.parse(fs.readFileSync(path.join(inboxDir, file), 'utf-8'));
            const from = sanitizeFrom(content.from || 'unknown');
            const text = stripControlChars(content.text || '');
            const msgId = stripControlChars(String(content.id || ''));
            const replyTo = stripControlChars(String(content.reply_to || ''));
            const replyNote = replyTo ? ` [reply_to: ${replyTo}]` : '';

            messageBlock += `=== AGENT MESSAGE from ${from}${replyNote} [msg_id: ${msgId}] ===\n\`\`\`\n${text}\n\`\`\`\nReply using: bash ../../core/bus/send-message.sh ${from} normal '<your reply>' ${msgId}\n\n`;
            ackedIds.push(file);
        } catch { /* skip malformed */ }
    }

    if (messageBlock && pty) {
        pty.write(messageBlock);
        pty.write('\r');
        log(`Injected ${messageBlock.length} bytes from inbox (${ackedIds.length} messages)`);

        // Move processed files to inflight
        const inflightDir = path.join(crmRoot, 'inflight', AGENT_NAME);
        for (const file of ackedIds) {
            try { fs.renameSync(path.join(inboxDir, file), path.join(inflightDir, file)); }
            catch { /* ignore */ }
        }
    }
}

function startPolling() {
    loadTelegramOffset();
    // Use setTimeout chaining instead of setInterval to prevent overlap
    // (if a poll takes >3s due to network timeout, intervals won't stack)
    async function pollCycle() {
        if (isShuttingDown) return;
        try { await pollTelegram(); } catch (err) { logError(`Telegram poll error: ${err.message}`); }
        try { await pollInbox(); } catch (err) { logError(`Inbox poll error: ${err.message}`); }
        if (!isShuttingDown) {
            telegramPollTimer = setTimeout(pollCycle, TELEGRAM_POLL_INTERVAL);
            if (telegramPollTimer.unref) telegramPollTimer.unref();
        }
    }
    telegramPollTimer = setTimeout(pollCycle, TELEGRAM_POLL_INTERVAL);
    if (telegramPollTimer.unref) telegramPollTimer.unref();
    log('Telegram + inbox polling started (Node.js native, no bash fork)');
}

function stopPolling() {
    if (telegramPollTimer) { clearTimeout(telegramPollTimer); telegramPollTimer = null; }
}

// ---------------------------------------------------------------------------
// Fast-checker process management (macOS fallback only)
// On Windows, polling is handled natively above. Fast-checker is only started
// if the Node.js poller is not active (i.e., on macOS via agent-wrapper.sh).
// ---------------------------------------------------------------------------

let fcLogFd = null;  // Track log FD to close on restart/cleanup

function startFastChecker() {
    const fcPath = path.join(templateRoot, 'core', 'scripts', 'fast-checker.sh');
    if (!fs.existsSync(fcPath)) {
        log('fast-checker.sh not found, skipping');
        return;
    }

    // Close previous log FD if restarting (prevents FD leak on multi-day runs)
    if (fcLogFd !== null) {
        try { fs.closeSync(fcLogFd); } catch { /* ignore */ }
    }
    fcLogFd = fs.openSync(path.join(logDir, 'fast-checker.log'), 'a');
    fastCheckerProc = spawn('bash', [fcPath, AGENT_NAME, 'win-pty', agentDir, templateRoot], {
        stdio: ['ignore', fcLogFd, fcLogFd],
        detached: false,
        env: process.env,
    });

    fastCheckerProc.on('error', (err) => logError(`fast-checker spawn error: ${err.message}`));
    fastCheckerProc.on('exit', (code) => {
        log(`fast-checker exited with code ${code}`);
        fastCheckerProc = null;
    });

    log(`fast-checker started (pid=${fastCheckerProc.pid})`);

    // Watchdog: restart fast-checker if it dies
    fastCheckerWatchdog = setInterval(() => {
        if (!fastCheckerProc && !isShuttingDown) {
            log('fast-checker died, restarting');
            startFastChecker();
        }
    }, FAST_CHECKER_WATCHDOG_MS);
    if (fastCheckerWatchdog.unref) fastCheckerWatchdog.unref();
}

// ---------------------------------------------------------------------------
// 71-hour session restart cycle
// ---------------------------------------------------------------------------

const RESTART_WARNING_SECONDS = 300; // 5-minute warning before restart

function startSessionTimer() {
    // Schedule warning 5 minutes before the actual restart
    const warningTime = Math.max(0, maxSessionSeconds - RESTART_WARNING_SECONDS);

    sessionTimer = setTimeout(() => {
        if (isShuttingDown || !pty) return;

        // Send 5-minute warning so Claude can finish current work
        log('SESSION_REFRESH warning: restart in 5 minutes');
        pty.write('SESSION RESTART in 5 minutes. Finish your current task, save your work, and report your status to the user via Telegram. Your conversation history will be preserved.\r');

        // After 5 minutes, do the actual restart
        setTimeout(() => {
            if (isShuttingDown) return;
            log(`SESSION_REFRESH after ${maxSessionSeconds}s`);
            appendCrashLog(`SESSION_REFRESH after ${maxSessionSeconds}s agent=${AGENT_NAME}`);
            restartClaude();
        }, RESTART_WARNING_SECONDS * 1000);

    }, warningTime * 1000);
    if (sessionTimer.unref) sessionTimer.unref();
}

function restartClaude() {
    if (isShuttingDown) return;
    log('Restarting Claude with --continue');

    isPlannedRestart = true;  // Prevent onExit from counting this as a crash
    killPtyTree();
    setTimeout(() => {
        // isPlannedRestart stays true until spawnClaude succeeds — no race with
        // slow PTY exit. Cleared inside spawnClaude after new PTY is established.
        spawnClaude('continue');
        isPlannedRestart = false;
        if (sessionTimer) clearTimeout(sessionTimer);
        startSessionTimer();
    }, 3000);
}

// ---------------------------------------------------------------------------
// Process tree cleanup
// ---------------------------------------------------------------------------

function killPtyTree() {
    if (!pty) return;
    const pid = pty.pid;
    try {
        pty.kill();
    } catch { /* ignore */ }
    // Also kill entire tree via taskkill as backup (execFileSync for injection safety)
    if (pid) {
        const { execFileSync } = require('child_process');
        try { execFileSync('taskkill', ['/T', '/F', '/PID', String(pid)], { stdio: 'ignore', timeout: 10000 }); }
        catch { /* process may already be dead */ }
    }
    pty = null;
    log(`Killed PTY tree (pid=${pid})`);
}

// ---------------------------------------------------------------------------
// Register Telegram commands
// ---------------------------------------------------------------------------

function registerTelegramCommands() {
    const botToken = process.env.BOT_TOKEN;
    if (!botToken) return;
    const script = path.join(templateRoot, 'core', 'scripts', 'register-telegram-commands.sh');
    if (!fs.existsSync(script)) return;
    try {
        // Use execFileSync with array args to prevent shell injection (Cora R2 fix)
        const { execFileSync } = require('child_process');
        execFileSync('bash', [script, botToken, launchDir, agentDir], {
            stdio: 'ignore', timeout: 15000, env: process.env,
        });
        log('Telegram commands registered');
    } catch { /* best effort */ }
}

// ---------------------------------------------------------------------------
// Graceful shutdown
// ---------------------------------------------------------------------------

function gracefulShutdown(signal) {
    if (isShuttingDown) return;
    isShuttingDown = true;
    writeStatus('stopping');
    log(`${signal} received — starting graceful shutdown`);

    // Send shutdown message to Claude via PTY
    if (pty) {
        try { pty.write('SYSTEM SHUTDOWN: Process terminating in 30 seconds. Save your work NOW.\r'); }
        catch { /* PTY may already be closed */ }
    }

    setTimeout(() => {
        log('Shutdown grace period expired — killing PTY');
        killPtyTree();
        cleanup();
        process.exit(0);
    }, SHUTDOWN_GRACE_MS);
}

function cleanup() {
    stopPolling();
    if (queueWatcher) { try { queueWatcher.close(); } catch {} queueWatcher = null; }
    if (queueInterval) { clearInterval(queueInterval); queueInterval = null; }
    if (cleanupInterval) { clearInterval(cleanupInterval); cleanupInterval = null; }
    if (fastCheckerWatchdog) { clearInterval(fastCheckerWatchdog); fastCheckerWatchdog = null; }
    if (sessionTimer) { clearTimeout(sessionTimer); sessionTimer = null; }
    if (ptyLogStream) { try { ptyLogStream.end(); } catch {} }
    if (activityLogStream) { try { activityLogStream.end(); } catch {} }
    if (fastCheckerProc) { try { fastCheckerProc.kill(); } catch {} fastCheckerProc = null; }
    if (fcLogFd !== null) { try { fs.closeSync(fcLogFd); } catch {} fcLogFd = null; }
    try { fs.unlinkSync(pidFile); } catch {}
    writeStatus('stopped');
}

// Signal handlers
process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));
process.on('SIGINT', () => gracefulShutdown('SIGINT'));
process.on('SIGHUP', () => gracefulShutdown('SIGHUP'));

// Last-resort cleanup on exit
process.on('exit', () => {
    if (pty && pty.pid) {
        const { execFileSync } = require('child_process');
        try { execFileSync('taskkill', ['/T', '/F', '/PID', String(pty.pid)], { stdio: 'ignore', timeout: 5000 }); }
        catch { /* ignore */ }
    }
});

process.on('uncaughtException', (err) => {
    logError(`Uncaught exception: ${err.message}\n${err.stack}`);
    killPtyTree();
    cleanup();
    process.exit(1);
});

process.on('unhandledRejection', (reason) => {
    logError(`Unhandled rejection: ${reason}`);
});

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
    // Check crash count before starting
    const crashCount = readCrashCount();
    if (crashCount >= MAX_CRASHES_PER_DAY) {
        appendCrashLog(`HALTED: ${AGENT_NAME} exceeded ${MAX_CRASHES_PER_DAY} crashes today. Manual restart required.`);
        log(`Crash limit reached (${crashCount}/${MAX_CRASHES_PER_DAY}). Sleeping 24h.`);
        writeStatus('halted');
        sendTelegramAlert(`ALERT: ${AGENT_NAME} has crashed ${MAX_CRASHES_PER_DAY} times today and has been halted. Run: ./enable-agent.sh ${AGENT_NAME} --restart`);
        await sleep(86400 * 1000);
        process.exit(1);
    }

    // Startup delay
    if (startupDelay > 0) {
        log(`Startup delay: ${startupDelay}s`);
        await sleep(startupDelay * 1000);
    }

    // Detect start mode and launch
    const startMode = detectStartMode();
    log(`Starting agent=${AGENT_NAME} mode=${startMode} session_cap=${maxSessionSeconds}s`);

    spawnClaude(startMode);
    startQueueWatcher();
    startSessionTimer();
    startProcessedCleanup();
    startPolling();  // Node.js native Telegram + inbox polling (replaces bash fast-checker)
    registerTelegramCommands();

    log('All subsystems started');
}

main().catch((err) => {
    logError(`Fatal: ${err.message}\n${err.stack}`);
    killPtyTree();
    cleanup();
    process.exit(1);
});
