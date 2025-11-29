# Mimo-MCP Gateway: Comprehensive Fault Analysis Report

> **Generated:** November 28, 2025  
> **Codebase Version:** 2.3.2  
> **Analysis Scope:** Full codebase architectural review

---

## Executive Summary

This report documents **35+ issues** identified across the Mimo-MCP Gateway codebase, categorized by severity and type. The analysis covers architectural flaws, logic bugs, security vulnerabilities, configuration issues, test coverage gaps, and concurrency problems.

### Issue Distribution

| Category | Count | Severity |
|----------|-------|----------|
| 🚨 Critical Issues | 5 | P0 - Fix Immediately |
| ⚠️ Architectural Issues | 5 | P1 - High Priority |
| 🔧 Logic Bugs | 5 | P1-P2 |
| 🔒 Security Issues | 3 | P0-P1 |
| 📊 Configuration Issues | 3 | P2 |
| 📝 Code Quality | 3 | P3 |
| 🧪 Test Coverage Gaps | 4 | P2 |
| 🔀 Concurrency Issues | 2 | P1 |
| 🔄 Tool Redundancy | 5 | P1 |

---

## 🚨 Critical Issues (P0)

### CRIT-001: Duplicate Tool Registration

**Files Affected:**
- `lib/mimo/tool_registry.ex` (lines 275-310)
- `lib/mimo/ports/tool_interface.ex` (lines 31-100)

**Description:**  
`store_fact` and `mimo_store_memory` are **functionally identical** - both call `Mimo.Brain.Memory.persist_memory/3`:

```elixir
# store_fact handler in tool_interface.ex
def execute("store_fact", %{"content" => content} = args) do
  category = Map.get(args, "category", "fact")
  importance = Map.get(args, "importance", 0.5)
  case Mimo.Brain.Memory.persist_memory(content, category, importance) do
    {:ok, id} -> {:ok, %{tool_call_id: UUID.uuid4(), status: "success", data: %{stored: true, id: id}}}
    {:error, reason} -> {:error, "Failed to store fact: #{inspect(reason)}"}
  end
end

# mimo_store_memory handler - IDENTICAL LOGIC
def execute("mimo_store_memory", %{"content" => content, "category" => category} = args) do
  importance = Map.get(args, "importance", 0.5)
  case Mimo.Brain.Memory.persist_memory(content, category, importance) do
    {:ok, id} -> {:ok, %{tool_call_id: UUID.uuid4(), status: "success", data: %{stored: true, id: id}}}
    {:error, reason} -> {:error, "Failed to store memory: #{inspect(reason)}"}
  end
end
```

**Impact:**
- Tool catalog bloat (42 tools instead of ~35)
- User/LLM confusion about which tool to use
- Wasted API tokens during tool discovery
- Inconsistent required fields (`store_fact` has optional category, `mimo_store_memory` requires it)

**Fix:** Remove `mimo_store_memory`, keep `store_fact` with improved schema.

---

### CRIT-002: Mimo.Tools Module Not Exposed via MCP

**Files Affected:**
- `lib/mimo/tools.ex`
- `lib/mimo/tool_registry.ex` (line 300)
- `lib/mimo/mcp_server.ex` (line 77)
- `lib/mimo/mcp_server/stdio.ex` (line 57)

**Description:**  
The `Mimo.Tools` module defines 12+ internal tools that are **never advertised** in MCP `tools/list`:

| Hidden Tool | Description |
|-------------|-------------|
| `fetch` | Advanced HTTP client (POST/PUT/DELETE/headers) |
| `web_parse` | HTML to Markdown converter |
| `terminal` | Sandboxed command execution |
| `file` | File operations (read/write/search/replace) |
| `sonar` | UI accessibility scanner |
| `think` | Log reasoning steps |
| `plan` | Log execution plan |
| `consult_graph` | Query semantic knowledge graph |
| `teach_mimo` | Add knowledge to graph |

**Root Cause:**  
`Mimo.ToolRegistry.list_all_tools()` only returns:
1. Internal tools from `internal_tools()` function (5 tools)
2. Catalog tools from `Mimo.Skills.Catalog.list_tools()` (external MCP skills)
3. Active skill tools from running processes

It **never** queries `Mimo.Tools.list_tools()`.

**Impact:**
- 12 capable internal tools invisible to MCP clients
- Tools can only be invoked if caller knows the name
- Feature parity loss between HTTP and MCP interfaces

**Fix:** Add `Mimo.Tools.list_tools()` to `list_all_tools/0` aggregation.

