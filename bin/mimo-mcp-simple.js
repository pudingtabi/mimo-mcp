#!/usr/bin/env node
/**
 * Minimal MCP wrapper - no bash, no logging, direct stdio forwarding
 * Loads .env file for API keys and configuration
 * 
 * CRITICAL: Only forwards lines starting with { to stdout (JSON-RPC)
 * This filters out any Elixir/Erlang warnings that leak to stdout
 * 
 * Supports multiple environments: /root, /workspace (GitHub Codespaces)
 * 
 * MIMO_DIR resolution priority:
 * 1. MIMO_DIR environment variable (if set)
 * 2. Script location (bin/ -> parent directory)
 */

// Force all console output to stderr
console.log = console.error;

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
  console.error(`[mimo-mcp] Ignoring invalid MIMO_DIR=${MIMO_DIR_FROM_ENV}; using ${MIMO_DIR}`);
}

// Dynamic path detection for multiple environments
// CRITICAL: We must use actual install paths, NOT shims
// asdf shims require the full asdf environment to work
function findElixirPaths() {
  const homeDir = os.homedir();
  const paths = [];

  // Check multiple possible Elixir installation locations
  const possibleRoots = ['/root', '/workspace', homeDir];

  for (const root of possibleRoots) {
    // asdf ACTUAL INSTALLS (not shims!)
    // Read .tool-versions to find correct versions
    const asdfInstalls = path.join(root, '.asdf', 'installs');
    const toolVersionsPath = path.join(MIMO_DIR, '.tool-versions');

    try {
      let elixirVersion = null;
      let erlangVersion = null;

      if (fs.existsSync(toolVersionsPath)) {
        const content = fs.readFileSync(toolVersionsPath, 'utf8');
        const lines = content.split('\n');
        for (const line of lines) {
          const [tool, version] = line.trim().split(/\s+/);
          if (tool === 'elixir') elixirVersion = version;
          if (tool === 'erlang') erlangVersion = version;
        }
      }

      // Erlang path (MUST come first in PATH)
      const erlangDir = path.join(asdfInstalls, 'erlang');
      if (fs.existsSync(erlangDir)) {
        const versions = fs.readdirSync(erlangDir);
        const selectedVersion = erlangVersion || versions[versions.length - 1];
        const erlangBin = path.join(erlangDir, selectedVersion, 'bin');
        if (fs.existsSync(erlangBin)) {
          paths.push(erlangBin);
        }
      }

      // Elixir path
      const elixirDir = path.join(asdfInstalls, 'elixir');
      if (fs.existsSync(elixirDir)) {
        const versions = fs.readdirSync(elixirDir);
        const selectedVersion = elixirVersion || versions[versions.length - 1];
        const elixirBin = path.join(elixirDir, selectedVersion, 'bin');
        if (fs.existsSync(elixirBin)) {
          paths.push(elixirBin);
        }
      }
    } catch (e) { /* ignore */ }

    // elixir-install
    const elixirInstallDir = path.join(root, '.elixir-install', 'installs');
    try {
      const elixirDir = path.join(elixirInstallDir, 'elixir');
      const otpDir = path.join(elixirInstallDir, 'otp');

      // Read target versions from .tool-versions for dynamic version selection
      let targetOtp = null;
      let targetElixir = null;
      const toolVersionsPath = path.join(MIMO_DIR, '.tool-versions');

      if (fs.existsSync(toolVersionsPath)) {
        const content = fs.readFileSync(toolVersionsPath, 'utf8');
        const lines = content.split('\n');
        for (const line of lines) {
          const [tool, version] = line.trim().split(/\s+/);
          if (tool === 'erlang') targetOtp = version;
          if (tool === 'elixir') targetElixir = version;
        }
      }

      // OTP/Erlang must come FIRST in PATH
      if (fs.existsSync(otpDir)) {
        const versions = fs.readdirSync(otpDir);
        // Prefer version from .tool-versions, otherwise use latest
        const matchingVersion = targetOtp ? versions.find(v => v.startsWith(targetOtp.split('.')[0])) : null;
        const selectedVersion = matchingVersion || versions[versions.length - 1];
        if (selectedVersion) {
          const otpBin = path.join(otpDir, selectedVersion, 'bin');
          if (fs.existsSync(otpBin)) paths.push(otpBin);
        }
      }

      // Elixir comes AFTER OTP
      if (fs.existsSync(elixirDir)) {
        const versions = fs.readdirSync(elixirDir);
        // Prefer version from .tool-versions, otherwise use latest
        // Match by extracting OTP version suffix (e.g., "otp-28" from "1.19.3-otp-28")
        const targetOtpSuffix = targetElixir ? targetElixir.match(/otp-\d+/)?.[0] : null;
        const matchingVersion = targetOtpSuffix ? versions.find(v => v.includes(targetOtpSuffix)) : null;
        const selectedVersion = matchingVersion || versions[versions.length - 1];
        if (selectedVersion) {
          const elixirBin = path.join(elixirDir, selectedVersion, 'bin');
          if (fs.existsSync(elixirBin)) paths.push(elixirBin);
        }
      }
    } catch (e) { /* ignore */ }
  }

  // System-wide installations (fallback)
  if (fs.existsSync('/usr/local/bin/mix')) {
    paths.push('/usr/local/bin');
  }

  return paths.filter(Boolean);
}

