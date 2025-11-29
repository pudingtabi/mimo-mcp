# SPEC-011 Implementation Prompt

## Context

You are implementing SPEC-011 (Tool Exposure Gap Remediation) for Mimo MCP, an Elixir-based memory system. Read the full spec at `docs/specs/SPEC-011-exposure-gaps.md`.

## Codebase Orientation

**Key Files:**
```
lib/mimo/ports/tool_interface.ex    # Tool execution dispatch (add new tools here)
lib/mimo/tool_registry.ex           # Tool registration and metadata
lib/mimo/tools.ex                   # Core tool definitions and dispatchers
lib/mimo/procedural_store/          # FSM implementation
  ├── execution_fsm.ex              # gen_statem FSM (already working)
  ├── loader.ex                     # Procedure loading
  └── execution.ex                  # Execution records (Ecto schema)
lib/mimo/brain/                     # Memory systems
  ├── memory.ex                     # Long-term memory operations
  ├── working_memory.ex             # ETS-based working memory
  ├── consolidator.ex               # Working → long-term transfer
  ├── decay_scorer.ex               # Decay calculation
  └── engram.ex                     # Memory schema
lib/mimo/episodic_store.ex          # Vector search
lib/mimo/semantic_store.ex          # Triple store
```

**Existing Patterns:**

Tool execution in `tool_interface.ex`:
```elixir
def execute("tool_name", %{"arg" => value} = args) do
  case do_something(value) do
    {:ok, result} ->
      {:ok, %{tool_call_id: UUID.uuid4(), status: "success", data: result}}
    {:error, reason} ->
      {:error, "Failed: #{inspect(reason)}"}
  end
end
```

Tool registration in `tool_registry.ex`:
```elixir
@internal_tools [
  "store_fact",
  "search_vibes",
  "ask_mimo",
  # Add new tools here
]
```

---

## Task 1: SPEC-011.1 - Procedural Store Exposure

### Implement `run_procedure` tool

**Location:** `lib/mimo/ports/tool_interface.ex`

**Requirements:**
1. Check if procedural store is enabled (like `recall_procedure` does)
2. Start `ExecutionFSM.start_procedure/4` with caller option
3. For sync mode: wait for `{:procedure_complete, name, status, context}` message
4. For async mode: return execution_id immediately
5. Handle timeout (default 60s for sync)

**Signature:**
```elixir
def execute("run_procedure", %{"name" => name} = args) do
  # version = Map.get(args, "version", "latest")
  # context = Map.get(args, "context", %{})
  # async = Map.get(args, "async", false)
end
```

**Return format (sync):**
```elixir
%{
  execution_id: uuid,
  status: "completed" | "failed" | "interrupted",
  final_state: "state_name",
  context: %{...},
  history: [...],
  duration_ms: integer
}
```

### Implement `procedure_status` tool

**Location:** `lib/mimo/ports/tool_interface.ex`

**Requirements:**
1. Query `Mimo.ProceduralStore.Execution` by ID
2. Return current status and context

### Implement `list_procedures` tool

**Location:** `lib/mimo/ports/tool_interface.ex`

**Requirements:**
1. Query all procedures from `Mimo.ProceduralStore.Procedure`
2. Return name, version, description, state count

### Register tools

**Location:** `lib/mimo/tool_registry.ex`

Add to `@internal_tools`:
```elixir
"run_procedure",
"procedure_status", 
"list_procedures"
```

Add tool definitions in `get_internal_tool_definitions/0`.

---

## Task 2: SPEC-011.2 - Unified Memory Tool

### Create unified `memory` tool

**Location:** `lib/mimo/ports/tool_interface.ex`

**Operations:**

```elixir
def execute("memory", %{"operation" => "store"} = args) do
  # Delegate to existing store_fact logic
end

def execute("memory", %{"operation" => "search"} = args) do
  # Delegate to existing search_vibes logic
end

def execute("memory", %{"operation" => "list"} = args) do
  # NEW: Query Engram with pagination
  # limit = Map.get(args, "limit", 20)
  # offset = Map.get(args, "offset", 0)
  # sort = Map.get(args, "sort", "recent")
end

def execute("memory", %{"operation" => "delete"} = args) do
  # NEW: Delete by ID
  # Repo.delete(Engram, id)
end

def execute("memory", %{"operation" => "stats"} = args) do
  # NEW: Aggregate stats
  # Count by category, avg importance, decay stats
end

def execute("memory", %{"operation" => "decay_check"} = args) do
  # NEW: Use DecayScorer.filter_forgettable/2
end
```

### Keep aliases (deprecated)

```elixir
def execute("store_fact", args) do
  Logger.warning("store_fact is deprecated, use memory operation=store")
  execute("memory", Map.put(args, "operation", "store"))
end
```

---

## Task 3: SPEC-011.3 - File Ingestion

### Create `ingest` tool

**Location:** `lib/mimo/ports/tool_interface.ex`

**New module:** `lib/mimo/ingest.ex`

