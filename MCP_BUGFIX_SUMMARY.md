# MCP Integration Fix Summary

## Problem
The stdio MCP server was not routing external skills through ToolRegistry, causing all external tools (37 of 42 total) to fail when called via stdio protocol.

## Root Cause
The `Mimo.McpServer.Stdio` module directly called `Mimo.Tools.dispatch/2` which only knows about 5 internal tools, bypassing the entire external skill infrastructure.

## Solution
Modified stdio server to route through ToolRegistry consistently with HTTP adapter:

### Changes Made

1. **Fixed stdio tool routing** (`lib/mimo/mcp_server/stdio.ex`):
   - Now checks ToolRegistry first
   - Handles external skills via `call_tool_sync` for lazy-spawning
   - Handles internal tools via `Tools.dispatch`

2. **Fixed ToolRegistry blocking** (`lib/mimo/tool_registry.ex`):
   - Changed `lookup_catalog_and_spawn/2` to return `{:skill_lazy, ...}` marker
   - Prevents GenServer from blocking on subprocess spawning
   - Clients now handle lazy-spawning asynchronously

3. **Added missing helper** (`lib/mimo/skills/catalog.ex`):
   - Added `get_skill_config/1` to retrieve config by skill name
   - Needed for lazy-spawning from stdio server

## Architecture Flow (Fixed)

```
AI → stdio MCP → check ToolRegistry → route to:
  ├── {:skill_lazy, name, config} → call_tool_sync (spawns + calls)
  ├── {:skill, name, pid} → call_tool (already running)
  └── {:internal} → Tools.dispatch
```

## Test Results
- All integration tests now pass
- External skills (fetch_*, puppeteer_*, etc.) accessible via stdio
- No ToolRegistry timeouts during skill discovery
- Lazy-spawning works correctly

## Available Tools via Stdio
- Internal: 5 tools (ask_mimo, search_vibes, store_fact, mimo_store_memory, mimo_reload_skills)
- External: 37 tools (fetch_*, puppeteer_*, exa_search_*, desktop_commander_*, sequential_thinking_*)
- **Total: 42 tools (was 5)**

## Backwards Compatibility
- HTTP adapter continues working unchanged
- ToolRegistry API compatible with existing code
- Existing tests continue passing (370/370)