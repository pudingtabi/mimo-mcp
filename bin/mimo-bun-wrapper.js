#!/usr/bin/env bun
/**
 * Bun wrapper for Mimo MCP server
 * 
 * Benefits over Node.js:
 * - 15-24x faster startup (~5ms vs ~120ms)
 * - 2-4x faster STDIO throughput
 * - 3x faster file I/O operations
 * - Native TypeScript support (future-proofing)
 * 
 * CRITICAL: MCP stdio transport requires ZERO output to stdout except JSON-RPC.
 * All logs MUST go to stderr only.
 * 
 * NOTE: Uses Node's child_process.spawn for stdin piping (Bun's native spawn has stdin bugs)
 */

import { spawn } from "child_process";  // Use Node's spawn for reliable stdin.pipe()
import { spawnSync } from "bun";  // Keep Bun's spawnSync for preflight checks
import { existsSync, readdirSync, statSync } from "fs";
import { join, resolve, isAbsolute } from "path";
import { homedir } from "os";

// CRITICAL: Force all console output to stderr
const originalLog = console.log;
console.log = (...args) => console.error(...args);

// SILENT mode - suppress wrapper logging for clean MCP transport
const SILENT_MODE = Bun.env.MCP_SILENT !== '0';
const log = SILENT_MODE ? () => { } : (...args) => console.error('[Mimo Bun]', ...args);

// --- Path Resolution ---

function isValidMimoDir(dir) {
  if (!dir) return false;
  try {
    return existsSync(join(dir, 'mix.exs'));
  } catch {
    return false;
  }
}

const MIMO_DIR_FROM_ENV = Bun.env.MIMO_DIR ? resolve(Bun.env.MIMO_DIR) : null;
const MIMO_DIR_FROM_SCRIPT = resolve(import.meta.dir, '..');
const MIMO_DIR = isValidMimoDir(MIMO_DIR_FROM_ENV) ? MIMO_DIR_FROM_ENV : MIMO_DIR_FROM_SCRIPT;

if (MIMO_DIR_FROM_ENV && MIMO_DIR !== MIMO_DIR_FROM_ENV) {
  log(`Ignoring invalid MIMO_DIR=${MIMO_DIR_FROM_ENV}; using ${MIMO_DIR}`);
}

// --- Elixir Path Discovery ---

function findElixirPaths() {
  const home = homedir();
  const paths = [];

  // asdf (most common)
  const asdfShims = join(home, '.asdf', 'shims');
  const asdfBin = join(home, '.asdf', 'bin');
  if (existsSync(asdfShims)) paths.push(asdfShims);
  if (existsSync(asdfBin)) paths.push(asdfBin);

  // elixir-install - read versions from .tool-versions for dynamic selection
  try {
    const elixirDir = join(home, '.elixir-install', 'installs', 'elixir');
    const otpDir = join(home, '.elixir-install', 'installs', 'otp');

    // Read target versions from .tool-versions
    let targetOtp = null;
    let targetElixir = null;
    const toolVersionsPath = join(MIMO_DIR, '.tool-versions');

    if (existsSync(toolVersionsPath)) {
      const { readFileSync } = require('fs');
      const content = readFileSync(toolVersionsPath, 'utf8');
      const lines = content.split('\n');
      for (const line of lines) {
        const [tool, version] = line.trim().split(/\s+/);
        if (tool === 'erlang') targetOtp = version;
        if (tool === 'elixir') targetElixir = version;
      }
    }

    // OTP must come FIRST in PATH
    if (existsSync(otpDir)) {
      const versions = readdirSync(otpDir).sort();
      // Prefer version from .tool-versions, otherwise use latest
      const matchingVersion = targetOtp ? versions.find(v => v.startsWith(targetOtp.split('.')[0])) : null;
      const selectedVersion = matchingVersion || versions[versions.length - 1];
      if (selectedVersion) {
        paths.push(join(otpDir, selectedVersion, 'bin'));
      }
    }

    // Elixir comes AFTER OTP
    if (existsSync(elixirDir)) {
      const versions = readdirSync(elixirDir).sort();
      // Prefer version from .tool-versions, otherwise use latest
      const targetOtpSuffix = targetElixir ? targetElixir.match(/otp-\d+/)?.[0] : null;
      const matchingVersion = targetOtpSuffix ? versions.find(v => v.includes(targetOtpSuffix)) : null;
      const selectedVersion = matchingVersion || versions[versions.length - 1];
      if (selectedVersion) {
        paths.push(join(elixirDir, selectedVersion, 'bin'));
      }
    }
  } catch { }

  return paths.join(':');
}

