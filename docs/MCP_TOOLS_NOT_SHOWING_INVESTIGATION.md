# Investigation Task: MCP Server Tools Not Appearing in VS Code Copilot

## Problem Summary

The mimo-mcp server is:
- ✅ Listed in VS Code's "MCP: List Servers" 
- ✅ Shows "Connection state: Running" in output logs
- ✅ Returns 51 tools correctly when tested via command line
- ❌ Tools do NOT appear when typing `#` or `@` in Copilot Chat
- ❌ Tools disappear from "Configure Tools" panel after briefly showing

## Environment Details

- **VS Code**: Remote SSH connection to Linux server
- **Workspace**: `/workspace/mrc-server/mimo-mcp`
- **MCP Config Location**: `/workspace/mrc-server/mimo-mcp/.vscode/mcp.json`
- **Server Type**: Elixir/OTP application using stdio transport
- **Tool Count**: 51 tools returned by `tools/list` method

## Current Configuration

### mcp.json
```json
{
  "servers": {
    "mimo": {
      "type": "stdio",
      "command": "/workspace/mrc-server/mimo-mcp/bin/mimo-mcp-wrapper",
      "args": []
    }
  }
}
```

### Wrapper Script (`bin/mimo-mcp-wrapper`)
```bash
#!/bin/bash
# Source asdf for Elixir
if [ -f "$HOME/.asdf/asdf.sh" ]; then
  . "$HOME/.asdf/asdf.sh"
fi

cd /workspace/mrc-server/mimo-mcp

export MIX_ENV=prod
export ELIXIR_ERL_OPTIONS="+fnu"
export MIMO_HTTP_PORT=$((50000 + ($$  % 10000)))
export MCP_PORT=$((40000 + ($$ % 10000)))
export PROMETHEUS_DISABLED=true
export MIMO_DISABLE_HTTP=true
export LOGGER_LEVEL=error

exec mix run --no-halt --no-compile -e "Mimo.McpServer.Stdio.start()"
```

## Verified Working (Command Line Test)

```bash
printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","clientInfo":{"name":"test"},"capabilities":{}}}\n{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}\n' | /workspace/mrc-server/mimo-mcp/bin/mimo-mcp-wrapper 2>&1
```

**Result**: Returns valid JSON-RPC responses with 51 tools ✅

## Investigation Areas

### 1. VS Code MCP Client Behavior
- How does VS Code's MCP client handle tool discovery?
- Is there a timeout for tool loading?
- Does VS Code cache tools and if so, where?
- What happens when "Update Tools" is clicked in Configure Tools panel?

### 2. Protocol Compliance
- Is the `tools/list` response format 100% compliant with MCP spec?
- Are there any malformed tool schemas that VS Code rejects silently?
- Check if any tool names or descriptions contain problematic characters

### 3. stdio Transport Issues
- Is the server keeping stdout clean (no debug output)?
- Are JSON-RPC messages properly newline-delimited?
- Is stderr properly separated from stdout?
- Check if there's any buffering issue with Elixir's IO

### 4. Server Lifecycle
- Does the server crash after returning tools?
- Is there a heartbeat/ping mechanism VS Code expects?
- Check if server process stays alive after tools/list

### 5. VS Code Extension Logs
- Check GitHub Copilot extension logs
- Check MCP-related output channels
- Look for any error messages about tool parsing

## Specific Tests to Run

### Test 1: Verify Server Stays Alive
```bash
# Start server and keep it running
/workspace/mrc-server/mimo-mcp/bin/mimo-mcp-wrapper &
PID=$!
sleep 30
ps aux | grep $PID
# Server should still be running
```

### Test 2: Check for Malformed Tool Schemas
```bash
# Get tools and validate JSON
printf '...' | /workspace/mrc-server/mimo-mcp/bin/mimo-mcp-wrapper 2>&1 | \
  jq '.result.tools[] | {name, valid: (.inputSchema | type == "object")}'
```

### Test 3: Check stdout Cleanliness
```bash
# Ensure ONLY JSON-RPC goes to stdout
/workspace/mrc-server/mimo-mcp/bin/mimo-mcp-wrapper <<< '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{...}}' 2>/dev/null | head -1 | jq .
# Should be valid JSON, no prefix text
```

### Test 4: Check Protocol Version Compatibility
- MCP spec version: 2024-11-05
- Verify VS Code expects this version
- Check if newer protocol versions exist

### Test 5: Minimal MCP Server Test
Create a minimal Node.js MCP server to verify VS Code's MCP client works:
```javascript
// minimal-mcp.js
const readline = require('readline');
const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: false });

rl.on('line', (line) => {
  const req = JSON.parse(line);
  if (req.method === 'initialize') {
    console.log(JSON.stringify({
      jsonrpc: '2.0',
      id: req.id,
      result: {
        protocolVersion: '2024-11-05',
        serverInfo: { name: 'test', version: '1.0.0' },
        capabilities: { tools: { listChanged: true } }
      }
    }));
  } else if (req.method === 'tools/list') {
    console.log(JSON.stringify({
      jsonrpc: '2.0',
      id: req.id,
      result: {
        tools: [{
          name: 'test_tool',
          description: 'A test tool',
          inputSchema: { type: 'object', properties: {}, required: [] }
        }]
      }
    }));
  }
});
```

## Files to Examine

1. `/workspace/mrc-server/mimo-mcp/lib/mimo/mcp_server/stdio.ex` - Main stdio handler
2. `/workspace/mrc-server/mimo-mcp/lib/mimo/tool_registry.ex` - Tool registration
3. VS Code output: "MCP: mimo" channel
4. VS Code settings: `chat.mcp.*` settings

## Hypotheses to Test

1. **Buffering Issue**: Elixir's IO might be buffering output, causing VS Code to timeout
2. **Tool Schema Issue**: One or more tools have schemas VS Code doesn't like
3. **Process Exit**: Server might be exiting after tools/list due to EOF handling
4. **Protocol Mismatch**: Missing required MCP protocol features
5. **VS Code Bug**: Known issue with MCP tool discovery in remote SSH sessions

## Commands for Agent

```
@agent Please investigate why mimo-mcp tools are not appearing in VS Code Copilot chat even though:
1. The server is listed and shows "Running" status
2. Command-line tests return 51 valid tools
3. The mcp.json configuration is correct

Focus on:
- Checking the Elixir stdio implementation for buffering/flushing issues
- Validating all 51 tool schemas against MCP spec
- Testing if the server stays alive after initialization
- Checking for any VS Code-specific MCP requirements not being met
- Creating a minimal test to isolate the issue

Start by reading:
- /workspace/mrc-server/mimo-mcp/lib/mimo/mcp_server/stdio.ex
- /workspace/mrc-server/mimo-mcp/lib/mimo/tool_registry.ex
```

## Success Criteria

Tools should appear when:
1. Typing `#` in Copilot Chat (e.g., `#ask_mimo`)
2. Opening "Configure Tools" panel and expanding "mimo" section
3. Using `@mimo` mention in chat (if agent mode supported)
