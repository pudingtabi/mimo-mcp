# Mimo-MCP Gateway: Remediation Tasks Prompt

> **Purpose:** Optimized prompt for AI agents to systematically fix identified issues  
> **Reference:** `docs/FAULT_ANALYSIS_REPORT.md`  
> **Total Tasks:** 30 actionable items across 4 phases

---

## Context

You are working on the Mimo-MCP Gateway, an Elixir-based MCP (Model Context Protocol) server that acts as a bridge between AI assistants and external tools/skills. The codebase has been audited and 35+ issues have been identified.

### Codebase Structure
```
lib/
├── mimo.ex                    # Bootstrap and lifecycle
├── mimo_web.ex               # Phoenix web macros
├── mimo/
│   ├── application.ex        # OTP supervision tree
│   ├── mcp_server.ex         # MCP GenServer
│   ├── mcp_server/stdio.ex   # MCP stdio implementation
│   ├── tool_registry.ex      # Tool registration/lookup
│   ├── tools.ex              # Internal tool definitions
│   ├── auto_memory.ex        # Auto-memory wrapper
│   ├── meta_cognitive_router.ex
│   ├── brain/                # Memory, LLM, embeddings
│   ├── skills/               # External skill management
│   ├── ports/                # Interface abstractions
│   ├── semantic_store/       # Knowledge graph
│   ├── procedural_store/     # Procedure definitions
│   └── error_handling/       # Circuit breaker, retry
└── mimo_web/
    ├── router.ex
    ├── controllers/
    └── plugs/
```

---

## Phase 1: Critical Security & Breaking Fixes (P0)

### Task 1.1: Fix Pattern Match in MCP Server

**File:** `lib/mimo/mcp_server.ex`  
**Line:** ~96  
**Issue:** 3-tuple pattern match vs 4-tuple return value

**Current Code:**
```elixir
case Mimo.ToolRegistry.get_tool_owner(tool_name) do
  {:ok, {:skill, skill_name, _client_pid}} ->
    Mimo.Skills.Client.call_tool(skill_name, tool_name, arguments)
```

**Required Fix:**
```elixir
case Mimo.ToolRegistry.get_tool_owner(tool_name) do
  {:ok, {:skill, skill_name, _pid, _tool_def}} ->
    Mimo.Skills.Client.call_tool(skill_name, tool_name, arguments)
```

**Verification:**
- [ ] Pattern matches 4-tuple correctly
- [ ] External skill routing works
- [ ] Run: `mix test test/mimo/mcp_server/`

---

### Task 1.2: Remove Mix.env() Runtime Checks

**File:** `lib/mimo_web/plugs/authentication.ex`  
**Lines:** 24, 42  
**Issue:** `Mix.env()` evaluated at compile time, not runtime

**Current Code:**
```elixir
if Mix.env() == :prod and (is_nil(api_key) or api_key == "") do
  # ...
if Mix.env() != :prod and (is_nil(api_key) or api_key == "") do
```

**Required Fix:**
1. Add config in `config/runtime.exs`:
```elixir
config :mimo_mcp, :environment, config_env()
```

2. Update authentication.ex:
```elixir
defp production? do
  Application.get_env(:mimo_mcp, :environment) == :prod
end

# Replace Mix.env() == :prod with production?()
# Replace Mix.env() != :prod with not production?()
```

**Verification:**
- [ ] No `Mix.env()` calls in runtime code
- [ ] Authentication works in releases
- [ ] Run: `mix test test/mimo_web/plugs/`

---

### Task 1.3: Start Circuit Breaker Processes

**File:** `lib/mimo/application.ex`  
**Issue:** Circuit breakers for `:llm_service` and `:ollama` never started

**Required Fix:**
Add to supervision tree children:
```elixir
children = [
  # ... existing children ...
  
  # Circuit breakers for external services
  {Mimo.ErrorHandling.CircuitBreaker, name: :llm_service, failure_threshold: 5},
  {Mimo.ErrorHandling.CircuitBreaker, name: :ollama, failure_threshold: 3},
]
```

**Verification:**
- [ ] Circuit breakers start with application
- [ ] `Mimo.ErrorHandling.CircuitBreaker.status(:llm_service)` returns `:closed`
- [ ] Run: `mix test test/mimo/error_handling/`

---

### Task 1.4: Make spawn_legacy Private

**File:** `lib/mimo/skills/process_manager.ex`  
**Line:** ~57  
**Issue:** Deprecated function still publicly callable

**Required Fix:**
Change from:
```elixir
@deprecated "Use spawn_secure/1 instead"
@spec spawn_legacy(map()) :: spawn_result()
def spawn_legacy(...) do
```