---

### CRIT-003: Pattern Match Mismatch in MCP Server

**File:** `lib/mimo/mcp_server.ex` (line 96)

**Description:**  
The pattern match expects a 3-tuple but `get_tool_owner/1` returns a 4-tuple:

```elixir
# mcp_server.ex - WRONG pattern (3-tuple)
case Mimo.ToolRegistry.get_tool_owner(tool_name) do
  {:ok, {:skill, skill_name, _client_pid}} ->  # ❌ Missing tool_def!
    Mimo.Skills.Client.call_tool(skill_name, tool_name, arguments)

# tool_registry.ex - Actual return (4-tuple)
{:ok, {:skill, skill_name, pid, tool_def}}  # ✅ Has 4 elements
```

**Impact:**
- Pattern match fails silently
- External skill routing completely broken
- Falls through to "tool not found" error

**Fix:** Update pattern to `{:ok, {:skill, skill_name, _pid, _tool_def}}`.

---

### CRIT-004: Mix.env() Used at Runtime

**File:** `lib/mimo_web/plugs/authentication.ex` (line 24)

**Description:**  
```elixir
if Mix.env() == :prod and (is_nil(api_key) or api_key == "") do
  # Block requests
else
  # ...
  if Mix.env() != :prod and (is_nil(api_key) or api_key == "") do
    # Allow unauthenticated in dev
```

`Mix.env()` is a **compile-time** value. In production releases:
- Always returns `:prod` regardless of actual runtime environment
- Cannot distinguish between staging/production
- Security bypass if compiled in `:dev` mode

**Impact:**
- Authentication bypass possible
- Security audit failure
- Inconsistent behavior between mix run and releases

**Fix:** Use `Application.get_env(:mimo_mcp, :environment)` configured at runtime.

---

### CRIT-005: Circuit Breaker Processes Never Started

**Files Affected:**
- `lib/mimo/brain/llm.ex` (lines 15-30)
- `lib/mimo/application.ex` (supervision tree)

**Description:**  
`CircuitBreaker.call/2` is invoked but no circuit breaker processes exist:

```elixir
# llm.ex - Calls circuit breaker
def complete(prompt, opts \\ []) do
  CircuitBreaker.call(:llm_service, fn ->
    do_complete(prompt, opts)
  end)
end

def generate_embedding(text) when is_binary(text) do
  CircuitBreaker.call(:ollama, fn ->
    do_generate_embedding(text)
  end)
end
```

The `CircuitBreaker.call/2` function tries to lookup via Registry:
```elixir
def call(name, operation) when is_function(operation, 0) do
  case get_state(name) do  # Calls via_tuple(name) → Registry lookup
    :open -> {:error, :circuit_breaker_open}
    # ...
```

But `:llm_service` and `:ollama` circuit breakers are **never started** in the supervision tree!

**Impact:**
- Registry lookup fails, returns `:closed` (fallback)
- Circuit breaker protection non-functional
- Cascade failures possible under load

**Fix:** Add circuit breaker children to supervision tree or use dynamic registration.

---

## ⚠️ Architectural Issues (P1)

### ARCH-001: Two Parallel MCP Server Implementations

**Files:**
- `lib/mimo/mcp_server.ex` - GenServer with stdio read loop
- `lib/mimo/mcp_server/stdio.ex` - Standalone stdio implementation

**Description:**  
Two different MCP implementations exist with different behaviors:

| Feature | McpServer (GenServer) | McpServer.Stdio |
|---------|----------------------|-----------------|
| Logging | Uses Logger normally | Silences all logs |
| Tool routing | Uses ToolInterface for internal | Uses Mimo.Tools.dispatch |
| Version | Reports "2.1.0" | Reports "2.3.2" |
| Started by | Application supervisor | CLI (`bin/mimo`) |

**Impact:**
- Inconsistent behavior between deployment modes
- Version mismatch in protocol responses
- Maintenance burden of two implementations

**Fix:** Consolidate into single implementation with mode flag.

---

### ARCH-002: Inconsistent Tool Schema Formats

**Files:**
- `lib/mimo/tools.ex` - Elixir atoms
- `lib/mimo/tool_registry.ex` - JSON strings
- `priv/skills_manifest.json` - JSON with different casing

```elixir
# Mimo.Tools - Atom keys
%{
  name: "fetch",
  description: "...",
  input_schema: %{type: "object", properties: %{url: %{type: "string"}}}
}

# ToolRegistry.internal_tools() - String keys
%{
  "name" => "ask_mimo",
  "description" => "...",
  "inputSchema" => %{"type" => "object", "properties" => %{}}
}
```