function findMix() {
  const elixirPaths = findElixirPaths();

  // Check each path for mix
  for (const p of elixirPaths) {
    const mixPath = path.join(p, 'mix');
    if (fs.existsSync(mixPath)) {
      return mixPath;
    }
  }

  // Fallback: try to find mix in PATH
  try {
    const mixPath = execSync('which mix', { encoding: 'utf8' }).trim();
    if (mixPath && fs.existsSync(mixPath)) {
      return mixPath;
    }
  } catch (e) { /* ignore */ }

  // Last resort: assume it's in PATH
  return 'mix';
}

const ELIXIR_PATHS = findElixirPaths();
const MIX_PATH = findMix();

// Load .env file if it exists
function loadEnvFile(envPath) {
  try {
    if (fs.existsSync(envPath)) {
      const content = fs.readFileSync(envPath, 'utf8');
      const lines = content.split('\n');
      const envVars = {};
      for (const line of lines) {
        const trimmed = line.trim();
        if (trimmed && !trimmed.startsWith('#')) {
          const eqIndex = trimmed.indexOf('=');
          if (eqIndex > 0) {
            const key = trimmed.substring(0, eqIndex).trim();
            let value = trimmed.substring(eqIndex + 1).trim();
            // Remove quotes if present
            if ((value.startsWith('"') && value.endsWith('"')) ||
              (value.startsWith("'") && value.endsWith("'"))) {
              value = value.slice(1, -1);
            }
            envVars[key] = value;
          }
        }
      }
      return envVars;
    }
  } catch (e) {
    // Silently ignore errors
  }
  return {};
}

const dotEnv = loadEnvFile(path.join(MIMO_DIR, '.env'));

// Set up environment - merge .env with process.env and overrides
const env = {
  ...process.env,
  ...dotEnv,
  PATH: `${ELIXIR_PATHS.join(':')}:${process.env.PATH}`,
  // Default to dev, but allow explicit override per-environment.
  MIX_ENV: process.env.MIX_ENV || dotEnv.MIX_ENV || 'dev',
  ELIXIR_ERL_OPTIONS: '+fnu',
  PROMETHEUS_DISABLED: 'true',
  MIMO_DISABLE_HTTP: 'true',
  LOGGER_LEVEL: 'none' // Suppress logs - MCP expects clean JSON-RPC on stdout
};

function resolveMixBuildPath() {
  const raw = env.MIX_BUILD_PATH;
  if (!raw) return path.join(MIMO_DIR, '_build');
  return path.isAbsolute(raw) ? raw : path.resolve(MIMO_DIR, raw);
}

function buildArtefactPath(mixEnv) {
  return path.join(resolveMixBuildPath(), mixEnv, 'lib', 'mimo_mcp', 'ebin', 'mimo_mcp.app');
}

function wantsAutoCompile() {
  const v = env.MIMO_WRAPPER_AUTO_COMPILE;
  return v === '1' || v === 'true' || v === 'TRUE' || v === 'yes' || v === 'YES';
}

function ensureCompiledSync(mixEnv) {
  const appPath = buildArtefactPath(mixEnv);
  if (fs.existsSync(appPath)) return true;

  if (!wantsAutoCompile()) return false;

  console.error(`[mimo-mcp] Build artifacts missing for MIX_ENV=${mixEnv}; attempting mix compile (stderr-only)...`);

  const baseEnv = {
    ...env,
    MIX_ENV: mixEnv,
    MIX_QUIET: '1',
    LC_ALL: env.LC_ALL || 'C.UTF-8',
    LANG: env.LANG || 'C.UTF-8'
  };

  const deps = spawnSync(MIX_PATH, ['deps.get'], {
    cwd: MIMO_DIR,
    env: baseEnv,
    stdio: ['ignore', 'pipe', 'pipe']
  });

  if (deps.stdout && deps.stdout.length) console.error(deps.stdout.toString());
  if (deps.stderr && deps.stderr.length) console.error(deps.stderr.toString());
  if (deps.status !== 0) return false;

  const compile = spawnSync(MIX_PATH, ['compile'], {
    cwd: MIMO_DIR,
    env: baseEnv,
    stdio: ['ignore', 'pipe', 'pipe']
  });

  if (compile.stdout && compile.stdout.length) console.error(compile.stdout.toString());
  if (compile.stderr && compile.stderr.length) console.error(compile.stderr.toString());
  if (compile.status !== 0) return false;

  return fs.existsSync(appPath);
}