To:
```elixir
# Remove @deprecated annotation (private functions can't be deprecated)
@spec do_spawn_legacy(map()) :: spawn_result()
defp do_spawn_legacy(...) do
```

Or remove entirely if unused.

**Verification:**
- [ ] Function not exported
- [ ] Compile succeeds
- [ ] Run: `mix compile --warnings-as-errors`

---

## Phase 2: High Priority Architectural Fixes (P1)

### Task 2.1: Remove Duplicate mimo_store_memory Tool

**Files:**
- `lib/mimo/tool_registry.ex` (internal_tools function)
- `lib/mimo/ports/tool_interface.ex`

**Steps:**
1. Remove `mimo_store_memory` from `internal_tools()` list in tool_registry.ex
2. Remove `execute("mimo_store_memory", ...)` clause in tool_interface.ex
3. Update `store_fact` to require `category` field (currently optional)

**Verification:**
- [ ] Only `store_fact` exists for memory storage
- [ ] `tools/list` returns 4 internal tools (not 5)
- [ ] Run: `mix test test/mimo/tool_registry_test.exs`

---

### Task 2.2: Expose Mimo.Tools via MCP

**File:** `lib/mimo/tool_registry.ex`

**Current Code (list_all_tools):**
```elixir
def list_all_tools do
  internal_tools() ++ catalog_tools() ++ active_skill_tools()
end
```

**Required Fix:**
```elixir
def list_all_tools do
  internal_tools() ++ mimo_core_tools() ++ catalog_tools() ++ active_skill_tools()
end

defp mimo_core_tools do
  Mimo.Tools.list_tools()
  |> Enum.map(&convert_to_mcp_format/1)
end

defp convert_to_mcp_format(%{name: name, description: desc, input_schema: schema}) do
  %{
    "name" => name,
    "description" => desc,
    "inputSchema" => convert_schema(schema)
  }
end

defp convert_schema(schema) when is_map(schema) do
  for {k, v} <- schema, into: %{} do
    {to_string(k), if(is_map(v), do: convert_schema(v), else: v)}
  end
end
```

**Verification:**
- [ ] `tools/list` includes fetch, terminal, file, think, plan, etc.
- [ ] Tool schemas are valid JSON
- [ ] Run manual test: `echo '{"jsonrpc":"2.0","method":"tools/list","id":1}' | mix run -e 'Mimo.McpServer.Stdio.start()'`

---

### Task 2.3: Consolidate MCP Server Implementations

**Files:**
- `lib/mimo/mcp_server.ex`
- `lib/mimo/mcp_server/stdio.ex`

**Strategy:**
1. Keep `Mimo.McpServer.Stdio` as the single stdio implementation
2. Convert `Mimo.McpServer` to a thin wrapper that delegates
3. Unify version strings to "2.3.2"
4. Unify tool routing logic

**Required Changes:**
1. Update `Mimo.McpServer` to use `Mimo.McpServer.Stdio` logic
2. Or remove `Mimo.McpServer` GenServer entirely, use Stdio directly
3. Ensure both report same `serverInfo.version`

**Verification:**
- [ ] Only one MCP implementation
- [ ] Version consistent in both modes
- [ ] Run: `mix test test/mimo/mcp_server/`

---

### Task 2.4: Fix Catalog Loading Race Condition

**File:** `lib/mimo/application.ex`

**Current Code:**
```elixir
defp wait_for_catalog_ready(0) do
  Logger.warning("⚠️ Catalog not ready after timeout, starting anyway")
  :ok
end
```

**Required Fix:**
```elixir
defp wait_for_catalog_ready(0) do
  Logger.error("Catalog not ready after 5 seconds - this may cause startup issues")
  # Don't start servers if catalog failed
  {:error, :catalog_timeout}
end

# Update start/2 to handle this:
def start(_type, _args) do
  # ... start children ...
  
  case wait_for_catalog_ready() do
    :ok -> 
      start_http_endpoint(sup)
      start_mcp_server(sup)
    {:error, reason} ->
      Logger.error("Delayed server startup due to: #{reason}")
      # Retry catalog load or fail gracefully
  end
end
```

**Verification:**
- [ ] Application fails fast if catalog broken
- [ ] Servers don't start with empty catalog
- [ ] Run: `mix test test/mimo/application_test.exs`

---

### Task 2.5: Guard ProceduralStore Tool Availability

**File:** `lib/mimo/ports/tool_interface.ex`

**Current Code:**
```elixir
def execute("recall_procedure", %{"name" => name} = args) do
  case Mimo.ProceduralStore.Loader.load(name, version) do
```