const ELIXIR_PATH = findElixirPaths();
const mixEnv = Bun.env.MIX_ENV || 'dev';

// --- Environment ---

function buildEnv() {
  return {
    ...Bun.env,
    LC_ALL: Bun.env.LC_ALL || 'C.UTF-8',
    LANG: Bun.env.LANG || 'C.UTF-8',
    PATH: `${ELIXIR_PATH}:${Bun.env.PATH}`,
    MIX_ENV: mixEnv,
    MIX_QUIET: '1',
    ELIXIR_ERL_OPTIONS: '+fnu',
    MIMO_HTTP_PORT: String(50000 + (process.pid % 10000)),
    MCP_PORT: String(40000 + (process.pid % 10000)),
    PROMETHEUS_DISABLED: 'true',
    MIMO_DISABLE_HTTP: 'true',
    LOGGER_LEVEL: 'none',
    // Set MIMO_ROOT to allow file/terminal operations on the project directory
    MIMO_ROOT: Bun.env.MIMO_ROOT || MIMO_DIR,
    // Allow additional paths (user home, /tmp, etc.) for broader file access
    MIMO_ALLOWED_PATHS: Bun.env.MIMO_ALLOWED_PATHS || '/root:/tmp:/home',
  };
}

// --- Build Paths ---

function resolveMixBuildPath() {
  const raw = Bun.env.MIX_BUILD_PATH;
  if (!raw) return join(MIMO_DIR, '_build');
  return isAbsolute(raw) ? raw : resolve(MIMO_DIR, raw);
}

function buildArtefactPath() {
  return join(resolveMixBuildPath(), mixEnv, 'lib', 'mimo_mcp', 'ebin', 'mimo_mcp.app');
}

// --- Compilation ---

function ensureCompiledSync() {
  const appPath = buildArtefactPath();
  if (existsSync(appPath)) return true;

  log('Build artifacts missing; compiling synchronously...');

  const result = spawnSync({
    cmd: ['bash', '-c', `
      set -euo pipefail
      cd "${MIMO_DIR}"
      export PATH="${ELIXIR_PATH}:$PATH"
      export LC_ALL="C.UTF-8"
      export LANG="C.UTF-8"
      export ELIXIR_ERL_OPTIONS="+fnu"
      [ -f .env ] && { set -a; . .env 2>/dev/null || true; set +a; }
      export MIX_ENV="${mixEnv}"
      export MIX_QUIET=1
      echo "[Mimo Compile] mix deps.get" >&2
      timeout 600s mix deps.get 2>&1 | while IFS= read -r line; do echo "[Mimo Compile] $line" >&2; done
      echo "[Mimo Compile] mix compile" >&2
      timeout 600s mix compile 2>&1 | while IFS= read -r line; do echo "[Mimo Compile] $line" >&2; done
    `],
    cwd: MIMO_DIR,
    env: buildEnv(),
    stderr: 'inherit',
  });

  if (result.exitCode !== 0) {
    log(`Synchronous compilation failed (exit=${result.exitCode})`);
    return false;
  }

  return existsSync(appPath);
}

// --- Hex Compatibility ---

function checkHexOtpCompatibility() {
  try {
    const result = spawnSync({
      cmd: ['bash', '-c', `
        cd "${MIMO_DIR}"
        export PATH="${ELIXIR_PATH}:$PATH"
        export LC_ALL="C.UTF-8"
        export LANG="C.UTF-8"
        export ELIXIR_ERL_OPTIONS="+fnu"
        mix hex.info 2>&1 || echo "HEX_CHECK_FAILED"
      `],
      cwd: MIMO_DIR,
      env: buildEnv(),
      stdout: 'pipe',
    });

    const output = result.stdout.toString();
    const needsReinstall = [
      'beam_load', 'op bs_add', 'OTP 28', 're-compile this module',
      'Hex.State', 'HEX_CHECK_FAILED', 'Hex package manager', 'Shall I install Hex'
    ].some(pattern => output.includes(pattern));

    if (needsReinstall) {
      log('Hex not installed or OTP mismatch detected');
      return false;
    }
    return true;
  } catch (e) {
    log('Hex check failed:', e.message);
    return false;
  }
}