// ============================================================================
// PRE-FLIGHT VALIDATION (CRITICAL: Prevents silent failures causing EOF errors)
// Added per Mimo memory analysis - recurring EOF root cause was missing validation
// ============================================================================
function validateEnvironment() {
  const errors = [];
  const mixEnv = env.MIX_ENV || 'dev';

  // 1. Check Elixir paths found
  if (ELIXIR_PATHS.length === 0) {
    errors.push('No Elixir installation found. Check .elixir-install or .asdf installs.');
  }

  // 2. Check mix exists and is not just a fallback string
  if (MIX_PATH === 'mix') {
    errors.push('Mix binary not found in any known path. Install Elixir or fix PATH.');
  } else if (!fs.existsSync(MIX_PATH)) {
    errors.push(`Mix not found at: ${MIX_PATH}`);
  }

  // 3. Check build artefact exists (respect MIX_BUILD_PATH if set)
  const appPath = buildArtefactPath(mixEnv);
  if (!fs.existsSync(appPath)) {
    const compiled = ensureCompiledSync(mixEnv);
    if (!compiled) {
      const hint = wantsAutoCompile()
        ? `Tried auto-compile but still missing. Run: cd ${MIMO_DIR} && MIX_ENV=${mixEnv} mix compile`
        : `Run: cd ${MIMO_DIR} && MIX_ENV=${mixEnv} mix compile (or set MIMO_WRAPPER_AUTO_COMPILE=1)`;

      errors.push(`Build artifacts missing for MIX_ENV=${mixEnv}. Expected: ${appPath}. ${hint}`);
    }
  }

  // 4. Report errors to stderr and exit with clear message
  if (errors.length > 0) {
    console.error('');
    console.error('╔═══════════════════════════════════════════════════════════╗');
    console.error('║         MCP WRAPPER PRE-FLIGHT VALIDATION FAILED          ║');
    console.error('╚═══════════════════════════════════════════════════════════╝');
    console.error('');
    errors.forEach(e => console.error('  ✗ ' + e));
    console.error('');
    console.error('Detected paths:', ELIXIR_PATHS.length > 0 ? ELIXIR_PATHS : '(none)');
    console.error('Mix path:', MIX_PATH);
    console.error('MIX_ENV:', mixEnv);
    console.error('MIMO_DIR:', MIMO_DIR);
    console.error('MIX_BUILD_PATH:', env.MIX_BUILD_PATH || '(default: _build under MIMO_DIR)');
    console.error('');
    process.exit(1);
  }
}

// Run validation BEFORE spawning Elixir
validateEnvironment();

// Spawn mix directly (no bash)

const elixir = spawn(MIX_PATH, [
  'run', '--no-halt',
  '-e', 'Mimo.McpServer.Stdio.start()'
], {
  cwd: MIMO_DIR,
  env: env,
  stdio: ['pipe', 'pipe', 'ignore']  // stdin/stdout piped, stderr ignored for clean MCP
});

// Forward stdin to Elixir
process.stdin.pipe(elixir.stdin);

// CRITICAL: Filter stdout to only forward JSON-RPC lines
// This prevents Elixir/Erlang warnings from corrupting the JSON-RPC stream
let buffer = '';
elixir.stdout.on('data', (data) => {
  buffer += data.toString();
  const lines = buffer.split('\n');

  // Keep the last incomplete line in the buffer
  buffer = lines.pop() || '';

  for (const line of lines) {
    // Only forward lines that start with { (valid JSON-RPC)
    if (line.trim().startsWith('{')) {
      process.stdout.write(line + '\n');
    }
    // Silently drop non-JSON lines (warnings, logs, etc.)
  }
});

// Flush any remaining buffer on close
elixir.stdout.on('end', () => {
  if (buffer.trim().startsWith('{')) {
    process.stdout.write(buffer + '\n');
  }
});

// Handle errors silently
elixir.on('error', () => process.exit(1));
elixir.on('close', (code) => process.exit(code || 0));

process.stdin.on('end', () => {
  elixir.stdin.end();
});
