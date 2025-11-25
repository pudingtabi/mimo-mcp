# Mimo-MCP Handoff Document

## Current Status: ❌ VS Code MCP Still Hanging

**Last Updated:** 2025-11-25 10:46 UTC

---

## The Problem

**VS Code MCP hangs indefinitely when calling MIMO tools.** Terminal tests work perfectly.

### What Works ✅
- Terminal single-request tests (via `echo | ssh`)
- `debug_stream.py` test script (sends requests one-at-a-time with waits)
- Docker container is healthy
- Elixir MCP server returns correct JSON-RPC responses
- All 46 tools are available

### What Fails ❌
- VS Code MCP integration hangs on `tools/list` response
- Never receives response, eventually cancels after ~60s timeout

---

## Root Cause Analysis

### The Symptom (from wrapper log)

```
[1228153] 10:45:19 [OUT] {"id":1,...}                    # initialize response SENT ✅
[1228153] 10:45:19 [IN] notifications/initialized        # notification received
[1228153] 10:45:19 [IN] tools/list (id=2)               # request received
[1228153] 10:45:19 [IN] tools/call ask_mimo (id=3)      # request received
                        ^^^ NO [OUT] for tools/list! ^^^
[1228153] 10:46:29 [IN] notifications/cancelled          # VS Code gives up after ~70s
```

### Key Observation

| Test Method | Request Pattern | Result |
|-------------|-----------------|--------|
| Terminal `echo \| ssh` | Single request, stdin closes | ✅ Works |
| `debug_stream.py` | One request, wait for response, repeat | ✅ Works |
| VS Code MCP | Multiple requests sent rapidly before responses | ❌ Hangs |

**VS Code sends requests WITHOUT waiting for responses:**
1. `initialize` → sends immediately
2. `notifications/initialized` → sends immediately  
3. `tools/list` → sends immediately (before initialize response!)
4. `tools/call` → sends immediately (before tools/list response!)

### The Likely Issue

The Python wrapper or Elixir server can't handle **pipelined requests** properly. When multiple requests arrive before responses are sent:

1. Elixir processes requests sequentially
2. Logger output (`[info] 📦 Cataloged...`) is mixed with stdout
3. Response for `tools/list` may be stuck in a buffer
4. Or the large `tools/list` response (~7KB JSON) is being truncated/delayed

### Evidence

From the log:
```
[1228153] 10:45:19 [RAW_OUT] 241 bytes    # Some output received
[1228153] 10:45:19 [SKIP] 09:45:19.807... # Logger lines (on stdout!)
[1228153] 10:45:19 [RAW_OUT] 122 bytes    # More output
[1228153] 10:45:19 [SKIP] ...             # More logger
[1228153] 10:45:19 [RAW_OUT] 57 bytes     # Fragmented reads
[1228153] 10:45:19 [RAW_OUT] 70 bytes
[1228153] 10:45:19 [RAW_OUT] 164 bytes
[1228153] 10:45:19 [OUT] {"id":1,...}     # Initialize response finally assembled
# tools/list response NEVER appears in log!
```

The output is coming in **fragments** mixed with logger output. The initialize response eventually gets assembled, but `tools/list` response never appears.

---

## What We Tried (Didn't Fix It)

### 1. Python Wrapper Buffering Fixes
- `bufsize=0` for unbuffered subprocess
- `select()` for non-blocking I/O
- `input_buffer` to handle fragmented input
- `output_buffer` to assemble fragmented output
- `flush=True` on all prints

### 2. Elixir Unbuffered I/O
- `:io.setopts(:standard_io, [:binary])` 
- `:io.put_chars()` instead of `IO.puts()`
- Silence logger with `:logger.set_primary_config(:level, :none)`

### 3. Logger Silencing
- Moved logger silencing to start of `run()` function
- But catalog loading still logs BEFORE `McpCli.run()` is called!

---

## Hypotheses to Test Next

### Hypothesis A: Logger Output Corrupts JSON Stream
The Elixir application starts and logs before `McpCli.run()` silences it. These log lines on stdout corrupt the JSON-RPC stream.

