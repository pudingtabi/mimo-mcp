#!/usr/bin/env node
/**
 * Node.js wrapper for Mimo MCP server
 * This ensures proper stdio handling and buffering for VS Code
 * 
 * Improvements:
 * - Proper cleanup on exit to prevent zombie processes
 * - Timeout for startup to detect hangs early
 * - Better signal handling
 */
const { spawn } = require('child_process');
const path = require('path');

const MIMO_DIR = '/workspace/mrc-server/mimo-mcp';
const STARTUP_TIMEOUT = 30000; // 30 seconds to start
let startupTimer = null;
let elixir = null;
let isShuttingDown = false;

function cleanup() {
  if (isShuttingDown) return;
  isShuttingDown = true;
  
  if (startupTimer) {
    clearTimeout(startupTimer);
    startupTimer = null;
  }
  
  if (elixir && !elixir.killed) {
    elixir.kill('SIGTERM');
    // Force kill after 2 seconds if still alive
    setTimeout(() => {
      if (elixir && !elixir.killed) {
        elixir.kill('SIGKILL');
      }
    }, 2000);
  }
}

// Spawn the Elixir process with proper shell environment
elixir = spawn('/bin/bash', ['-l', '-c', `
  cd "${MIMO_DIR}"
  # Load .env file
  if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
  fi
  export MIX_ENV=dev
  export ELIXIR_ERL_OPTIONS="+fnu"
  export MIMO_HTTP_PORT=$((50000 + $$ % 10000))
  export MCP_PORT=$((40000 + $$ % 10000))
  export PROMETHEUS_DISABLED=true
  export MIMO_DISABLE_HTTP=true
  export LOGGER_LEVEL=none
  exec mix run --no-halt -e "Mimo.McpServer.Stdio.start()"
`], {
  stdio: ['pipe', 'pipe', 'pipe'],
  cwd: MIMO_DIR,
  detached: false  // Don't detach - we want clean shutdown
});

// Startup timeout - if no output in 30s, something is wrong
startupTimer = setTimeout(() => {
  console.error('MCP server startup timeout - killing process');
  cleanup();
  process.exit(1);
}, STARTUP_TIMEOUT);

// Forward stdin to Elixir directly
process.stdin.on('data', (data) => {
  if (elixir && elixir.stdin && !elixir.stdin.destroyed) {
    elixir.stdin.write(data);
  }
});

// When stdin closes (EOF), trigger clean shutdown
process.stdin.on('end', () => {
  cleanup();
  setTimeout(() => process.exit(0), 500);
});

process.stdin.on('close', () => {
  cleanup();
  setTimeout(() => process.exit(0), 500);
});

// Forward Elixir stdout to our stdout
elixir.stdout.on('data', (data) => {
  // Clear startup timeout on first output
  if (startupTimer) {
    clearTimeout(startupTimer);
    startupTimer = null;
  }
  process.stdout.write(data);
});

// Forward stderr for debugging (to stderr, not stdout)
elixir.stderr.on('data', (data) => {
  process.stderr.write(data);
});

// Handle process termination
elixir.on('close', (code) => {
  cleanup();
  process.exit(code || 0);
});

elixir.on('error', (err) => {
  console.error('Failed to start Elixir process:', err);
  cleanup();
  process.exit(1);
});

// Signal handlers for clean shutdown
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

// Cleanup on uncaught errors
process.on('uncaughtException', (err) => {
  console.error('Uncaught exception:', err);
  cleanup();
  process.exit(1);
});

// Keep process alive while stdin is open
process.stdin.resume();