```elixir
defmodule Mimo.Ingest do
  @max_file_size 10_485_760  # 10MB
  
  def ingest_file(path, opts \\ []) do
    strategy = Keyword.get(opts, :strategy, :auto)
    category = Keyword.get(opts, :category, "fact")
    importance = Keyword.get(opts, :importance, 0.5)
    tags = Keyword.get(opts, :tags, [])
    
    with {:ok, content} <- read_file_safe(path),
         {:ok, chunks} <- chunk_content(content, strategy, path),
         {:ok, ids} <- store_chunks(chunks, category, importance, tags, path) do
      {:ok, %{
        chunks_created: length(ids),
        file_size: byte_size(content),
        strategy_used: strategy,
        ids: ids
      }}
    end
  end
  
  defp chunk_content(content, :auto, path) do
    strategy = detect_strategy(path)
    chunk_content(content, strategy, path)
  end
  
  defp chunk_content(content, :paragraphs, _path) do
    chunks = String.split(content, ~r/\n\n+/)
             |> Enum.filter(&(String.length(&1) > 10))
    {:ok, chunks}
  end
  
  defp chunk_content(content, :markdown, _path) do
    # Split on headers
    chunks = Regex.split(~r/^#{1,3}\s/m, content, include_captures: true)
             |> chunk_markdown_sections()
    {:ok, chunks}
  end
  
  defp detect_strategy(path) do
    case Path.extname(path) do
      ".md" -> :markdown
      ".txt" -> :paragraphs
      ".json" -> :whole
      ".yaml" -> :whole
      ".yml" -> :whole
      _ -> :paragraphs
    end
  end
end
```

### Tool handler

```elixir
def execute("ingest", %{"path" => path} = args) do
  # Check sandbox restrictions
  # Call Mimo.Ingest.ingest_file/2
end
```

---

## Task 4: SPEC-011.4 - Natural Time Queries

### Create time parser module

**Location:** `lib/mimo/utils/time_parser.ex`

```elixir
defmodule Mimo.Utils.TimeParser do
  @doc """
  Parse natural language time expression to date range.
  
  Returns {:ok, {from_datetime, to_datetime}} or {:error, reason}
  """
  def parse(expression) do
    now = DateTime.utc_now()
    
    case String.downcase(expression) do
      "today" ->
        {:ok, {start_of_day(now), now}}
      
      "yesterday" ->
        yesterday = DateTime.add(now, -1, :day)
        {:ok, {start_of_day(yesterday), end_of_day(yesterday)}}
      
      "last week" ->
        {:ok, {DateTime.add(now, -7, :day), now}}
      
      "last month" ->
        {:ok, {DateTime.add(now, -30, :day), now}}
      
      "this week" ->
        {:ok, {start_of_week(now), now}}
      
      expr ->
        parse_relative(expr, now)
    end
  end
  
  defp parse_relative(expr, now) do
    case Regex.run(~r/(\d+)\s*(days?|hours?|weeks?|months?)\s*ago/, expr) do
      [_, n, unit] ->
        amount = String.to_integer(n)
        from = subtract_time(now, amount, unit)
        {:ok, {from, now}}
      nil ->
        {:error, "Cannot parse time expression: #{expr}"}
    end
  end
end
```

### Integrate with memory search

Add `time_filter` parameter handling in memory search operation:
```elixir
def execute("memory", %{"operation" => "search", "time_filter" => filter} = args) do
  case Mimo.Utils.TimeParser.parse(filter) do
    {:ok, {from, to}} ->
      # Add to query: where inserted_at >= ^from and inserted_at <= ^to
    {:error, reason} ->
      {:error, reason}
  end
end
```

---

## Testing

For each task, add tests in:
- `test/mimo/ports/tool_interface_test.exs` (or create if missing)
- `test/mimo/ingest_test.exs` (new)
- `test/mimo/utils/time_parser_test.exs` (new)

Example test:
```elixir
describe "run_procedure" do
  test "executes procedure and returns result" do
    # Setup: ensure a test procedure exists
    {:ok, result} = ToolInterface.execute("run_procedure", %{
      "name" => "test_procedure",
      "context" => %{"input" => "value"}
    })
    
    assert result.status == "success"
    assert result.data.status == "completed"
  end
end
```

---

## Checklist

### SPEC-011.1 Procedural Exposure
- [ ] `run_procedure` tool implemented (sync + async)
- [ ] `procedure_status` tool implemented
- [ ] `list_procedures` tool implemented
- [ ] Tools registered in tool_registry.ex
- [ ] Tool definitions added
- [ ] Tests passing

### SPEC-011.2 Unified Memory
- [ ] `memory` tool with all operations
- [ ] `store` operation working
- [ ] `search` operation working
- [ ] `list` operation working (NEW)
- [ ] `delete` operation working (NEW)
- [ ] `stats` operation working (NEW)
- [ ] `decay_check` operation working (NEW)
- [ ] Deprecated aliases working with warning
- [ ] Tests passing

### SPEC-011.3 File Ingestion
- [ ] `Mimo.Ingest` module created
- [ ] Paragraph chunking working
- [ ] Markdown chunking working
- [ ] `ingest` tool implemented
- [ ] Sandbox restrictions respected
- [ ] Tests passing

### SPEC-011.4 Time Queries
- [ ] `Mimo.Utils.TimeParser` module created
- [ ] "today", "yesterday", "last week" working
- [ ] "N days ago" pattern working
- [ ] Integrated with memory search
- [ ] Tests passing

---

## Constraints

1. **No breaking changes** - existing tools must keep working
2. **Simple implementations** - no over-engineering
3. **Follow existing patterns** - match code style in codebase
4. **Telemetry** - emit events for observability
5. **Error handling** - return helpful error messages