**Test:** Modify `config/config.exs` to set `config :logger, level: :none` at compile time.

### Hypothesis B: Response Stuck in Docker Exec Pipe
The `docker exec -i` pipe has its own buffering that isn't flushed.

**Test:** Try `docker exec -i -t` (pseudo-TTY) or use `stdbuf -oL`.

### Hypothesis C: Large Response Fragmentation
The `tools/list` response is ~7KB. It may be split across multiple reads and the reassembly fails.

**Test:** Add more logging to track exactly how many bytes are received for tools/list response.

### Hypothesis D: Race Condition in Request Processing
When multiple requests arrive before responses are sent, Elixir may be processing them out of order or dropping some.

**Test:** Add request queuing and ensure responses are sent in order.

### Hypothesis E: SSH Connection Issue
The SSH tunnel may have different buffering behavior for rapid bidirectional communication.

**Test:** Try TCP socket connection instead of stdio over SSH.

---

## Files & Locations

| File | Location | Purpose |
|------|----------|---------|
| `mcp.json` | `/root/.vscode/mcp.json` | VS Code MCP config |
| `mimo-mcp-stdio.py` | Repo root & `/usr/local/bin/` on VPS | Python wrapper |
| `mcp_cli.ex` | `lib/mimo/mcp_cli.ex` | Elixir stdio handler |
| `debug_stream.py` | Repo root | Test script (works!) |
| Wrapper log | `/tmp/mcp-wrapper.log` on VPS | Debug output |

---

## Quick Commands

```bash
# Check latest wrapper log
ssh root@172.18.0.1 "tail -50 /tmp/mcp-wrapper.log"

# Test terminal (should work)
echo '{"jsonrpc":"2.0","id":1,"method":"initialize"}' | \
  ssh -T root@172.18.0.1 /usr/local/bin/mimo-mcp-stdio

# Test with debug_stream.py (should work)  
cd /root/mimo/mimo_mcp && python3 debug_stream.py

# Git deploy workflow
cd /root/mimo/mimo_mcp
git add -A && git commit -m "message" && git push origin main
ssh root@172.18.0.1 "cd /root/mrc-server/mimo-mcp && git pull"
ssh root@172.18.0.1 "cp /root/mrc-server/mimo-mcp/mimo-mcp-stdio.py /usr/local/bin/mimo-mcp-stdio"
# For Elixir changes:
ssh root@172.18.0.1 "docker cp /root/mrc-server/mimo-mcp/lib/mimo/mcp_cli.ex mimo-mcp:/app/lib/mimo/ && docker exec mimo-mcp mix compile --force"
```

---

## VS Code MCP Config

`/root/.vscode/mcp.json`:
```json
{
  "servers": {
    "mimo": {
      "type": "stdio",
      "command": "ssh",
      "args": [
        "-T",
        "-o", "LogLevel=ERROR",
        "-o", "BatchMode=yes", 
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "root@172.18.0.1",
        "/usr/local/bin/mimo-mcp-stdio"
      ]
    }
  }
}
```

---

## Architecture

```
VS Code (local machine or tunnel container)
    ↓ SSH (-T for no PTY)
VPS Host (172.18.0.1)
    ↓ /usr/local/bin/mimo-mcp-stdio (Python wrapper)
    ↓ subprocess.Popen with bufsize=0
Docker: mimo-mcp container
    ↓ mix run --no-halt -e "Mimo.McpCli.run()"
Elixir BEAM VM
    ↓ IO.read(:stdio, :line) loop
    ↓ Process JSON-RPC, return response
    ↓ :io.put_chars(:standard_io, response)
```

---

## Next Steps for Incoming Agent

1. **Don't repeat the buffering fixes** - we've tried them extensively
2. **Focus on WHY `tools/list` response never appears** in wrapper log
3. **Check if response is generated** - add logging inside Elixir `handle_request`
4. **Consider alternative transports** - TCP socket, named pipe, or HTTP instead of stdio
5. **Check if VS Code has special requirements** - maybe needs Content-Length header like LSP?

---

## GitHub Repo
https://github.com/pudingtabi/mimo-mcp
