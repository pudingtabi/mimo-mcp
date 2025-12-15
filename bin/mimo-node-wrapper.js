#!/usr/bin/env node
/**
 * Node.js wrapper for Mimo MCP server
 * This ensures proper stdio handling and buffering for VS Code
 * 
 * CRITICAL: MCP stdio transport requires ZERO output to stdout except JSON-RPC.
 * All logs MUST go to stderr only.
 * 
 * Improvements:
 * - Kills existing Mimo processes before starting
 * - Proper cleanup on exit to prevent zombie processes
 * - Timeout for startup to detect hangs early
 * - Better signal handling
 * - SIMPLE compilation check using Node.js fs.stat (no bash/bc dependencies)
 * - Async background compile if stale (eventual consistency model)
 * - Target: <1s startup via cached BEAM + graceful degradation
 */

// CRITICAL: Force all console output to stderr to prevent stdout contamination
// This MUST be at the very top before any other code runs
const originalLog = console.log;
console.log = function (...args) {
  console.error(...args);
};

// SILENT mode - suppress all wrapper logging to ensure clean MCP transport
const SILENT_MODE = process.env.MCP_SILENT !== '0';
const log = SILENT_MODE ? () => { } : (...args) => console.error('[Mimo Wrapper]', ...args);

function normalizeLocaleEnv(baseEnv) {
  return {
    ...baseEnv,
    LC_ALL: baseEnv.LC_ALL || 'C.UTF-8',
    LANG: baseEnv.LANG || 'C.UTF-8'
  };
}

const { spawn, spawnSync, execSync } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

function isValidMimoDir(dir) {
  if (!dir) return false;

  try {
    return fs.existsSync(path.join(dir, 'mix.exs'));
  } catch (_e) {
    return false;
  }
}

// MIMO_DIR: Prefer env var, but only if it points to a real checkout.
// This prevents stale environments from breaking MCP with EOF on startup.
const MIMO_DIR_FROM_ENV = process.env.MIMO_DIR ? path.resolve(process.env.MIMO_DIR) : null;
const MIMO_DIR_FROM_SCRIPT = path.resolve(__dirname, '..');
const MIMO_DIR = isValidMimoDir(MIMO_DIR_FROM_ENV) ? MIMO_DIR_FROM_ENV : MIMO_DIR_FROM_SCRIPT;

if (MIMO_DIR_FROM_ENV && MIMO_DIR !== MIMO_DIR_FROM_ENV) {
  log(`Ignoring invalid MIMO_DIR=${MIMO_DIR_FROM_ENV}; using ${MIMO_DIR}`);
}

// Find Elixir/OTP paths dynamically
function findElixirPaths() {
  const homeDir = os.homedir();
  const paths = [];

  // Check asdf first (most common in dev environments)
  const asdfShims = path.join(homeDir, '.asdf', 'shims');
  const asdfBin = path.join(homeDir, '.asdf', 'bin');
  if (fs.existsSync(asdfShims)) {
    paths.push(asdfShims);
  }
  if (fs.existsSync(asdfBin)) {
    paths.push(asdfBin);
  }

  // Also check elixir-install (alternative installer)
  // IMPORTANT: Prefer OTP 27 over OTP 28 to avoid Hex.State errors
  const elixirInstallDir = path.join(homeDir, '.elixir-install', 'installs');

  try {
    const elixirDir = path.join(elixirInstallDir, 'elixir');
    const otpDir = path.join(elixirInstallDir, 'otp');

    if (fs.existsSync(elixirDir)) {
      const versions = fs.readdirSync(elixirDir).sort();
      // Prefer otp-27 versions over otp-28 (Hex compatibility)
      const otp27Version = versions.find(v => v.includes('otp-27'));
      const selectedVersion = otp27Version || versions[0]; // Fallback to first
      if (selectedVersion) {
        paths.push(path.join(elixirDir, selectedVersion, 'bin'));
      }
    }

    if (fs.existsSync(otpDir)) {
      const versions = fs.readdirSync(otpDir).sort();
      // Prefer OTP 27.x over 28.x
      const otp27Version = versions.find(v => v.startsWith('27'));
      const selectedVersion = otp27Version || versions[0]; // Fallback to first
      if (selectedVersion) {
        paths.push(path.join(otpDir, selectedVersion, 'bin'));
      }
    }
  } catch (e) {
    // Ignore errors
  }

  return paths.filter(Boolean).join(':');
}