**Impact:**
- Schema conversion bugs
- Inconsistent API responses
- Brittle code with mixed access patterns

**Fix:** Standardize on JSON string format (MCP protocol requirement).

---

### ARCH-003: ProceduralStore Not Started by Default

**File:** `lib/mimo/application.ex` (line 148)

```elixir
defp synthetic_cortex_children do
  []
  |> maybe_add_child(:rust_nifs, {Mimo.Vector.Supervisor, []})
  |> maybe_add_child(:websocket_synapse, {Mimo.Synapse.ConnectionManager, []})
  |> maybe_add_child(:procedural_store, {Mimo.ProceduralStore.Registry, []})
end
```

Feature flag `procedural_store` defaults to `false`, but `ToolInterface` assumes it exists:

```elixir
def execute("recall_procedure", %{"name" => name} = args) do
  case Mimo.ProceduralStore.Loader.load(name, version) do  # ❌ Crashes if not started!
```

**Impact:**
- `recall_procedure` tool advertised but crashes
- Inconsistent feature availability

**Fix:** Either always start ProceduralStore or don't advertise the tool.

---

### ARCH-004: Race Condition in Catalog Loading

**File:** `lib/mimo/application.ex` (lines 72-87)

```elixir
defp wait_for_catalog_ready(0) do
  Logger.warning("⚠️ Catalog not ready after timeout, starting anyway")
  :ok  # ← Proceeds with potentially empty catalog!
end
```

**Impact:**
- First requests may fail with "tool not found"
- Race between catalog load and HTTP server start
- Flaky startup behavior

**Fix:** Block server startup until catalog ready or implement retry logic.

---

### ARCH-005: Dead Code - ensure_skill_running/2

**File:** `lib/mimo/tool_registry.ex` (lines 391-410)

```elixir
defp ensure_skill_running(skill_name, config) do
  case Registry.lookup(Mimo.Skills.Registry, skill_name) do
    [{pid, _}] when is_pid(pid) ->
      if Process.alive?(pid) do
        {:ok, pid}
      else
        start_skill(skill_name, config)
      end
    [] ->
      start_skill(skill_name, config)
  end
end
```

This function is **never called** from anywhere in the codebase.

**Impact:**
- Dead code suggesting incomplete refactoring
- Confusion for maintainers

**Fix:** Remove or integrate into skill lifecycle.

---

## 🔧 Logic Bugs (P1-P2)

### BUG-001: AutoMemory Silently Swallows Errors

**File:** `lib/mimo/auto_memory.ex` (lines 28-37)

```elixir
def wrap_tool_call(tool_name, arguments, result) do
  if enabled?() do
    Task.start(fn ->
      try do
        maybe_store_memory(tool_name, arguments, result)
      rescue
        e -> Logger.debug("AutoMemory failed: #{inspect(e)}")  # ❌ Silent failure!
      end
    end)
  end
  result
end
```

**Impact:**
- Memory storage failures invisible
- No telemetry for failures
- Debugging extremely difficult

**Fix:** Add telemetry event for failures, upgrade to Logger.warning.

---

### BUG-002: QueryInterface Returns Wrong Type for Procedural

**File:** `lib/mimo/ports/query_interface.ex` (lines 108-112)

```elixir
defp search_procedural(_query, %{primary_store: :procedural} = _decision) do
  %{status: "not_implemented", message: "..."}  # Returns map!
end

defp search_procedural(_query, _decision), do: nil  # Returns nil
```

Caller expects `nil` for unimplemented, gets a map instead.

**Impact:**
- Type confusion in response assembly
- Inconsistent API responses

**Fix:** Return `nil` or structured error tuple consistently.

---

### BUG-003: Observer Crashes on Non-Map Messages

**File:** `lib/mimo/semantic_store/observer.ex` (line 152)

```elixir
conversation_text =
  conversation_history
  |> Enum.map(fn msg -> msg["content"] || msg[:content] || "" end)  # ❌ Crashes if msg not map
```

**Impact:**
- Observer crashes on malformed input
- No input validation

**Fix:** Add guard clause or pattern match.

---

### BUG-004: Dreamer Transaction Mode Hardcoded for SQLite

**File:** `lib/mimo/semantic_store/dreamer.ex` (line 136)

```elixir
Repo.transaction(
  fn -> ... end,
  mode: :immediate,  # ❌ SQLite-specific!
  timeout: 30_000
)
```