**Required Fix:**
```elixir
def execute("recall_procedure", %{"name" => name} = args) do
  if Mimo.Application.feature_enabled?(:procedural_store) do
    case Mimo.ProceduralStore.Loader.load(name, version) do
      # ... existing logic
    end
  else
    {:error, "Procedural store not enabled. Set PROCEDURAL_STORE_ENABLED=true"}
  end
end
```

Also update `list_tools/0` to conditionally include recall_procedure.

**Verification:**
- [ ] Tool not advertised when feature disabled
- [ ] Graceful error when feature disabled
- [ ] Run: `mix test test/mimo/ports/`

---

## Phase 3: Logic Bug Fixes (P2)

### Task 3.1: Add Telemetry for AutoMemory Failures

**File:** `lib/mimo/auto_memory.ex`

**Current Code:**
```elixir
rescue
  e -> Logger.debug("AutoMemory failed: #{inspect(e)}")
```

**Required Fix:**
```elixir
rescue
  e ->
    :telemetry.execute(
      [:mimo, :auto_memory, :failure],
      %{count: 1},
      %{tool: tool_name, error: Exception.message(e)}
    )
    Logger.warning("AutoMemory storage failed for #{tool_name}: #{Exception.message(e)}")
end
```

**Verification:**
- [ ] Telemetry event emitted on failure
- [ ] Log level is warning, not debug
- [ ] Run: `mix test test/mimo/auto_memory_test.exs` (create if needed)

---

### Task 3.2: Fix QueryInterface Procedural Return Type

**File:** `lib/mimo/ports/query_interface.ex`

**Current Code:**
```elixir
defp search_procedural(_query, %{primary_store: :procedural} = _decision) do
  %{status: "not_implemented", message: "..."}
end
```

**Required Fix:**
```elixir
defp search_procedural(_query, %{primary_store: :procedural} = _decision) do
  # Return nil for consistency, or implement actual search
  nil
end
```

Or implement properly:
```elixir
defp search_procedural(query, %{primary_store: :procedural} = _decision) do
  if Mimo.Application.feature_enabled?(:procedural_store) do
    case Mimo.ProceduralStore.Loader.search(query) do
      {:ok, results} -> results
      _ -> nil
    end
  else
    nil
  end
end
```

**Verification:**
- [ ] Return type consistent (nil or list)
- [ ] No type confusion in response assembly

---

### Task 3.3: Add Input Validation to Observer

**File:** `lib/mimo/semantic_store/observer.ex`

**Current Code:**
```elixir
|> Enum.map(fn msg -> msg["content"] || msg[:content] || "" end)
```

**Required Fix:**
```elixir
|> Enum.map(fn 
  msg when is_map(msg) -> msg["content"] || msg[:content] || ""
  _ -> ""
end)
```

**Verification:**
- [ ] Observer doesn't crash on non-map input
- [ ] Run: `mix test test/mimo/semantic_store/`

---

### Task 3.4: Make Dreamer Transaction Mode Configurable

**File:** `lib/mimo/semantic_store/dreamer.ex`

**Current Code:**
```elixir
Repo.transaction(
  fn -> ... end,
  mode: :immediate,
  timeout: 30_000
)
```

**Required Fix:**
```elixir
defp transaction_opts do
  case Application.get_env(:mimo_mcp, :database_adapter) do
    :sqlite -> [mode: :immediate, timeout: 30_000]
    _ -> [timeout: 30_000]
  end
end

Repo.transaction(fn -> ... end, transaction_opts())
```

**Verification:**
- [ ] Works with SQLite
- [ ] Works with PostgreSQL (if configured)

---

### Task 3.5: Add Periodic Rate Limiter Cleanup

**File:** `lib/mimo_web/plugs/rate_limiter.ex`

**Required Fix:**
Add a separate cleanup process or use existing telemetry poller:

```elixir
# In Mimo.Telemetry, add to periodic_measurements:
defp periodic_measurements do
  [
    {__MODULE__, :measure_memory, []},
    {__MODULE__, :measure_schedulers, []},
    {MimoWeb.Plugs.RateLimiter, :cleanup_stale_entries, []}
  ]
end

# In rate_limiter.ex, add:
def cleanup_stale_entries do
  if :ets.whereis(@table_name) != :undefined do
    now = System.monotonic_time(:millisecond)
    window_ms = Application.get_env(:mimo_mcp, :rate_limit_window_ms, @default_window_ms)
    cleanup_old_entries(now, window_ms)
  end
end
```

**Verification:**
- [ ] Cleanup runs periodically
- [ ] ETS table doesn't grow unbounded