const ELIXIR_PATH = findElixirPaths();
const STARTUP_TIMEOUT = 60000; // 60 seconds to start
let startupTimer = null;
let elixir = null;
let isShuttingDown = false;

// Use configured MIX_ENV (default: dev)
const mixEnv = process.env.MIX_ENV || 'dev';

// Multi-instance stability: avoid background compilation storms / build-lock waits by default.
// Enable only when you explicitly want the wrapper to rebuild automatically.
const AUTO_COMPILE = ['1', 'true', 'TRUE', 'yes', 'YES'].includes(process.env.MIMO_WRAPPER_AUTO_COMPILE || '0');

function resolveMixBuildPath() {
  const raw = process.env.MIX_BUILD_PATH;
  if (!raw) return path.join(MIMO_DIR, '_build');
  return path.isAbsolute(raw) ? raw : path.resolve(MIMO_DIR, raw);
}

function buildArtefactPath(mixEnv) {
  return path.join(resolveMixBuildPath(), mixEnv, 'lib', 'mimo_mcp', 'ebin', 'mimo_mcp.app');
}

/**
 * Ensure build artefacts exist BEFORE starting MCP stdio.
 * If Mix compiles during MCP startup, it may print non-JSON lines to stdout
 * (e.g. "==> exqlite"), which corrupts VS Code MCP stdio parsing.
 */
function ensureCompiledSync(mixEnv) {
  const appPath = buildArtefactPath(mixEnv);
  if (fs.existsSync(appPath)) {
    return true;
  }

  log(` Build artifacts missing for MIX_ENV=${mixEnv}; compiling synchronously...`);

  const compileResult = spawnSync('/bin/bash', ['-c', `
    set -euo pipefail
    cd "${MIMO_DIR}"
    export PATH="${ELIXIR_PATH}:$PATH"
    export LC_ALL="C.UTF-8"
    export LANG="C.UTF-8"
    export ELIXIR_ERL_OPTIONS="+fnu"
    if [ -f .env ]; then
      set -a
      . .env 2>/dev/null || true
      set +a
    fi
    export MIX_ENV="${mixEnv}"
    export MIX_QUIET=1

    echo "[Mimo Compile] mix deps.get" >&2
    timeout 600s mix deps.get 2>&1 | while IFS= read -r line; do echo "[Mimo Compile] $line" >&2; done
    echo "[Mimo Compile] mix compile" >&2
    timeout 600s mix compile 2>&1 | while IFS= read -r line; do echo "[Mimo Compile] $line" >&2; done
  `], {
    cwd: MIMO_DIR,
    stdio: ['ignore', 'ignore', 'inherit'],
    env: normalizeLocaleEnv(process.env)
  });

  if (compileResult.status !== 0) {
    log(` Synchronous compilation failed (exit=${compileResult.status})`);
    return false;
  }

  return fs.existsSync(appPath);
}

// Kill any existing Mimo MCP processes BEFORE starting
function killExisting() {
  try {
    execSync('pkill -f "Mimo.McpServer.Stdio" 2>/dev/null || true', { stdio: 'ignore' });
    execSync('rm -f /tmp/mimo_mcp_stdio.lock 2>/dev/null || true', { stdio: 'ignore' });
    execSync('sleep 0.5', { stdio: 'ignore' });
  } catch (e) {
    // Ignore errors - processes may not exist
  }
}

/**
 * Check if compilation is needed using Node.js fs.stat (pure JavaScript, no bash/bc)
 * Returns true if any .ex file is newer than any .beam file
 * Falls back gracefully: if check fails, assume up-to-date and start anyway
 */
