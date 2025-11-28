# MIMO-MCP Comprehensive Testing Prompt

Execute real-world tests against the MCP server to identify bugs, errors, and edge cases. Generate a detailed bug report.

## PREREQUISITES

### 1. Start the Server
```bash
cd /workspace/mrc-server/mimo-mcp
# Set environment (optional for dev)
export MIMO_HTTP_PORT=4000
export OLLAMA_URL=http://localhost:11434

# Start server in background
mix phx.server &
# Or: iex -S mix phx.server

# Wait for startup
sleep 5
```

### 2. Verify Health
```bash
curl -s http://localhost:4000/health | jq
# Expected: {"status": "ok", ...}
```

### 3. Check Dependencies
```bash
# Ollama running?
curl -s http://localhost:11434/api/tags | jq '.models[].name'

# Database exists?
ls -la priv/mimo_mcp.db
```

---

## PHASE 1: HTTP API TESTS

### Test 1.1: Health Endpoint
```bash
curl -s http://localhost:4000/health | jq
```
**Expected:** `{"status": "ok", ...}`
**Record:** Response, latency, any errors

### Test 1.2: List Tools (GET /v1/mimo/tools)
```bash
curl -s http://localhost:4000/v1/mimo/tools \
  -H "Authorization: Bearer test-key" | jq '.tools | length'
```
**Expected:** Array of tools with name, description, inputSchema
**Record:** Tool count, any missing schemas

### Test 1.3: Ask Endpoint (POST /v1/mimo/ask)
```bash
# Basic query
curl -s http://localhost:4000/v1/mimo/ask \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test-key" \
  -d '{"query": "What is the capital of France?"}' | jq

# Query with context
curl -s http://localhost:4000/v1/mimo/ask \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test-key" \
  -d '{"query": "Remember this fact", "context_id": "test-ctx-1"}' | jq
```
**Expected:** `{query_id, router_decision, results, synthesis, latency_ms}`
**Record:** Response structure, router decision accuracy, latency

### Test 1.4: Tool Execution (POST /v1/mimo/tool)
```bash
# search_vibes
curl -s http://localhost:4000/v1/mimo/tool \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test-key" \
  -d '{"tool": "search_vibes", "arguments": {"query": "test", "limit": 5}}' | jq

# store_fact
curl -s http://localhost:4000/v1/mimo/tool \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test-key" \
  -d '{"tool": "store_fact", "arguments": {"content": "Test fact for verification", "category": "fact", "importance": 0.8}}' | jq

# ask_mimo
curl -s http://localhost:4000/v1/mimo/tool \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test-key" \
  -d '{"tool": "ask_mimo", "arguments": {"query": "What did I just store?"}}' | jq

# think
curl -s http://localhost:4000/v1/mimo/tool \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test-key" \
  -d '{"tool": "think", "arguments": {"thought": "Testing the think tool"}}' | jq

# plan
curl -s http://localhost:4000/v1/mimo/tool \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test-key" \
  -d '{"tool": "plan", "arguments": {"steps": ["Step 1", "Step 2", "Step 3"]}}' | jq
```
**Expected:** `{tool_call_id, status: "success", data, latency_ms}`
**Record:** Each tool's response, any failures

### Test 1.5: OpenAI-Compatible Endpoint
```bash
# Chat completion
curl -s http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test-key" \
  -d '{
    "model": "mimo-polymorphic-1",
    "messages": [{"role": "user", "content": "Hello, test message"}]
  }' | jq

# With tool_choice
curl -s http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test-key" \
  -d '{
    "model": "mimo-polymorphic-1",
    "messages": [{"role": "user", "content": "Search for recent news about AI"}],
    "tools": [{"type": "function", "function": {"name": "search_vibes", "parameters": {}}}],
    "tool_choice": "auto"
  }' | jq

# List models
curl -s http://localhost:4000/v1/models \
  -H "Authorization: Bearer test-key" | jq
```
**Expected:** OpenAI-compatible response format
**Record:** Format compliance, tool_calls structure

---

## PHASE 2: ERROR HANDLING TESTS

### Test 2.1: Authentication Errors
```bash
# No auth header
curl -s http://localhost:4000/v1/mimo/ask \
  -H "Content-Type: application/json" \
  -d '{"query": "test"}' | jq

# Invalid token
curl -s http://localhost:4000/v1/mimo/ask \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer invalid-token" \
  -d '{"query": "test"}' | jq
```
**Expected:** 401 Unauthorized with error message
**Record:** Error format, timing (constant-time for security)

### Test 2.2: Validation Errors
```bash
# Missing required field
curl -s http://localhost:4000/v1/mimo/ask \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test-key" \
  -d '{}' | jq

# Invalid tool name
curl -s http://localhost:4000/v1/mimo/tool \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test-key" \
  -d '{"tool": "nonexistent_tool", "arguments": {}}' | jq

# Invalid argument types
curl -s http://localhost:4000/v1/mimo/tool \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test-key" \
  -d '{"tool": "search_vibes", "arguments": {"query": 123, "limit": "not_a_number"}}' | jq
```
**Expected:** 400 Bad Request with validation errors
**Record:** Error messages, field-level validation

