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
 */

import { spawn, spawnSync } from "bun";
import { existsSync, readdirSync, statSync } from "fs";
import { join, resolve, isAbsolute } from "path";
import { homedir } from "os";

// CRITICAL: Force all console output to stderr
const originalLog = console.log;
console.log = (...args) => console.error(...args);

// SILENT mode - suppress wrapper logging for clean MCP transport
const SILENT_MODE = Bun.env.MCP_SILENT !== '0';
const log = SILENT_MODE ? () => {} : (...args) => console.error('[Mimo Bun]', ...args);

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

  // elixir-install - PREFER OTP 27 over OTP 28 (Hex compatibility)
  try {
    const elixirDir = join(home, '.elixir-install', 'installs', 'elixir');
    const otpDir = join(home, '.elixir-install', 'installs', 'otp');

    if (existsSync(elixirDir)) {
      const versions = readdirSync(elixirDir).sort();
      const otp27Version = versions.find(v => v.includes('otp-27'));
      const selectedVersion = otp27Version || versions[0];
      if (selectedVersion) {
        paths.push(join(elixirDir, selectedVersion, 'bin'));
      }
    }
    if (existsSync(otpDir)) {
      const versions = readdirSync(otpDir).sort();
      const otp27Version = versions.find(v => v.startsWith('27'));
      const selectedVersion = otp27Version || versions[0];
      if (selectedVersion) {
        paths.push(join(otpDir, selectedVersion, 'bin'));
      }
    }
  } catch {}

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
    spawnSync({ cmd: ['pkill', '-f', 'Mimo.McpServer.Stdio'], stdout: 'ignore', stderr: 'ignore' });
    spawnSync({ cmd: ['rm', '-f', '/tmp/mimo_mcp_stdio.lock'], stdout: 'ignore', stderr: 'ignore' });
    // Use sync sleep via spawnSync instead of top-level await
    spawnSync({ cmd: ['sleep', '0.5'], stdout: 'ignore', stderr: 'ignore' });
  } catch {}
}

// --- Pre-flight Checks ---

if (!checkHexOtpCompatibility()) {
  reinstallHex();
}

ensureCompiledSync();

// --- Spawn Elixir MCP Server ---

log('Starting Mimo MCP server...');

const elixir = spawn({
  cmd: ['bash', '-c', `
    cd "${MIMO_DIR}" 2>/dev/null
    export PATH="${ELIXIR_PATH}:$PATH"
    [ -f .env ] && { set -a; . .env 2>/dev/null || true; set +a; }
    export MIX_ENV="${mixEnv}"
    export MIX_QUIET=1
    export ELIXIR_ERL_OPTIONS="+fnu"
    export MIMO_HTTP_PORT=$((50000 + $$ % 10000))
    export MCP_PORT=$((40000 + $$ % 10000))
    export PROMETHEUS_DISABLED=true
    export MIMO_DISABLE_HTTP=true
    export LOGGER_LEVEL=none
    export MIMO_ROOT="${MIMO_DIR}"
    export MIMO_ALLOWED_PATHS="/root:/tmp:/home"
    exec mix run --no-halt --no-compile -e "Mimo.McpServer.Stdio.start()"
  `],
  cwd: MIMO_DIR,
  env: buildEnv(),
  stdin: 'pipe',
  stdout: 'pipe',
  stderr: 'pipe',
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

// Forward stdin to Elixir
(async () => {
  const reader = Bun.stdin.stream().getReader();
  const writer = elixir.stdin;
  
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        writer.end();
        break;
      }
      writer.write(value);
    }
  } catch {
    // stdin closed
  }
  
  // Give child time to flush, then exit
  await Bun.sleep(500);
  process.exit(0);
})();

// Forward stdout - only JSON-RPC lines
(async () => {
  const reader = elixir.stdout.getReader();
  const decoder = new TextDecoder();
  let buffer = '';

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      
      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split('\n');
      buffer = lines.pop() || '';

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
    }
    
    // Flush remaining buffer
    if (buffer.trimStart().startsWith('{')) {
      process.stdout.write(buffer + '\n');
    } else if (buffer.trim().length > 0) {
      process.stderr.write(`[Mimo Stdout Noise] ${buffer}\n`);
    }
  } catch {}
})();

// Forward stderr with Hex error detection
let hexReinstallAttempted = false;

(async () => {
  const reader = elixir.stderr.getReader();
  const decoder = new TextDecoder();

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      
      const output = decoder.decode(value, { stream: true });
      
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
    }
  } catch {}
})();

// --- Process Exit ---

elixir.exited.then((code) => {
  clearTimeout(startupTimer);
  process.exit(code);
});

// --- Signal Handlers ---

const cleanup = () => {
  elixir.kill();
  setTimeout(() => process.exit(0), 2500);
};

process.on('SIGTERM', cleanup);
process.on('SIGINT', cleanup);
process.on('SIGHUP', cleanup);