function needsCompilation() {
  try {
    // Find newest source file mtime
    const libDir = path.join(MIMO_DIR, 'lib');
    let newestSourceMtime = 0;

    function walkDir(dir) {
      const files = fs.readdirSync(dir, { withFileTypes: true });
      for (const file of files) {
        const fullPath = path.join(dir, file.name);
        if (file.isDirectory()) {
          walkDir(fullPath);
        } else if (file.isFile() && file.name.endsWith('.ex')) {
          const stat = fs.statSync(fullPath);
          if (stat.mtimeMs > newestSourceMtime) {
            newestSourceMtime = stat.mtimeMs;
          }
        }
      }
    }

    walkDir(libDir);

    // Find oldest BEAM file mtime
    const beamDir = path.join(resolveMixBuildPath(), mixEnv, 'lib', 'mimo_mcp', 'ebin');
    if (!fs.existsSync(beamDir)) {
      // No BEAM files exist - need compilation
      log(' No BEAM files found - compilation needed');
      return true;
    }

    const beamFiles = fs.readdirSync(beamDir).filter(f => f.endsWith('.beam'));
    if (beamFiles.length === 0) {
      log(' No BEAM files in ebin - compilation needed');
      return true;
    }

    let oldestBeamMtime = Infinity;
    for (const beamFile of beamFiles) {
      const stat = fs.statSync(path.join(beamDir, beamFile));
      if (stat.mtimeMs < oldestBeamMtime) {
        oldestBeamMtime = stat.mtimeMs;
      }
    }

    // If newest source is newer than oldest beam, we need compilation
    const stale = newestSourceMtime > oldestBeamMtime;
    if (stale) {
      log(' Source files newer than BEAM files - compilation needed');
    } else {
      log(' BEAM files up-to-date');
    }
    return stale;

  } catch (e) {
    // GRACEFUL FALLBACK: If check fails, assume up-to-date and start anyway
    // This prevents startup failures due to filesystem issues
    log(' Compilation check failed, assuming up-to-date:', e.message);
    return false; // Changed from true - fail safe, not fail secure
  }
}

/**
 * Trigger async background compilation (non-blocking)
 * This compiles for the NEXT startup, not the current one
 * Detached process runs independently and doesn't block startup
 */
function asyncCompile() {
  log(' Starting background compilation for next startup...');

  try {
    const compile = spawn('/bin/bash', ['-c', `
      cd "${MIMO_DIR}"
      # Ensure Elixir/OTP are in PATH
      export PATH="${ELIXIR_PATH}:$PATH"
      export LC_ALL="C.UTF-8"
      export LANG="C.UTF-8"
      export ELIXIR_ERL_OPTIONS="+fnu"
      if [ -f .env ]; then
        export $(grep -v '^#' .env | xargs 2>/dev/null)
      fi
      export MIX_ENV="${mixEnv}"
      
      echo "[Mimo Compile] Async compilation started..." >&2
      timeout 600s mix compile 2>&1 | while IFS= read -r line; do
        echo "[Mimo Compile] $line" >&2
      done
      echo "[Mimo Compile] Compilation complete - ready for next startup" >&2
    `], {
      stdio: ['ignore', 'ignore', 'pipe'],
      cwd: MIMO_DIR,
      detached: true,  // Detached so it runs independently
      env: normalizeLocaleEnv(process.env)
    });

    compile.stderr.on('data', (data) => {
      process.stderr.write(data);
    });

    compile.on('error', (err) => {
      // Log but don't fail - compilation is for next startup
      log('[Compile] Background compilation error:', err.message);
    });

    // Don't wait for it to finish - let it run in background
    compile.unref();
  } catch (e) {
    // If async compile fails to start, just log and continue
    // Server will still start with existing BEAM files
    log('[Compile] Failed to start background compilation:', e.message);
  }
}

function cleanup() {
  if (isShuttingDown) return;
  isShuttingDown = true;

  if (startupTimer) {
    clearTimeout(startupTimer);
    startupTimer = null;
  }

  if (elixir && !elixir.killed) {
    elixir.kill('SIGTERM');
    setTimeout(() => {
      if (elixir && !elixir.killed) {
        elixir.kill('SIGKILL');
      }
    }, 2000);
  }
}

/**
 * Reinstall Hex and Rebar to fix OTP version mismatch or missing packages
 * This is needed when Hex was compiled for a different OTP version
 * Error: "please re-compile this module with an Erlang/OTP 28 compiler"
 * Also ensures Hex is installed in fresh environments
 */