**Impact:**
- Cannot switch to PostgreSQL
- Database vendor lock-in

**Fix:** Make transaction mode configurable.

---

### BUG-005: Rate Limiter ETS Cleanup Only on Request

**File:** `lib/mimo_web/plugs/rate_limiter.ex` (lines 67-84)

```elixir
defp check_rate_limit(client_ip, limit, window_ms) do
  # ...
  cleanup_old_entries(now, window_ms)  # Only called during request!
```

**Impact:**
- Stale entries accumulate during traffic lulls
- Memory grows unbounded over time

**Fix:** Add periodic cleanup via separate process or timer.

---

## 🔒 Security Issues

### SEC-001: API Key Bypass via Mix.env

See CRIT-004 above.

---

### SEC-002: Deprecated spawn_legacy Still Callable

**File:** `lib/mimo/skills/process_manager.ex` (lines 57-77)

```elixir
@deprecated "Use spawn_secure/1 instead - this bypasses SecureExecutor"
@spec spawn_legacy(map()) :: spawn_result()
def spawn_legacy(%{"command" => cmd, "args" => args} = config) do
  # Still publicly callable!
```

**Impact:**
- Security bypass possible via direct function call
- Deprecated functions should be private or removed

**Fix:** Make private or remove entirely.

---

### SEC-003: Compile-Time Environment Variable Evaluation

**File:** `lib/mimo/brain/llm.ex` (line 14)

```elixir
@default_model System.get_env("OPENROUTER_MODEL", "kwaipilot/kat-coder-pro:free")
```

Module attributes evaluated at **compile time**, not runtime.

**Impact:**
- Cannot change model via env var at deploy time
- Must recompile to change

**Fix:** Move to runtime config or function call.

---

## 📊 Configuration Issues (P2)

### CFG-001: Hardcoded URLs

**File:** `lib/mimo/brain/llm.ex` (line 13)

```elixir
@openrouter_url "https://openrouter.ai/api/v1/chat/completions"
```

**Fix:** Move to application config.

---

### CFG-002: Inconsistent Timeout Defaults

| Module | Timeout | Context |
|--------|---------|---------|
| `client.ex` | 60,000ms | Tool calls |
| `hot_reload.ex` | 30,000ms | Drain |
| `secure_executor.ex` | 120,000ms | npx commands |
| `dreamer.ex` | 30,000ms | Inference |

**Fix:** Centralize timeout configuration.

---

### CFG-003: Feature Flags Not Documented

```elixir
config :mimo_mcp, :feature_flags,
  rust_nifs: {:system, "RUST_NIFS_ENABLED", false},
  semantic_store: {:system, "SEMANTIC_STORE_ENABLED", false},
  procedural_store: {:system, "PROCEDURAL_STORE_ENABLED", false},
  websocket_synapse: {:system, "WEBSOCKET_ENABLED", false}
```

No documentation on what each flag enables or dependencies.

**Fix:** Add documentation and validation.

---

## 🧪 Test Coverage Gaps (P2)

### TEST-001: No Tests for ToolInterface

**Missing:** `test/mimo/ports/tool_interface_test.exs`

### TEST-002: No Tests for AutoMemory

**Missing:** `test/mimo/auto_memory_test.exs`

### TEST-003: No Tests for QueryInterface

**Missing:** `test/mimo/ports/query_interface_test.exs`

### TEST-004: Integration Tests Only Check Module Loading

**File:** `test/integration/full_pipeline_test.exs`

Most tests just call `Code.ensure_loaded?()` without actual integration testing.

---

## 🔀 Concurrency Issues (P1)

### CONC-001: Hot Reload Drain Check Incorrect

**File:** `lib/mimo/skills/hot_reload.ex` (lines 150-180)

```elixir
defp all_drained? do
  Mimo.ToolRegistry.all_drained?()
end

# In ToolRegistry:
def handle_call(:all_drained?, _from, state) do
  all_drained = map_size(state.skills) == 0 or state.draining  # Just checks flag!
```

Does not track actual in-flight requests.

**Fix:** Implement request counter per skill.

---

### CONC-002: Port Monitor Race in Skills.Client

**File:** `lib/mimo/skills/client.ex` (lines 92-96)

```elixir
port_monitor_ref = Port.monitor(port)
Process.sleep(1000)  # ❌ Race window!
case discover_tools(port) do
```

**Fix:** Handle port death during discovery gracefully.

---

## 🔄 Tool Redundancy Analysis

### Current State: 42 Tools from 3 Sources

