# Mimo-MCP Handoff Document

## Current Status: ✅ FULLY RESOLVED (Buffering Fix Complete)

**Last Updated:** 2025-11-25

### The Problem (FIXED)
~~VS Code MCP hangs indefinitely when calling MIMO tools, even though terminal tests work.~~

**Root cause was**: Output buffering at multiple layers:
1. Python `subprocess.Popen` default buffering
2. Elixir `IO.puts` buffered output
3. Docker exec pipe buffering

### Solution Implemented (3-Step Buffer Fix)

#### Step 1: Python Wrapper (`/usr/local/bin/mimo-mcp-stdio`)
- Uses `select()` for non-blocking I/O
- `bufsize=0` for unbuffered subprocess
- Explicit `flush=True` on all prints
- Proper handling of partial reads with output buffer

#### Step 2: Elixir CLI (`lib/mimo/mcp_cli.ex`)
- Force unbuffered I/O at startup: `:io.setopts(:standard_io, [:binary, {:encoding, :unicode}])`
- Use `:io.put_chars()` instead of `IO.puts()` for explicit flushing
- Immediate flush after each JSON response

#### Step 3: Verification Script (`debug_stream.py`)
- Simulates VS Code persistent connection
- Tests: initialize → notification → tools/list → tools/call → alive check
- All 5 tests pass with immediate responses

### What Works Now
- ✅ Mimo container running on VPS (217.216.73.22)
- ✅ SSH tunnel from VS Code container to host
- ✅ **Unbuffered JSON output** - responses return immediately
- ✅ All 5 skills cataloged (43 tools from manifest + 3 internal)
- ✅ **46 tools available** on `tools/list`
- ✅ **Persistent connections work** - multiple requests per session
- ✅ **ask_mimo LLM calls** - ~4s response time
- ✅ VS Code discovers all tools on first connection

### Architecture

```
VS Code Container (172.18.0.3)
    ↓ SSH
VPS Host (172.18.0.1)
    ↓ /usr/local/bin/mimo-mcp-stdio
mimo-mcp container
    ↓ mix run -e "Mimo.McpCli.run()"
    ↓
┌─────────────────────────────────────┐
│  Mimo.Skills.Catalog (ETS)          │  ← Instant tool listing
│  - 43 tools from manifest           │
│  - Lazy spawn on first call         │
└─────────────────────────────────────┘
    ↓ on-demand
[filesystem, exa_search, fetch, playwright, sequential_thinking]
```

### Key Files

| File | Location | Purpose |
|------|----------|---------|
| `mcp.json` | `/root/.vscode/mcp.json` | VS Code MCP config |
| `skills.json` | `priv/skills.json` | Skill process definitions |
| `skills_manifest.json` | `priv/skills_manifest.json` | Pre-generated tool catalog |
| `mcp_cli.ex` | `lib/mimo/mcp_cli.ex` | One-shot CLI for stdio |
| `catalog.ex` | `lib/mimo/skills/catalog.ex` | Static tool catalog (ETS) |
| `application.ex` | `lib/mimo/application.ex` | App startup, waits for catalog |
| `mimo-mcp-stdio` | `/usr/local/bin/mimo-mcp-stdio` (on VPS host) | Wrapper script |

### Wrapper Script (VPS Host)

**Location:** `/usr/local/bin/mimo-mcp-stdio`

The wrapper uses:
- Non-blocking I/O with `select()`
- `bufsize=0` for unbuffered subprocess pipes
- Explicit `flush=True` on all output
- Filters only JSON lines (starting with `{`)

```python
# Key buffering fixes in the wrapper:
os.environ['PYTHONUNBUFFERED'] = '1'
sys.stdout = os.fdopen(sys.stdout.fileno(), 'w', buffering=1)

proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, 
                        stderr=subprocess.PIPE, bufsize=0)

# Non-blocking read with select()
readable, _, _ = select.select([stdout_fd], [], [], 1.0)

# Always flush output
print(line, flush=True)
```

### Testing

```bash
# Quick one-shot test (should return immediately)
echo '{"jsonrpc":"2.0","id":1,"method":"initialize"}' | \
  ssh -T root@172.18.0.1 /usr/local/bin/mimo-mcp-stdio

# Multi-request test
{ echo '{"jsonrpc":"2.0","id":1,"method":"initialize"}'; sleep 0.3; \
  echo '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'; sleep 0.3; } | \
  timeout 15 ssh -T root@172.18.0.1 /usr/local/bin/mimo-mcp-stdio

# Full persistent connection test (run from vscode-tunnel)
python3 debug_stream.py --host root@172.18.0.1

# Check wrapper debug log
ssh root@172.18.0.1 'cat /tmp/mcp-wrapper.log'
```

### Regenerating Manifest

If you add/remove skills, regenerate the manifest:

```bash
# Inside container
mix generate_manifest

# Or manually copy updated manifest
docker cp priv/skills_manifest.json mimo-mcp:/app/priv/
docker restart mimo-mcp
```

### Container Commands

```bash
# SSH to host
ssh root@172.18.0.1

# Check logs
docker logs mimo-mcp 2>&1 | tail -50

# Restart
docker restart mimo-mcp

# Rebuild after code changes
cd /root/mrc-server/mimo-mcp
git pull
docker-compose down
docker-compose build --no-cache
docker-compose up -d
```

### GitHub Repo
https://github.com/pudingtabi/mimo-mcp

---

## Future Improvements

1. **Native Elixir Tools** - Implement filesystem, fetch, etc. directly in Elixir (no npx spawning)
2. **Persistent Skill Processes** - Keep skills running instead of lazy-spawn
3. **WebSocket Transport** - Alternative to stdio for better performance
4. **Release Build** - Use `mix release` for faster startup (no compilation)

---

## Troubleshooting

### VS Code MCP Still Not Working?

1. **Reload MCP servers**: In VS Code, run "Developer: Reload Window" or restart
2. **Check wrapper log**: `ssh root@172.18.0.1 'cat /tmp/mcp-wrapper.log'`
3. **Run debug script**: `python3 debug_stream.py` to verify buffering fix
4. **Verify wrapper deployed**: `ssh root@172.18.0.1 'cat /usr/local/bin/mimo-mcp-stdio | head -20'`

### Common Issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| Hangs indefinitely | Buffering issue | Deploy updated wrapper script |
| "stdbuf not found" | Container missing coreutils | Don't use stdbuf, use Python wrapper |
| Empty response | Elixir output buffered | Update mcp_cli.ex with `:io.put_chars` |
| 3 tools only | Manifest not loaded | Run `mix generate_manifest` |
| Process exits 127 | Wrong binary path | Use `mix run -e` not `/app/bin/mimo_mcp` |

### Debug Log Format

```
[PID] HH:MM:SS === SESSION START ===
[PID] HH:MM:SS Starting: docker exec ...
[PID] HH:MM:SS [IN] {"jsonrpc":"2.0",...}    # Request received
[PID] HH:MM:SS [OUT] {"id":1,...}            # Response sent
[PID] HH:MM:SS [SKIP] 09:12:51.931 [info]... # Filtered non-JSON
[PID] HH:MM:SS [ERR] ...                     # Stderr from container
[PID] HH:MM:SS EOF from stdin
[PID] HH:MM:SS === SESSION END ===
```