function reinstallHex() {
  log(' Reinstalling Hex and Rebar for current OTP version...');

  try {
    execSync(`
      cd "${MIMO_DIR}"
      export PATH="${ELIXIR_PATH}:$PATH"
      export LC_ALL="C.UTF-8"
      export LANG="C.UTF-8"
      export ELIXIR_ERL_OPTIONS="+fnu"
      if [ -f .env ]; then
        set -a
        . .env 2>/dev/null || true
        set +a
      fi
      mix local.hex --force 2>&1
      mix local.rebar --force 2>&1
    `, {
      stdio: 'pipe',
      timeout: 60000,
      cwd: MIMO_DIR,
      env: normalizeLocaleEnv(process.env)
    });
    log(' Hex and Rebar reinstalled successfully');
    return true;
  } catch (e) {
    log(' Failed to reinstall Hex:', e.message);
    return false;
  }
}

/**
 * Check if Hex needs reinstallation due to OTP mismatch or missing
 * Detects the "op bs_add" error pattern that indicates OTP version incompatibility
 * Also detects missing Hex package manager
 */
function checkHexOtpCompatibility() {
  try {
    // Try to load Hex and see if it fails with OTP mismatch
    const result = execSync(`
      cd "${MIMO_DIR}"
      export PATH="${ELIXIR_PATH}:$PATH"
      export LC_ALL="C.UTF-8"
      export LANG="C.UTF-8"
      export ELIXIR_ERL_OPTIONS="+fnu"
      mix hex.info 2>&1 || echo "HEX_CHECK_FAILED"
    `, {
      stdio: 'pipe',
      timeout: 30000,
      cwd: MIMO_DIR,
      env: normalizeLocaleEnv(process.env)
    }).toString();

    // Check for OTP mismatch or missing Hex patterns
    if (result.includes('beam_load') ||
      result.includes('op bs_add') ||
      result.includes('OTP 28') ||
      result.includes('re-compile this module') ||
      result.includes('Hex.State') ||
      result.includes('HEX_CHECK_FAILED') ||
      result.includes('Hex package manager') ||
      result.includes('Shall I install Hex')) {
      log(' Hex not installed or OTP version mismatch detected');
      return false;
    }

    return true;
  } catch (e) {
    // If check fails, assume Hex might need reinstallation
    log(' Hex compatibility check failed:', e.message);
    return false;
  }
}

// Multi-instance stability: do NOT kill other instances by default.
// Set MIMO_WRAPPER_KILL_EXISTING=1 if you explicitly want singleton behavior.
const KILL_EXISTING = ['1', 'true', 'TRUE', 'yes', 'YES'].includes(process.env.MIMO_WRAPPER_KILL_EXISTING || '0');
if (KILL_EXISTING) {
  killExisting();
}

// Check for Hex OTP compatibility BEFORE compilation check
// This fixes "Hex.State module not found" errors
const hexCompatible = checkHexOtpCompatibility();
if (!hexCompatible) {
  reinstallHex();
}

// Ensure we have build artifacts before starting MCP stdio
// This avoids Mix compiling during startup and leaking non-JSON to stdout.
ensureCompiledSync(mixEnv);

// Check if compilation is needed and trigger async compile if stale
// CRITICAL: This doesn't block startup - server starts immediately with cached BEAM
const stale = needsCompilation();
if (stale) {
  if (AUTO_COMPILE) {
    asyncCompile(); // Non-blocking - runs in background for next startup
  } else {
    log(' Compilation appears stale, but background compile is disabled (set MIMO_WRAPPER_AUTO_COMPILE=1 to enable)');
  }
}

// Spawn the Elixir process immediately with cached BEAM files
// Use --no-compile to skip synchronous compilation at startup
// CRITICAL: Do NOT use login shell (-l) as it may print motd/welcome messages
elixir = spawn('/bin/bash', ['-c', `
  cd "${MIMO_DIR}" 2>/dev/null
  export PATH="${ELIXIR_PATH}:$PATH"
  # Load .env silently - redirect ALL output to /dev/null
  if [ -f .env ]; then
    set -a
    . .env 2>/dev/null || true
    set +a
  fi
  export MIX_ENV="${mixEnv}"
  export MIX_QUIET=1
  export ELIXIR_ERL_OPTIONS="+fnu"
  export MIMO_HTTP_PORT=$((50000 + $$ % 10000))
  export MCP_PORT=$((40000 + $$ % 10000))
  export PROMETHEUS_DISABLED=true
  export MIMO_DISABLE_HTTP=true
  export LOGGER_LEVEL=none
  exec mix run --no-halt --no-compile -e "Mimo.McpServer.Stdio.start()"
`], {
  stdio: ['pipe', 'pipe', 'pipe'],
  cwd: MIMO_DIR,
  detached: false,
  env: normalizeLocaleEnv(process.env)
});