### Test 2.3: Timeout Handling
```bash
# Short timeout
curl -s http://localhost:4000/v1/mimo/ask \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test-key" \
  -d '{"query": "complex query requiring LLM", "timeout_ms": 1}' | jq
```
**Expected:** 504 Gateway Timeout or graceful degradation
**Record:** Timeout behavior, fallback response

### Test 2.4: Not Found
```bash
curl -s http://localhost:4000/nonexistent/path | jq
```
**Expected:** 404 Not Found
**Record:** Error format

---

## PHASE 3: TOOL-SPECIFIC TESTS

### Test 3.1: File Tool (Sandboxed)
```bash
# Read file
curl -s http://localhost:4000/v1/mimo/tool \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test-key" \
  -d '{"tool": "file", "arguments": {"operation": "read", "path": "README.md"}}' | jq

# Write file (should be sandboxed)
curl -s http://localhost:4000/v1/mimo/tool \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test-key" \
  -d '{"tool": "file", "arguments": {"operation": "write", "path": "/tmp/test.txt", "content": "test"}}' | jq

# Path traversal attempt (should fail)
curl -s http://localhost:4000/v1/mimo/tool \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test-key" \
  -d '{"tool": "file", "arguments": {"operation": "read", "path": "../../../etc/passwd"}}' | jq
```
**Expected:** Sandboxed operations only, path traversal blocked
**Record:** Security enforcement

### Test 3.2: Terminal Tool (Sandboxed)
```bash
# Safe command
curl -s http://localhost:4000/v1/mimo/tool \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test-key" \
  -d '{"tool": "terminal", "arguments": {"command": "echo hello"}}' | jq

# Dangerous command (should be blocked)
curl -s http://localhost:4000/v1/mimo/tool \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test-key" \
  -d '{"tool": "terminal", "arguments": {"command": "rm -rf /"}}' | jq

# Timeout test
curl -s http://localhost:4000/v1/mimo/tool \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test-key" \
  -d '{"tool": "terminal", "arguments": {"command": "sleep 60", "timeout": 1000}}' | jq
```
**Expected:** Dangerous commands blocked, timeouts enforced
**Record:** Security enforcement, timeout behavior

### Test 3.3: Fetch Tool
```bash
# HTTP fetch
curl -s http://localhost:4000/v1/mimo/tool \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test-key" \
  -d '{"tool": "fetch", "arguments": {"url": "https://httpbin.org/json"}}' | jq

# Invalid URL
curl -s http://localhost:4000/v1/mimo/tool \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test-key" \
  -d '{"tool": "fetch", "arguments": {"url": "not-a-url"}}' | jq

# Localhost/internal (should be blocked in prod)
curl -s http://localhost:4000/v1/mimo/tool \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test-key" \
  -d '{"tool": "fetch", "arguments": {"url": "http://localhost:11434"}}' | jq
```
**Expected:** Valid fetches work, SSRF protection in place
**Record:** Response handling, security

### Test 3.4: Consult Graph Tool
```bash
curl -s http://localhost:4000/v1/mimo/tool \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test-key" \
  -d '{"tool": "consult_graph", "arguments": {"query": "find all relationships"}}' | jq
```
**Expected:** Query result or "not_implemented" status
**Record:** Semantic store status

### Test 3.5: Teach Mimo Tool
```bash
curl -s http://localhost:4000/v1/mimo/tool \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test-key" \
  -d '{"tool": "teach_mimo", "arguments": {"subject": "Paris", "predicate": "is_capital_of", "object": "France"}}' | jq
```
**Expected:** Knowledge stored or "not_implemented"
**Record:** Semantic store status

---

## PHASE 4: CONCURRENT & LOAD TESTS

### Test 4.1: Concurrent Requests
```bash
# 10 concurrent requests
for i in {1..10}; do
  curl -s http://localhost:4000/v1/mimo/ask \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer test-key" \
    -d "{\"query\": \"Concurrent test $i\"}" &
done
wait
```
**Record:** All responses received, no crashes

### Test 4.2: Rapid Sequential Requests
```bash
# 50 rapid requests
for i in {1..50}; do
  curl -s http://localhost:4000/health > /dev/null
  echo -n "."
done
echo " Done"
```
**Record:** Rate limiting behavior, stability

---

## PHASE 5: MCP STDIO PROTOCOL TESTS

### Test 5.1: Direct Protocol Test
```bash
# Create test script
cat << 'EOF' > /tmp/mcp_test.sh
#!/bin/bash
cd /workspace/mrc-server/mimo-mcp

# Test initialize
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' | mix run -e 'Mimo.MCP.Protocol.handle_line(IO.read(:stdio, :line))'

# Test tools/list
echo '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | mix run -e 'Mimo.MCP.Protocol.handle_line(IO.read(:stdio, :line))'
EOF
chmod +x /tmp/mcp_test.sh
```
**Record:** Protocol responses, JSON-RPC compliance

