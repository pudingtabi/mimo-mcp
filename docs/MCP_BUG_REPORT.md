# MIMO-MCP Bug Report
Generated: 2025-11-28T01:40:00Z
Server Version: 2.3.2
Test Environment: Linux (Docker container)

## Executive Summary
- Total Tests Run: 23
- Passed: 17
- Failed: 4
- Errors: 2
- Critical Issues: 2

---

## Critical Bugs (Production Blockers)

### BUG-001: ToolRegistry GenServer Timeout on External Skill Calls
- **Severity:** Critical
- **Component:** `Mimo.ToolRegistry`, `Mimo.Skills.Client`
- **Endpoint/Function:** `POST /v1/mimo/tool` with external skill tools (fetch, desktop_commander, puppeteer, etc.)
- **Steps to Reproduce:**
  1. Start the server with `mix phx.server`
  2. Call any external skill tool via the tool endpoint:
     ```bash
     curl -s -X POST http://localhost:4000/v1/mimo/tool \
       -H "Content-Type: application/json" \
       -d '{"tool": "fetch_fetch_json", "arguments": {"url": "https://httpbin.org/json"}}'
     ```
- **Expected:** Tool executes and returns JSON result
- **Actual:** 
  - GenServer.call timeout after 5000ms
  - Server returns HTML error page instead of JSON error
  - Stack trace: `(exit) exited in: GenServer.call(Mimo.ToolRegistry, {:lookup, "fetch_fetch_json"}, 5000)`
- **Error Message:**
  ```
  ** (EXIT) time out
  (elixir 1.15.7) lib/gen_server.ex:1074: GenServer.call/3
  (mimo_mcp 2.3.2) lib/mimo/ports/tool_interface.ex:121: Mimo.ToolInterface.execute/2
  ```
- **Impact:** ALL external skill tools (37 out of 42 tools) are non-functional
- **Suggested Fix:** 
  - Investigate ToolRegistry GenServer blocking
  - Add proper timeout handling with JSON error response
  - Consider async skill initialization

### BUG-002: Skills.Client Spawn Failure - Case Clause Error
- **Severity:** Critical
- **Component:** `Mimo.Skills.Client`
- **Endpoint/Function:** External skill tool execution
- **Steps to Reproduce:**
  1. Start server
  2. Call desktop_commander_read_file:
     ```bash
     curl -s -X POST http://localhost:4000/v1/mimo/tool \
       -H "Content-Type: application/json" \
       -d '{"tool": "desktop_commander_read_file", "arguments": {"path": "README.md"}}'
     ```
- **Expected:** File content returned
- **Actual:** Spawn failure with case_clause error
- **Error Message:**
  ```elixir
  {:spawn_failed, {{:case_clause, {:ok, %{"jsonrpc" => "2.0", 
    "method" => "notifications/message", 
    "params" => %{"data" => "No feature flag cache found", 
                  "level" => "debug", 
                  "logger" => "desktop-commander"}}}}
  ```
