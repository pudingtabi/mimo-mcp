# MCP VS Code Integration Issue - November 28, 2025

## Status: ✅ RESOLVED

The MCP VS Code integration issue has been fixed. All 50 tools are now accessible and working correctly in VS Code Copilot Chat.

## Summary

The mimo-mcp server was correctly returning 50 valid MCP tools via stdio, but VS Code failed to validate them with the error:
```
Failed to validate tools for server mimo: mcp_mimo_fetch
```

## Root Causes Found

### 1. Empty Schema Property
`desktop_commander_set_config_value.value` had an empty schema `{}` which is invalid JSON Schema.

**Fix:** Added description to the schema:
```json
"value": {"description": "The configuration value to set"}
```

### 2. Stale Tool Classification  
`lib/mimo/tool_registry.ex` still classified `"fetch"` as a mimo_core tool after it was renamed to `"http_request"`.

**Fix:** Updated classification:
```elixir
defp classify_tool("http_request"), do: {:mimo_core, :http_request}
```

### 3. Process Hang on EOF
The Elixir VM didn't exit cleanly when stdin closed because of `--no-halt` flag, causing VS Code tool calls to timeout.

**Fix:** Added explicit `System.halt(0)` in `lib/mimo/mcp_server/stdio.ex`:
```elixir
defp loop do
  case IO.read(:stdio, :line) do
    :eof ->
      System.halt(0)  # Cleanly exit the VM
    ...
  end
end
```

## Files Modified

| File | Change |
|------|--------|
| `priv/skills_manifest.json` | Fixed empty schema for `set_config_value.value` |
| `lib/mimo/tool_registry.ex` | Changed `classify_tool("fetch")` to `classify_tool("http_request")` |
| `lib/mimo/mcp_server/stdio.ex` | Added `System.halt(0)` on EOF for clean exit |
| `bin/mimo-node-wrapper.js` | Added stdin EOF handlers |

## Verification

```bash
# Test server responds correctly
cd /workspace/mrc-server/mimo-mcp
printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}}}\n{"jsonrpc":"2.0","id":2,"method":"tools/list"}\n' | timeout 15 node bin/mimo-node-wrapper.js 2>/dev/null

# Verify all schemas are valid
# Output: "✅ All schemas valid!"

# Test tool call
printf '...\n{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ask_mimo","arguments":{"query":"test"}}}\n' | timeout 15 node bin/mimo-node-wrapper.js

# Verify clean exit (exit code 0)
```

## Environment

- **Elixir:** 1.19.2-otp-26
- **Erlang:** 26.0
- **VS Code:** Insiders (Remote SSH)