---

## Phase 4: Test Coverage & Documentation (P3)

### Task 4.1: Create ToolInterface Tests

**File:** `test/mimo/ports/tool_interface_test.exs` (create new)

```elixir
defmodule Mimo.ToolInterfaceTest do
  use ExUnit.Case, async: true
  
  describe "execute/2" do
    test "search_vibes returns results" do
      assert {:ok, %{status: "success"}} = 
        Mimo.ToolInterface.execute("search_vibes", %{"query" => "test"})
    end
    
    test "store_fact persists memory" do
      assert {:ok, %{data: %{stored: true}}} = 
        Mimo.ToolInterface.execute("store_fact", %{
          "content" => "test fact",
          "category" => "fact"
        })
    end
    
    test "unknown tool returns error" do
      assert {:error, _} = Mimo.ToolInterface.execute("nonexistent", %{})
    end
  end
  
  describe "list_tools/0" do
    test "returns list of tool definitions" do
      tools = Mimo.ToolInterface.list_tools()
      assert is_list(tools)
      assert Enum.all?(tools, &is_map/1)
    end
  end
end
```

---

### Task 4.2: Create AutoMemory Tests

**File:** `test/mimo/auto_memory_test.exs` (create new)

```elixir
defmodule Mimo.AutoMemoryTest do
  use ExUnit.Case, async: true
  
  describe "wrap_tool_call/3" do
    test "returns original result unchanged" do
      result = {:ok, "test result"}
      assert ^result = Mimo.AutoMemory.wrap_tool_call("test_tool", %{}, result)
    end
    
    test "handles error results" do
      result = {:error, "test error"}
      assert ^result = Mimo.AutoMemory.wrap_tool_call("test_tool", %{}, result)
    end
  end
  
  describe "enabled?/0" do
    test "returns boolean" do
      assert is_boolean(Mimo.AutoMemory.enabled?())
    end
  end
end
```

---

### Task 4.3: Create QueryInterface Tests

**File:** `test/mimo/ports/query_interface_test.exs` (create new)

```elixir
defmodule Mimo.QueryInterfaceTest do
  use ExUnit.Case, async: true
  
  describe "ask/3" do
    test "returns structured response" do
      assert {:ok, response} = Mimo.QueryInterface.ask("test query")
      assert Map.has_key?(response, :query_id)
      assert Map.has_key?(response, :router_decision)
      assert Map.has_key?(response, :results)
    end
    
    test "respects timeout" do
      assert {:error, :timeout} = 
        Mimo.QueryInterface.ask("test", nil, timeout_ms: 1)
    end
  end
end
```

---

### Task 4.4: Update README with Tool Documentation

**File:** `README.md`

Add section documenting:
1. All available tools (internal + external)
2. When to use each tool
3. Feature flags and their effects
4. Tool redundancy notes

---

## Verification Checklist

After completing all tasks, verify:

```bash
# Compile without warnings
mix compile --warnings-as-errors

# Run all tests
mix test

# Run specific test suites
mix test test/mimo/mcp_server/
mix test test/mimo/tool_registry_test.exs
mix test test/mimo/ports/
mix test test/integration/

# Check for deprecated functions
mix xref deprecated

# Verify MCP protocol
echo '{"jsonrpc":"2.0","method":"initialize","id":1}' | mix run -e 'Mimo.McpServer.Stdio.start()'
echo '{"jsonrpc":"2.0","method":"tools/list","id":2}' | mix run -e 'Mimo.McpServer.Stdio.start()'

# Start application and verify no crashes
iex -S mix

# In IEx, verify:
Mimo.ToolRegistry.list_all_tools() |> length()  # Should be ~47 (reduced from 54)
Mimo.ErrorHandling.CircuitBreaker.status(:llm_service)  # Should be :closed
Mimo.Application.cortex_status()  # Should show all module statuses
```

---

## Success Criteria

- [ ] All P0 tasks completed and verified
- [ ] All P1 tasks completed and verified
- [ ] All P2 tasks completed and verified
- [ ] Test coverage increased by 4 new test files
- [ ] No `Mix.env()` in runtime code
- [ ] Tool count reduced from 42 to ~35
- [ ] All tests passing
- [ ] No compile warnings

---

## Notes for AI Agents

1. **Always read the file before editing** to get current context
2. **Run tests after each change** to catch regressions
3. **One task at a time** - complete and verify before moving on
4. **Document changes** in git commits with task ID (e.g., "Fix CRIT-003: Pattern match mismatch")
5. **Ask for clarification** if a task is ambiguous

---

*Prompt version: 1.0 | Last updated: November 28, 2025*