function reinstallHex() {
  log('Reinstalling Hex and Rebar...');
  try {
    spawnSync({
      cmd: ['bash', '-c', `
        cd "${MIMO_DIR}"
        export PATH="${ELIXIR_PATH}:$PATH"
        export LC_ALL="C.UTF-8"
        export LANG="C.UTF-8"
        export ELIXIR_ERL_OPTIONS="+fnu"
        [ -f .env ] && { set -a; . .env 2>/dev/null || true; set +a; }
        mix local.hex --force 2>&1
        mix local.rebar --force 2>&1
      `],
      cwd: MIMO_DIR,
      env: buildEnv(),
      stderr: 'inherit',
    });
    log('Hex and Rebar reinstalled');
    return true;
  } catch (e) {
    log('Failed to reinstall Hex:', e.message);
    return false;
  }
}

// --- Kill Existing (Optional) ---

const KILL_EXISTING = ['1', 'true', 'yes'].includes((Bun.env.MIMO_WRAPPER_KILL_EXISTING || '0').toLowerCase());

if (KILL_EXISTING) {
  try {
    // Kill existing Mimo processes
    spawnSync({ cmd: ['pkill', '-f', 'Mimo.McpServer.Stdio'], stdout: 'ignore', stderr: 'ignore' });
    spawnSync({ cmd: ['pkill', '-f', 'beam.smp.*mimo'], stdout: 'ignore', stderr: 'ignore' });
    // Clean up all lock files (both old /tmp style and new priv/ style)
    spawnSync({ cmd: ['rm', '-f', '/tmp/mimo_mcp_stdio.lock'], stdout: 'ignore', stderr: 'ignore' });
    spawnSync({ cmd: ['rm', '-f', `${MIMO_DIR}/priv/mimo.lock`, `${MIMO_DIR}/priv/mimo.lock.info`, `${MIMO_DIR}/priv/mimo.pid`], stdout: 'ignore', stderr: 'ignore' });
    // Use sync sleep via spawnSync instead of top-level await
    spawnSync({ cmd: ['sleep', '0.5'], stdout: 'ignore', stderr: 'ignore' });
  } catch { }
}

// --- Pre-flight Checks ---

if (!checkHexOtpCompatibility()) {
  reinstallHex();
}

ensureCompiledSync();

// --- Spawn Elixir MCP Server ---

log('Starting Mimo MCP server...');

// Build env with all required vars set BEFORE spawn (no bash wrapper)
const spawnEnv = {
  ...buildEnv(),
  MIX_QUIET: '1',
  MIMO_HTTP_PORT: String(50000 + (process.pid % 10000)),
  MCP_PORT: String(40000 + (process.pid % 10000)),
  PROMETHEUS_DISABLED: 'true',
  MIMO_DISABLE_HTTP: 'true',
  LOGGER_LEVEL: 'none',
  MIMO_ROOT: MIMO_DIR,
  MIMO_ALLOWED_PATHS: '/root:/tmp:/home',
};

// Find elixir executable - ELIXIR_PATH is a PATH-style string
const elixirBinDirs = ELIXIR_PATH.split(':').filter(Boolean);
let elixirBin = 'elixir'; // default fallback to PATH
for (const dir of elixirBinDirs) {
  const candidate = `${dir}/elixir`;
  const check = Bun.spawnSync({ cmd: ['test', '-x', candidate] });
  if (check.exitCode === 0) {
    elixirBin = candidate;
    break;
  }
}

// Find mix executable
const mixBin = elixirBinDirs.map(d => `${d}/mix`).find(p => {
  const check = Bun.spawnSync({ cmd: ['test', '-x', p] });
  return check.exitCode === 0;
}) || 'mix';

