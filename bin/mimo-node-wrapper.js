#!/usr/bin/env node
/**
 * Node.js wrapper for Mimo MCP server
 * This ensures proper stdio handling and buffering for VS Code
 */
const { spawn } = require('child_process');
const readline = require('readline');

const MIMO_DIR = '/workspace/mrc-server/mimo-mcp';

// Spawn the Elixir process with proper shell environment
const elixir = spawn('/bin/bash', ['-l', '-c', `
  cd "${MIMO_DIR}"
  export MIX_ENV=dev
  export ELIXIR_ERL_OPTIONS="+fnu"
  export MIMO_HTTP_PORT=$((50000 + $$ % 10000))
  export MCP_PORT=$((40000 + $$ % 10000))
  export PROMETHEUS_DISABLED=true
  export MIMO_DISABLE_HTTP=true
  export LOGGER_LEVEL=none
  exec mix run --no-halt --no-compile -e "Mimo.McpServer.Stdio.start()"
`], {
  stdio: ['pipe', 'pipe', 'pipe'],
  cwd: MIMO_DIR
});

// Forward stdin to Elixir directly
process.stdin.on('data', (data) => {
  elixir.stdin.write(data);
});

// When stdin closes (EOF), close Elixir's stdin to signal shutdown
process.stdin.on('end', () => {
  elixir.stdin.end();
});

process.stdin.on('close', () => {
  elixir.stdin.end();
});

// Forward Elixir stdout to our stdout
elixir.stdout.on('data', (data) => {
  process.stdout.write(data);
});

// Forward stderr for debugging
elixir.stderr.on('data', (data) => {
  process.stderr.write(data);
});

// Handle process termination
elixir.on('close', (code) => {
  process.exit(code || 0);
});

elixir.on('error', (err) => {
  console.error('Failed to start Elixir process:', err);
  process.exit(1);
});

process.on('SIGTERM', () => {
  elixir.kill('SIGTERM');
  setTimeout(() => process.exit(0), 500);
});

process.on('SIGINT', () => {
  elixir.kill('SIGINT');
  setTimeout(() => process.exit(0), 500);
});

// Keep process alive while stdin is open
process.stdin.resume();