| Source | Count | Tools |
|--------|-------|-------|
| External MCP Skills | 37 | desktop_commander (23), puppeteer (7), fetch (4), exa_search (2), sequential_thinking (1) |
| Internal (tool_registry.ex) | 5 | ask_mimo, search_vibes, store_fact, mimo_store_memory, mimo_reload_skills |
| Mimo.Tools (NOT exposed) | ~12 | fetch, terminal, file, think, plan, consult_graph, teach_mimo, etc. |

### Redundant Pairs Identified

| Pair | Issue | Recommendation |
|------|-------|----------------|
| `fetch` (Mimo.Tools) vs `fetch_*` (external) | Mimo's supports POST/PUT/DELETE/headers; external has 4 separate tools | Expose Mimo's fetch, deprecate external |
| `terminal` (Mimo.Tools) vs `desktop_commander_*` | desktop_commander has 23 tools; Mimo's is sandboxed | Keep both, document use cases |
| `file` (Mimo.Tools) vs `desktop_commander_read/write_file` | Overlapping file operations | Keep both, document use cases |
| `store_fact` vs `mimo_store_memory` | EXACT SAME FUNCTION | Remove mimo_store_memory |
| `think` vs `sequential_thinking` | Both for reasoning steps | Disable sequential_thinking skill |

---

## Recommended Fix Priority

### P0 - Fix Immediately (Security/Breaking)

| ID | Issue | Estimated Effort |
|----|-------|------------------|
| CRIT-003 | Pattern match mismatch in mcp_server.ex | 5 minutes |
| CRIT-004 | Mix.env() at runtime | 30 minutes |
| CRIT-005 | Circuit breaker processes not started | 1 hour |
| SEC-002 | spawn_legacy still public | 10 minutes |

### P1 - High Priority (This Sprint)

| ID | Issue | Estimated Effort |
|----|-------|------------------|
| CRIT-001 | Duplicate store_fact/mimo_store_memory | 30 minutes |
| CRIT-002 | Mimo.Tools not exposed via MCP | 1 hour |
| ARCH-001 | Two MCP server implementations | 4 hours |
| ARCH-003 | ProceduralStore not started by default | 30 minutes |
| ARCH-004 | Race condition in catalog loading | 1 hour |

### P2 - Medium Priority (Technical Debt)

| ID | Issue | Estimated Effort |
|----|-------|------------------|
| ARCH-002 | Inconsistent tool schema formats | 2 hours |
| ARCH-005 | Dead code ensure_skill_running | 10 minutes |
| BUG-001 | AutoMemory swallows errors | 30 minutes |
| BUG-005 | Rate limiter cleanup | 1 hour |
| TEST-* | Missing test coverage | 4 hours |

### P3 - Low Priority (Cleanup)

| ID | Issue | Estimated Effort |
|----|-------|------------------|
| CFG-001 | Hardcoded URLs | 30 minutes |
| CFG-002 | Inconsistent timeouts | 1 hour |
| SEC-003 | Compile-time env vars | 30 minutes |

---

## Appendix: File Reference Index

| File | Issues |
|------|--------|
| `lib/mimo/application.ex` | ARCH-003, ARCH-004, CRIT-005 |
| `lib/mimo/mcp_server.ex` | CRIT-003, ARCH-001 |
| `lib/mimo/mcp_server/stdio.ex` | ARCH-001, CRIT-002 |
| `lib/mimo/tool_registry.ex` | CRIT-001, CRIT-002, ARCH-005, CONC-001 |
| `lib/mimo/tools.ex` | CRIT-002, ARCH-002 |
| `lib/mimo/ports/tool_interface.ex` | CRIT-001, ARCH-003 |
| `lib/mimo/ports/query_interface.ex` | BUG-002 |
| `lib/mimo/brain/llm.ex` | CRIT-005, SEC-003, CFG-001 |
| `lib/mimo/auto_memory.ex` | BUG-001 |
| `lib/mimo/skills/client.ex` | CONC-002 |
| `lib/mimo/skills/process_manager.ex` | SEC-002 |
| `lib/mimo/skills/hot_reload.ex` | CONC-001 |
| `lib/mimo/semantic_store/observer.ex` | BUG-003 |
| `lib/mimo/semantic_store/dreamer.ex` | BUG-004 |
| `lib/mimo_web/plugs/authentication.ex` | CRIT-004 |
| `lib/mimo_web/plugs/rate_limiter.ex` | BUG-005 |

---

*Report generated by automated codebase analysis.*