// Spawn using Node's child_process.spawn for reliable stdin.pipe()
// Bun's native spawn has known stdin bugs (GitHub #13978)
const elixir = spawn(mixBin, [
  'run', '--no-halt', '--no-compile',
  '-e', 'Mimo.McpServer.Stdio.start()'
], {
  cwd: MIMO_DIR,
  env: spawnEnv,
  stdio: ['pipe', 'pipe', 'pipe']  // stdin/stdout/stderr all piped
});

// --- Startup Timeout ---

const STARTUP_TIMEOUT = 60000;
let startupComplete = false;

const startupTimer = setTimeout(() => {
  if (!startupComplete) {
    log('Startup timeout (60s) - killing process');
    elixir.kill();
    process.exit(1);
  }
}, STARTUP_TIMEOUT);

// --- STDIO Forwarding ---

// Error handlers for pipe stability
process.stdin.on('error', (err) => {
  log('stdin error:', err.message);
  // Don't exit immediately - try to continue
});

// Forward stdin using Node's reliable pipe() method
process.stdin.pipe(elixir.stdin);

// Handle stdin errors on the elixir side
elixir.stdin.on('error', (err) => {
  log('elixir.stdin error:', err.message);
});

// Handle stdin end
process.stdin.on('end', () => {
  log('stdin ended - client disconnected');
  try { elixir.stdin.end(); } catch { }
});

// Handle stdin close (different from end)
process.stdin.on('close', () => {
  log('stdin closed');
});

// Forward stdout - only JSON-RPC lines (using Node's event-based API)
let stdoutBuffer = '';
let lastActivity = Date.now();

// Stdout error handler
elixir.stdout.on('error', (err) => {
  log('elixir.stdout error:', err.message);
});

elixir.stdout.on('data', (data) => {
  lastActivity = Date.now();
  stdoutBuffer += data.toString();
  const lines = stdoutBuffer.split('\n');

  // Keep the last incomplete line in the buffer
  stdoutBuffer = lines.pop() || '';

  for (const line of lines) {
    const trimmed = line.trimStart();
    if (trimmed.startsWith('{')) {
      if (!startupComplete) {
        startupComplete = true;
        clearTimeout(startupTimer);
      }
      process.stdout.write(line + '\n');
    } else if (trimmed.length > 0) {
      process.stderr.write(`[Mimo Stdout Noise] ${line}\n`);
    }
  }
});

elixir.stdout.on('end', () => {
  if (stdoutBuffer.trimStart().startsWith('{')) {
    process.stdout.write(stdoutBuffer + '\n');
  } else if (stdoutBuffer.trim().length > 0) {
    process.stderr.write(`[Mimo Stdout Noise] ${stdoutBuffer}\n`);
  }
});

// Forward stderr with Hex error detection
let hexReinstallAttempted = false;

elixir.stderr.on('data', (data) => {
  const output = data.toString();

  // Detect Hex/OTP mismatch
  if (!hexReinstallAttempted &&
    ['Hex.State', 'op bs_add', 'beam_load', 're-compile this module']
      .some(p => output.includes(p))) {
    hexReinstallAttempted = true;
    log('Runtime Hex.State OTP mismatch - attempting reinstall');
    if (reinstallHex()) {
      process.stderr.write('[Mimo] OTP mismatch fixed. Please restart MCP server.\n');
    }
  }

  process.stderr.write(output);
});

// --- Activity Watchdog ---
// Log warning if no activity for extended period (may indicate stuck connection)
const ACTIVITY_WARNING_INTERVAL = 300000; // 5 minutes
setInterval(() => {
  if (startupComplete && !elixir.killed) {
    const inactiveMs = Date.now() - lastActivity;
    if (inactiveMs > ACTIVITY_WARNING_INTERVAL) {
      log(`No activity for ${Math.round(inactiveMs / 60000)} minutes - connection may be stuck`);
    }
  }
}, 60000); // Check every minute

// --- Process Exit ---

elixir.on('error', (err) => {
  log('Spawn error:', err.message);
  process.exit(1);
});

elixir.on('close', (code) => {
  clearTimeout(startupTimer);
  process.exit(code || 0);
});

// --- Signal Handlers ---

const cleanup = () => {
  elixir.kill();
  setTimeout(() => process.exit(0), 2500);
};

process.on('SIGTERM', cleanup);
process.on('SIGINT', cleanup);
process.on('SIGHUP', cleanup);
