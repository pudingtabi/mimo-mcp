# Mimo-MCP Handoff Document

## Current Status: Skills Discovery Issue

### The Problem
VS Code MCP only discovers **3 tools** (mimo brain tools) instead of the full **46 tools**.

**Root cause**: Skills are loaded asynchronously AFTER the initial `tools/list` response. By the time skills finish loading (5-15 seconds), VS Code has already cached the tool list from the first response.

### What Works
- ✅ Mimo container running on VPS (217.216.73.22)
- ✅ SSH tunnel from VS Code container to host
- ✅ JSON filtering wrapper (`/usr/local/bin/mimo-mcp-stdio`)
- ✅ All 5 skills load successfully (see logs)
- ✅ 46 tools available after skills load

### What's Broken
- ❌ VS Code only sees 3 tools (initial response before skills load)
- ❌ Skills load async, not blocking initialize response

### Architecture

```
VS Code Container (172.18.0.3)
    ↓ SSH
VPS Host (172.18.0.1)
    ↓ docker exec
mimo-mcp container
    ↓ spawns
[filesystem, exa_search, fetch, playwright, sequential_thinking]
```

### Files

| File | Location | Purpose |
|------|----------|---------|
| `mcp.json` | `/root/.vscode/mcp.json` | Global VS Code MCP config |
| `skills.json` | `/root/mimo/mimo_mcp/priv/skills.json` | Skill definitions |
| `mcp_server.ex` | `lib/mimo/mcp_server.ex` | MCP JSON-RPC handler |
| `application.ex` | `lib/mimo/application.ex` | App startup, skill bootstrap |
| `registry.ex` | `lib/mimo/registry.ex` | Tool registry (ETS) |
| `mimo-mcp-stdio` | `/usr/local/bin/mimo-mcp-stdio` (on host) | Wrapper script |

### The Fix Needed

**Option A: Block initialize until skills load**
```elixir
# In application.ex - wait for skills before returning from start/2
def start(_type, _args) do
  # ... start supervisors ...
  Mimo.bootstrap_skills()
  wait_for_skills_ready()  # NEW: block until all skills registered
  {:ok, sup}
end
```

**Option B: Make skills native (user's preference)**
Instead of spawning external MCP servers, implement tools directly in Elixir:

```elixir
# lib/mimo/tools/filesystem.ex
defmodule Mimo.Tools.Filesystem do
  def read_file(%{"path" => path}) do
    case File.read(path) do
      {:ok, content} -> {:ok, %{content: content}}
      {:error, reason} -> {:error, reason}
    end
  end
  
  def list_directory(%{"path" => path}) do
    # ...
  end
end
```

Register in `registry.ex`:
```elixir
def list_all_tools do
  [
    # Brain tools
    %{"name" => "ask_mimo", ...},
    # Native tools
    %{"name" => "read_file", "description" => "Read file contents", ...},
    %{"name" => "list_directory", ...},
    %{"name" => "web_search", ...},  # wrap exa API
    %{"name" => "fetch_url", ...},   # native HTTP
    %{"name" => "browser_*", ...},   # wrap playwright
  ]
end
```

### Quick Fix (Test)

SSH to host and test if skills are fully loaded:
```bash
# Wait 20s for skills, then query tools
(sleep 20; echo '{"jsonrpc":"2.0","method":"tools/list","id":1}') | \
  ssh root@172.18.0.1 /usr/local/bin/mimo-mcp-stdio 2>&1 | grep -o '"name":"[^"]*"' | wc -l
# Should show 46
```

### Next Steps

1. **Immediate**: Fix timing - block `tools/list` response until skills loaded
2. **Better**: Implement native tools in Elixir (no external processes)
3. **Test**: Reload VS Code after fix, verify 46 tools discovered

### GitHub Repo
https://github.com/pudingtabi/mimo-mcp

### Container Commands
```bash
# SSH to host
ssh root@172.18.0.1

# Check logs
docker logs mimo-mcp 2>&1 | tail -50

# Restart
docker restart mimo-mcp

# Update skills.json
docker cp /root/mrc-server/mimo-mcp/priv/skills.json mimo-mcp:/app/priv/skills.json
```