// Startup timeout
startupTimer = setTimeout(() => {
  log(' Startup timeout (60s) - killing process');
  cleanup();
  process.exit(1);
}, STARTUP_TIMEOUT);

// Forward stdin to Elixir
process.stdin.on('data', (data) => {
  if (elixir && elixir.stdin && !elixir.stdin.destroyed) {
    elixir.stdin.write(data);
  }
});

let stdinShutdownScheduled = false;
function scheduleStdinShutdown() {
  if (stdinShutdownScheduled) return;
  stdinShutdownScheduled = true;

  // Give the child a moment to react to EOF, then ensure cleanup.
  setTimeout(() => {
    cleanup();
    process.exit(0);
  }, 500);
}

process.stdin.on('end', () => {
  // Don’t hard-kill the child immediately; allow it to flush final JSON-RPC.
  if (elixir && elixir.stdin && !elixir.stdin.destroyed) {
    try { elixir.stdin.end(); } catch (_) { /* ignore */ }
  }

  scheduleStdinShutdown();
});

process.stdin.on('close', () => {
  if (elixir && elixir.stdin && !elixir.stdin.destroyed) {
    try { elixir.stdin.end(); } catch (_) { /* ignore */ }
  }

  scheduleStdinShutdown();
});

// Forward stdout, but ONLY JSON-RPC lines.
// Any non-JSON line is redirected to stderr to prevent VS Code MCP parse failures.
let stdoutBuffer = '';
elixir.stdout.on('data', (data) => {
  stdoutBuffer += data.toString();
  const lines = stdoutBuffer.split('\n');
  stdoutBuffer = lines.pop() || '';

  for (const line of lines) {
    const trimmed = line.trimStart();
    if (trimmed.startsWith('{')) {
      if (startupTimer) {
        clearTimeout(startupTimer);
        startupTimer = null;
      }
      process.stdout.write(line + '\n');
    } else if (trimmed.length > 0) {
      process.stderr.write(`[Mimo Stdout Noise] ${line}\n`);
    }
  }
});

elixir.stdout.on('end', () => {
  const trimmed = stdoutBuffer.trimStart();
  if (trimmed.startsWith('{')) {
    process.stdout.write(stdoutBuffer + '\n');
  } else if (trimmed.length > 0) {
    process.stderr.write(`[Mimo Stdout Noise] ${stdoutBuffer}\n`);
  }
  stdoutBuffer = '';
});

// Track if we've already attempted Hex reinstall this session
let hexReinstallAttempted = false;

// Forward stderr with Hex.State error detection
elixir.stderr.on('data', (data) => {
  const output = data.toString();

  // Detect Hex/OTP mismatch at runtime
  if (!hexReinstallAttempted &&
    (output.includes('Hex.State') ||
      output.includes('op bs_add') ||
      output.includes('beam_load') ||
      output.includes('re-compile this module'))) {
    hexReinstallAttempted = true;
    log(' Runtime Hex.State OTP mismatch detected - attempting reinstall and restart');

    // Reinstall Hex in background, then signal for restart
    const reinstalled = reinstallHex();
    if (reinstalled) {
      log(' Hex reinstalled - please restart the MCP server');
      // Output to stderr so VS Code can see the guidance
      process.stderr.write('[Mimo] OTP version mismatch fixed. Please restart the MCP server.\n');
    }
  }

  process.stderr.write(data);
});

// Handle process termination
elixir.on('close', (code) => {
  cleanup();
  process.exit(code || 0);
});

elixir.on('error', (err) => {
  log(' Failed to start Elixir:', err);
  cleanup();
  process.exit(1);
});

// Signal handlers
process.on('SIGTERM', () => {
  cleanup();
  setTimeout(() => process.exit(0), 2500);
});

process.on('SIGINT', () => {
  cleanup();
  setTimeout(() => process.exit(0), 2500);
});

process.on('SIGHUP', () => {
  cleanup();
  setTimeout(() => process.exit(0), 2500);
});

process.on('uncaughtException', (err) => {
  log(' Uncaught exception:', err);
  cleanup();
  process.exit(1);
});

process.stdin.resume();