---

## PHASE 6: ELIXIR DIRECT API TESTS

Run in IEx session:
```elixir
# Start IEx
# iex -S mix

# Test ToolRegistry
Mimo.ToolRegistry.list_all_tools() |> Enum.map(& &1.name)

# Test Tool Execution
Mimo.ToolInterface.execute("search_vibes", %{"query" => "test"})
Mimo.ToolInterface.execute("store_fact", %{"content" => "IEx test", "category" => "fact"})
Mimo.ToolInterface.execute("ask_mimo", %{"query" => "What is stored?"})

# Test QueryInterface
Mimo.QueryInterface.ask("Test query", nil, [])

# Test MetaCognitiveRouter
Mimo.MetaCognitiveRouter.route("What is the capital of France?")
Mimo.MetaCognitiveRouter.route("Remember that I like coffee")
Mimo.MetaCognitiveRouter.route("How do I make coffee?")

# Test CircuitBreaker
Mimo.ErrorHandling.CircuitBreaker.get_state(:llm_service)
Mimo.ErrorHandling.CircuitBreaker.get_state(:ollama)

# Test ResourceMonitor
Mimo.ResourceMonitor.stats()

# Test ClassifierCache
Mimo.Cache.Classifier.stats()

# Test GracefulDegradation
Mimo.Fallback.GracefulDegradation.degradation_status()
```
**Record:** All function outputs, any crashes

---

## BUG REPORT TEMPLATE

Create file: `docs/MCP_BUG_REPORT.md`

```markdown
# MIMO-MCP Bug Report
Generated: [DATE]
Server Version: [VERSION]
Test Environment: [ENV DETAILS]

## Executive Summary
- Total Tests Run: X
- Passed: X
- Failed: X
- Errors: X
- Critical Issues: X

## Critical Bugs (Production Blockers)

### BUG-001: [Title]
- **Severity:** Critical/High/Medium/Low
- **Component:** [e.g., ToolController, CircuitBreaker]
- **Endpoint/Function:** [e.g., POST /v1/mimo/tool]
- **Steps to Reproduce:**
  1. ...
  2. ...
- **Expected:** ...
- **Actual:** ...
- **Error Message:** ```...```
- **Suggested Fix:** ...

## High Priority Bugs

### BUG-002: ...

## Medium Priority Bugs

### BUG-003: ...

## Low Priority / Enhancements

### ENH-001: ...

## Test Results by Category

### HTTP API Tests
| Test | Status | Notes |
|------|--------|-------|
| Health endpoint | ✅/❌ | ... |
| List tools | ✅/❌ | ... |
| Ask endpoint | ✅/❌ | ... |
| Tool execution | ✅/❌ | ... |
| OpenAI compat | ✅/❌ | ... |

### Error Handling Tests
| Test | Status | Notes |
|------|--------|-------|
| Auth errors | ✅/❌ | ... |
| Validation | ✅/❌ | ... |
| Timeouts | ✅/❌ | ... |

### Tool Tests
| Tool | Status | Notes |
|------|--------|-------|
| search_vibes | ✅/❌ | ... |
| store_fact | ✅/❌ | ... |
| ask_mimo | ✅/❌ | ... |
| file | ✅/❌ | ... |
| terminal | ✅/❌ | ... |
| fetch | ✅/❌ | ... |
| consult_graph | ✅/❌ | ... |
| teach_mimo | ✅/❌ | ... |

### Security Tests
| Test | Status | Notes |
|------|--------|-------|
| Path traversal blocked | ✅/❌ | ... |
| Dangerous commands blocked | ✅/❌ | ... |
| SSRF protection | ✅/❌ | ... |
| Auth timing attacks | ✅/❌ | ... |

### Stability Tests
| Test | Status | Notes |
|------|--------|-------|
| Concurrent requests | ✅/❌ | ... |
| Rapid requests | ✅/❌ | ... |
| Memory stability | ✅/❌ | ... |

## Performance Observations
- Average latency: X ms
- P95 latency: X ms
- Timeout rate: X%

## Recommendations
1. ...
2. ...
3. ...

## Appendix: Raw Test Output
[Attach full curl outputs if needed]
```

---

## EXECUTION CHECKLIST

- [ ] Server started and healthy
- [ ] Phase 1: HTTP API tests complete
- [ ] Phase 2: Error handling tests complete
- [ ] Phase 3: Tool-specific tests complete
- [ ] Phase 4: Concurrent tests complete
- [ ] Phase 5: MCP stdio tests complete
- [ ] Phase 6: Elixir API tests complete
- [ ] Bug report generated
- [ ] Critical bugs identified
- [ ] Report saved to `docs/MCP_BUG_REPORT.md`
