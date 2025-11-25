# Mimo-MCP Handoff Document

## Current Status: ✅ RESOLVED

### The Problem (FIXED)
~~VS Code MCP only discovers **3 tools** (mimo brain tools) instead of the full **46 tools**.~~

**Root cause was**: Skills were loaded asynchronously AFTER the initial `tools/list` response. By the time skills finish loading (5-15 seconds), VS Code has already cached the tool list from the first response.

### Solution Implemented

1. **Pre-generated Skills Manifest** (`priv/skills_manifest.json`)
   - Tools are defined statically in a manifest file
   - Catalog loads tools instantly on startup (no async wait)

2. **Catalog-based Lazy Loading** (`lib/mimo/skills/catalog.ex`)
   - Tools advertised immediately from manifest
   - Actual MCP skill processes spawn on-demand when tool is called

3. **McpCli for stdio mode** (`lib/mimo/mcp_cli.ex`)
   - One-shot CLI entry point for VS Code communication
   - Processes stdin, outputs JSON, exits cleanly on EOF

4. **Wait for Catalog Ready** (`lib/mimo/application.ex`)
   - Blocks MCP server startup until catalog has loaded tools
   - Ensures `tools/list` always returns full tool set

### What Works Now
- ✅ Mimo container running on VPS (217.216.73.22)
- ✅ SSH tunnel from VS Code container to host
- ✅ JSON filtering wrapper (`/usr/local/bin/mimo-mcp-stdio`)
- ✅ All 5 skills cataloged (43 tools from manifest)
- ✅ **46 tools available immediately** on `tools/list`
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

```bash
#!/bin/bash
# /usr/local/bin/mimo-mcp-stdio
# MCP stdio wrapper - uses McpCli for one-shot requests
# Filter: only output lines starting with { (JSON)
exec docker exec -i mimo-mcp mix run -e "Mimo.McpCli.run()" 2>/dev/null | grep "^{"
```

### Testing

```bash
# Test tools/list response (should return 46 tools)
(echo '{"jsonrpc":"2.0","method":"initialize","params":{},"id":0}'; \
 echo '{"jsonrpc":"2.0","method":"tools/list","id":1}') | \
  ssh root@172.18.0.1 /usr/local/bin/mimo-mcp-stdio | \
  grep '^{' | tail -1 | jq '.result.tools | length'
# Output: 46
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
