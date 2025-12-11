#!/usr/bin/env node
/**
 * Minimal MCP wrapper - no bash, no logging, direct stdio forwarding
 * Loads .env file for API keys and configuration
 * 
 * CRITICAL: Only forwards lines starting with { to stdout (JSON-RPC)
 * This filters out any Elixir/Erlang warnings that leak to stdout
 * 
 * Supports multiple environments: /root, /workspace (GitHub Codespaces)
 */

// Force all console output to stderr
console.log = console.error;

const { spawn, execSync } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const MIMO_DIR = path.resolve(__dirname, '..');

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

      if (fs.existsSync(elixirDir)) {
        const versions = fs.readdirSync(elixirDir);
        // Prefer OTP 27 versions (Mimo compiled with OTP 27)
        const otp27Version = versions.find(v => v.includes('otp-27'));
        const selectedVersion = otp27Version || versions[versions.length - 1];
        if (selectedVersion) {
          paths.push(path.join(elixirDir, selectedVersion, 'bin'));
        }
      }

      if (fs.existsSync(otpDir)) {
        const versions = fs.readdirSync(otpDir);
        // Prefer OTP 27 versions
        const otp27Version = versions.find(v => v.startsWith('27'));
        const selectedVersion = otp27Version || versions[versions.length - 1];
        if (selectedVersion) {
          paths.push(path.join(otpDir, selectedVersion, 'bin'));
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
  MIX_ENV: 'prod',
  ELIXIR_ERL_OPTIONS: '+fnu',
  PROMETHEUS_DISABLED: 'true',
  MIMO_DISABLE_HTTP: 'true',
  LOGGER_LEVEL: 'none'  // Suppress logs - MCP expects clean JSON-RPC on stdout
};

// Spawn mix directly (no bash)

const elixir = spawn(MIX_PATH, [
  'run', '--no-halt', '--no-compile',
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