- **Root Cause:** The Skills.Client is receiving a notifications/message response during tool discovery but the code expects a different response structure.
- **Location:** [lib/mimo/skills/client.ex](lib/mimo/skills/client.ex#L138) - `discover_tools/1` function
- **Suggested Fix:** Handle notification messages during skill initialization, not just tool responses

---

## High Priority Bugs

### BUG-003: Authentication Fails When Bearer Token Provided in Dev Mode
- **Severity:** High
- **Component:** `MimoWeb.Plugs.Authentication`
- **Endpoint/Function:** All authenticated endpoints
- **Steps to Reproduce:**
  1. Start server in dev mode (no MIMO_API_KEY set)
  2. Call endpoint with Bearer token:
     ```bash
     curl -s -X POST http://localhost:4000/v1/mimo/ask \
       -H "Authorization: Bearer test-key" \
       -H "Content-Type: application/json" \
       -d '{"query": "test"}'
     ```
- **Expected:** In dev mode without API key configured, requests should work
- **Actual:** Returns 401 "Invalid API key" because it compares "test-key" against `nil`
- **Error Message:**
  ```json
  {"error":"Authentication required","reason":"Invalid API key","security_event_id":"..."}
  ```
- **Impact:** Confusing behavior - omitting Bearer token works, providing one fails
- **Suggested Fix:** 
  - If no API key is configured, don't attempt to validate provided tokens
  - Or return a clear error message explaining auth is not configured

### BUG-004: HTML Error Responses Instead of JSON for Server Errors
- **Severity:** High
- **Component:** `MimoWeb.ErrorJSON`, Phoenix Error Handling
- **Endpoint/Function:** All endpoints on unhandled exceptions
- **Steps to Reproduce:**
  1. Trigger any server crash (e.g., ToolRegistry timeout from BUG-001)
- **Expected:** JSON error response like `{"error": "Internal server error", "details": "..."}`
- **Actual:** Full HTML error page with Phoenix debug information
- **Impact:** 
  - API consumers cannot parse error responses
  - Sensitive stack traces exposed
  - Non-compliant with REST API expectations
- **Suggested Fix:** Ensure error handler returns JSON for all API routes

---

## Medium Priority Bugs

### BUG-005: Type Coercion for Tool Arguments
- **Severity:** Medium
- **Component:** `Mimo.ToolInterface`
- **Endpoint/Function:** `POST /v1/mimo/tool`
- **Steps to Reproduce:**
  ```bash
  curl -s -X POST http://localhost:4000/v1/mimo/tool \
    -H "Content-Type: application/json" \
    -d '{"tool": "search_vibes", "arguments": {"query": 123, "limit": "not_a_number"}}'
  ```
- **Expected:** Validation error for wrong types
- **Actual:** Returns 200 with empty results (silently converts 123 to string "123")
- **Impact:** Silent data coercion may produce unexpected results
- **Suggested Fix:** Add strict type validation or return clear coercion warnings

### BUG-006: Missing think and plan Tools
- **Severity:** Medium
- **Component:** Tool Registration
- **Endpoint/Function:** `GET /v1/mimo/tools`
- **Steps to Reproduce:**
  ```bash
  curl -s http://localhost:4000/v1/mimo/tools | grep -E "think|plan"
  ```
- **Expected:** Tools `think` and `plan` listed (per testing prompt documentation)
- **Actual:** Not found in tools list (42 tools, but these are missing)
- **Impact:** Documented tools unavailable
- **Suggested Fix:** Register think and plan tools or update documentation

### BUG-007: Concurrent Request Partial Failures
- **Severity:** Medium  
- **Component:** HTTP Server / Cowboy
- **Endpoint/Function:** `GET /health`
- **Steps to Reproduce:**
  ```bash
  for i in 1 2 3 4 5; do curl -s http://localhost:4000/health & done
  ```
- **Expected:** 5/5 requests succeed
- **Actual:** 4/5 requests succeed (80% success rate on simple concurrent test)
- **Impact:** Under load, some requests may fail
- **Suggested Fix:** Investigate connection handling and increase acceptor pool

---

## Low Priority / Enhancements

### ENH-001: Metrics Endpoint Not Available on Main Port
- **Severity:** Low/Enhancement
- **Component:** Telemetry/Prometheus
- **Current Behavior:** `/metrics` on port 4000 returns 404; metrics available on port 9568
- **Suggested:** Consider exposing metrics on main port or documenting the separate metrics port

### ENH-002: Metric Type "summary" Unsupported Warning
- **Severity:** Low
- **Component:** `Mimo.Telemetry`
- **Current Behavior:** Logs warnings at startup:
  ```
  Metric type summary is unsupported. Dropping measure. metric_name:=[:mimo, :brain, :classify, :confidence]
  ```
- **Suggested:** Use histogram type instead of summary, or suppress warning

### ENH-003: Locale Warning for Non-UTF8 Environment
- **Severity:** Low
- **Component:** BEAM VM
- **Current Behavior:** Warning on startup about latin1 encoding
- **Suggested:** Document ELIXIR_ERL_OPTIONS="+fnu" requirement

---

## Test Results by Category

### HTTP API Tests
| Test | Status | Notes |
|------|--------|-------|
| Health endpoint | ✅ PASS | Returns healthy status with system metrics |
| List tools | ✅ PASS | Returns 42 tools |
| Ask endpoint | ✅ PASS | Returns query results with router decision |
| Tool execution (native) | ✅ PASS | search_vibes, store_fact, ask_mimo work |
| Tool execution (external) | ❌ FAIL | GenServer timeout on all external skills |
| OpenAI chat completions | ✅ PASS | Returns tool_calls format |
| List models | ✅ PASS | Returns mimo-polymorphic-1 |

### Error Handling Tests
| Test | Status | Notes |
|------|--------|-------|
| Missing required field | ✅ PASS | Returns 400 with clear message |
| Invalid tool name | ✅ PASS | Returns error with available tools list |
| Invalid argument types | ⚠️ WARN | Silently coerces types |
| 404 handling | ✅ PASS | Returns JSON with available endpoints |
| Auth with Bearer (no key) | ❌ FAIL | Incorrectly rejects valid dev requests |

### Tool Tests
| Tool | Status | Notes |
|------|--------|-------|
| search_vibes | ✅ PASS | Vector similarity search works |
| store_fact | ✅ PASS | Stores to episodic memory |
| ask_mimo | ✅ PASS | Queries memory successfully |
| mimo_store_memory | ✅ PASS | Alternative storage tool works |
| mimo_reload_skills | ✅ PASS | Skills reload successfully |
| desktop_commander_* | ❌ FAIL | Spawn failure (case_clause) |
| fetch_* | ❌ FAIL | GenServer timeout |
| puppeteer_* | ❌ FAIL | GenServer timeout |
| exa_search_* | ❌ FAIL | GenServer timeout |
| sequential_thinking | ❌ FAIL | GenServer timeout |

### Security Tests
| Test | Status | Notes |
|------|--------|-------|
| Path traversal blocked | ⚠️ N/A | Tool fails before path check (spawn error) |
| Dangerous commands blocked | ⚠️ N/A | Tool fails before command check |
| SSRF protection | ⚠️ N/A | Cannot test due to tool failures |
| Auth timing attacks | ✅ PASS | Uses constant-time comparison |

### Stability Tests
| Test | Status | Notes |
|------|--------|-------|
| Concurrent requests (5) | ⚠️ WARN | 4/5 succeed (80%) |
| Rapid sequential (20) | ✅ PASS | 20/20 succeed |
| Memory stability | ✅ PASS | ~53MB stable |

---

## Performance Observations
- Average health latency: <10ms
- Average ask_mimo latency: ~100ms
- Average store_fact latency: ~160ms (with embedding)
- Memory usage: ~53MB stable
- Tool count: 42 (but 37 external tools non-functional)

---

## Recommendations

1. **CRITICAL:** Fix ToolRegistry/Skills.Client initialization to handle MCP notification messages properly
2. **CRITICAL:** Add timeout handling with proper JSON error responses
3. **HIGH:** Improve authentication logic for dev mode clarity
4. **HIGH:** Ensure all error responses are JSON, not HTML
5. **MEDIUM:** Add strict type validation for tool arguments
6. **MEDIUM:** Document or implement think/plan tools
7. **LOW:** Consider connection pool tuning for concurrent load

---

## Appendix: Working Tools (5/42)

The following native tools work correctly:
1. `ask_mimo` - Query the memory system
2. `search_vibes` - Vector similarity search
3. `store_fact` - Store facts with embeddings
4. `mimo_store_memory` - Alternative memory storage
5. `mimo_reload_skills` - Hot-reload skills

All other tools (37) fail due to external skill routing issues.
