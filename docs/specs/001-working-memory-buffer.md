# SPEC-001: Working Memory Buffer System

## 📋 Overview

**Status:** Not Started  
**Priority:** CRITICAL  
**Estimated Effort:** 2-3 days  
**Dependencies:** None (foundation component)

### Purpose

Implement a short-lived working memory buffer that holds active context during AI interactions. This mimics human working memory which has limited capacity and duration, serving as a staging area before memories are consolidated into long-term storage.

### Research Foundation

From the Memory MCP research document:
- Working memory should be separate from long-term storage
- Items expire after ~5-10 minutes of inactivity
- Limited capacity (recent N items or token budget)
- Serves as consolidation source during "sleep" phases

---

## 🎯 Requirements

### Functional Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| WM-01 | Store memories with automatic TTL expiration | MUST |
| WM-02 | Limit buffer size (configurable, default 100 items) | MUST |
| WM-03 | Support FIFO eviction when capacity exceeded | MUST |
| WM-04 | Track memory context (source, session, importance) | MUST |
| WM-05 | Provide efficient retrieval by recency and relevance | MUST |
| WM-06 | Support marking items for consolidation | SHOULD |
| WM-07 | Emit telemetry events for monitoring | SHOULD |
| WM-08 | Support session-scoped working memory | COULD |

### Non-Functional Requirements

| ID | Requirement | Target |
|----|-------------|--------|
| WM-NFR-01 | Read latency | < 5ms p99 |
| WM-NFR-02 | Write latency | < 10ms p99 |
| WM-NFR-03 | Memory footprint | < 50MB for 1000 items |
| WM-NFR-04 | TTL accuracy | ± 1 second |

---

## 🏗️ Architecture

### Component Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                    Working Memory System                     │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────────┐    ┌─────────────────┐                │
│  │  WorkingMemory  │───▶│  ETS Backend    │                │
│  │     (API)       │    │  (In-Memory)    │                │
│  └────────┬────────┘    └─────────────────┘                │
│           │                                                 │
│           │              ┌─────────────────┐                │
│           └─────────────▶│  TTL Cleaner    │                │
│                          │  (GenServer)    │                │
│                          └─────────────────┘                │
│                                                             │
│  Events: [:mimo, :working_memory, :stored|:expired|:evicted]│
└─────────────────────────────────────────────────────────────┘
```

### Data Model

```elixir
# Working Memory Item Structure
%WorkingMemoryItem{
  id: "uuid",
  content: "The actual memory content",
  context: %{
    session_id: "session-123",
    source: "tool_call",           # tool_call | user_message | system
    tool_name: "file_read",        # if from tool
    importance: 0.5,               # 0.0 - 1.0
    tokens: 150                    # estimated token count
  },
  embedding: [0.1, 0.2, ...],      # optional, for semantic search
  created_at: ~U[2025-11-28 10:00:00Z],
  expires_at: ~U[2025-11-28 10:10:00Z],
  accessed_at: ~U[2025-11-28 10:05:00Z],
  consolidation_candidate: false   # marked for transfer to long-term
}
```

### Storage Strategy

**Primary:** ETS table (in-memory, fast access)
- Table name: `:mimo_working_memory`
- Type: `:ordered_set` (allows range queries by time)
- Key: `{expires_at, id}` for efficient TTL cleanup

**Why ETS over SQLite?**
- Sub-millisecond access (no I/O)
- Automatic process cleanup on restart
- Perfect for ephemeral, high-frequency data
- TTL cleanup via simple key range deletion

---

## 📝 Implementation Tasks

### Task 1: Create WorkingMemoryItem Schema
**File:** `lib/mimo/brain/working_memory_item.ex`

```elixir
defmodule Mimo.Brain.WorkingMemoryItem do
  @moduledoc """
  Schema for working memory items.
  Uses embedded schema (not persisted to DB).
  """
  
  use Ecto.Schema
  import Ecto.Changeset
  
  @type t :: %__MODULE__{}
  
  @primary_key {:id, :binary_id, autogenerate: true}
  embedded_schema do
    field :content, :string
    field :context, :map, default: %{}
    field :embedding, {:array, :float}, default: []
    field :importance, :float, default: 0.5
    field :tokens, :integer, default: 0
    field :session_id, :string
    field :source, :string, default: "unknown"
    field :created_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :accessed_at, :utc_datetime
    field :consolidation_candidate, :boolean, default: false
  end
  
  def changeset(item, attrs) do
    item
    |> cast(attrs, [:content, :context, :embedding, :importance, 
                    :tokens, :session_id, :source, :consolidation_candidate])
    |> validate_required([:content])
    |> validate_number(:importance, 
        greater_than_or_equal_to: 0.0, 
        less_than_or_equal_to: 1.0)
    |> set_timestamps()
  end
  
  defp set_timestamps(changeset) do
    now = DateTime.utc_now()
    ttl_seconds = Application.get_env(:mimo_mcp, :working_memory_ttl, 600)
    
    changeset
    |> put_change(:created_at, now)
    |> put_change(:accessed_at, now)
    |> put_change(:expires_at, DateTime.add(now, ttl_seconds, :second))
  end
end
```

---

### Task 2: Create WorkingMemory GenServer
**File:** `lib/mimo/brain/working_memory.ex`

**Acceptance Criteria:**
- [ ] Initialize ETS table on start
- [ ] Implement `store/2` - add item with auto-TTL
- [ ] Implement `get/1` - retrieve by ID, update accessed_at
- [ ] Implement `get_recent/1` - get N most recent items
- [ ] Implement `search/2` - semantic search if embeddings available
- [ ] Implement `mark_for_consolidation/1` - flag items for transfer
- [ ] Implement `get_consolidation_candidates/0` - get flagged items
- [ ] Implement `clear_session/1` - remove all items for a session
- [ ] Implement `stats/0` - return current buffer statistics
- [ ] Handle capacity limits with FIFO eviction
- [ ] Emit telemetry events

**Key Functions:**

```elixir
# Public API
@spec store(content :: String.t(), opts :: keyword()) :: {:ok, id} | {:error, term()}
@spec get(id :: String.t()) :: {:ok, WorkingMemoryItem.t()} | {:error, :not_found}
@spec get_recent(limit :: pos_integer()) :: [WorkingMemoryItem.t()]
@spec search(query :: String.t(), opts :: keyword()) :: [WorkingMemoryItem.t()]
@spec mark_for_consolidation(id :: String.t()) :: :ok | {:error, term()}
@spec get_consolidation_candidates() :: [WorkingMemoryItem.t()]
@spec delete(id :: String.t()) :: :ok
@spec clear_session(session_id :: String.t()) :: :ok
@spec clear_expired() :: {:ok, count :: non_neg_integer()}
@spec stats() :: map()
```

---

### Task 3: Create TTL Cleaner Process
**File:** `lib/mimo/brain/working_memory_cleaner.ex`

**Acceptance Criteria:**
- [ ] Run cleanup every 30 seconds (configurable)
- [ ] Delete expired items from ETS
- [ ] Emit telemetry for expired item count
- [ ] Handle graceful shutdown

```elixir
defmodule Mimo.Brain.WorkingMemoryCleaner do
  use GenServer
  require Logger
  
  @cleanup_interval 30_000  # 30 seconds
  
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  @impl true
  def init(_opts) do
    schedule_cleanup()
    {:ok, %{}}
  end
  
  @impl true
  def handle_info(:cleanup, state) do
    {deleted, _} = Mimo.Brain.WorkingMemory.clear_expired()
    
    if deleted > 0 do
      Logger.debug("Working memory cleaner: removed #{deleted} expired items")
    end
    
    :telemetry.execute(
      [:mimo, :working_memory, :cleanup],
      %{expired_count: deleted},
      %{}
    )
    
    schedule_cleanup()
    {:noreply, state}
  end
  
  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
```

---

### Task 4: Add to Supervision Tree
**File:** `lib/mimo/application.ex`

Add to children list:
```elixir
{Mimo.Brain.WorkingMemory, []},
{Mimo.Brain.WorkingMemoryCleaner, []},
```

---

### Task 5: Integration with AutoMemory
**File:** `lib/mimo/auto_memory.ex`

Modify `wrap_tool_call/3` to store in working memory first:

```elixir
def wrap_tool_call(tool_name, arguments, result) do
  if enabled?() do
    Task.start(fn ->
      try do
        # Store in working memory immediately
        store_to_working_memory(tool_name, arguments, result)
        
        # Optionally also store important items directly to long-term
        if high_importance?(tool_name, result) do
          maybe_store_memory(tool_name, arguments, result)
        end
      rescue
        e -> Logger.warning("AutoMemory failed: #{Exception.message(e)}")
      end
    end)
  end
  result
end

defp store_to_working_memory(tool_name, arguments, result) do
  content = format_memory_content(tool_name, arguments, result)
  
  Mimo.Brain.WorkingMemory.store(content, 
    source: "tool_call",
    tool_name: tool_name,
    importance: calculate_importance(tool_name, result)
  )
end
```

---

### Task 6: Add Configuration
**File:** `config/config.exs`

```elixir
config :mimo_mcp, :working_memory,
  enabled: true,
  ttl_seconds: 600,           # 10 minutes default
  max_items: 100,             # capacity limit
  cleanup_interval: 30_000,   # 30 seconds
  embedding_enabled: false    # enable semantic search in working memory
```

---

### Task 7: Add Telemetry Metrics
**File:** `lib/mimo/telemetry/metrics.ex`

Add metrics:
```elixir
# Working Memory Metrics
counter("mimo.working_memory.stored.total"),
counter("mimo.working_memory.expired.total"),
counter("mimo.working_memory.evicted.total"),
summary("mimo.working_memory.size"),
distribution("mimo.working_memory.item_age",
  buckets: [1, 10, 60, 300, 600]  # seconds
)
```

---

### Task 8: Write Tests
**File:** `test/mimo/brain/working_memory_test.exs`

Test cases:
- [ ] Store and retrieve item
- [ ] TTL expiration works
- [ ] FIFO eviction when over capacity
- [ ] Session clearing
- [ ] Consolidation candidate marking
- [ ] Stats accuracy
- [ ] Concurrent access safety

---

## 🧪 Testing Strategy

### Unit Tests

```elixir
describe "store/2" do
  test "stores item and returns id" do
    {:ok, id} = WorkingMemory.store("test content")
    assert {:ok, item} = WorkingMemory.get(id)
    assert item.content == "test content"
  end
  
  test "evicts oldest when over capacity" do
    # Fill to capacity + 1
    for i <- 1..101 do
      WorkingMemory.store("item #{i}")
    end
    
    assert WorkingMemory.stats().count == 100
  end
  
  test "item expires after TTL" do
    {:ok, id} = WorkingMemory.store("expiring", ttl: 1)
    Process.sleep(1100)
    WorkingMemory.clear_expired()
    assert {:error, :not_found} = WorkingMemory.get(id)
  end
end
```

### Integration Tests

```elixir
describe "AutoMemory integration" do
  test "tool calls are stored in working memory" do
    AutoMemory.wrap_tool_call("file_read", %{"path" => "/test"}, {:ok, "content"})
    Process.sleep(100)  # async storage
    
    recent = WorkingMemory.get_recent(1)
    assert length(recent) == 1
    assert recent |> hd() |> Map.get(:content) =~ "file_read"
  end
end
```

---

## 📊 Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| Storage latency | < 5ms p99 | Telemetry |
| Retrieval latency | < 2ms p99 | Telemetry |
| Memory efficiency | < 50KB/item avg | Profiling |
| TTL accuracy | ± 1 second | Testing |
| Zero data loss | 100% during normal ops | Testing |

---

## 🔗 Dependencies & Interfaces

### Consumes
- None (foundation component)

### Provides
- `Mimo.Brain.WorkingMemory` API for other components
- Consolidation candidates for `Mimo.Brain.Consolidator`

### Events Emitted
- `[:mimo, :working_memory, :stored]`
- `[:mimo, :working_memory, :retrieved]`
- `[:mimo, :working_memory, :expired]`
- `[:mimo, :working_memory, :evicted]`
- `[:mimo, :working_memory, :cleanup]`

---

## 📚 References

- [Memory MCP Research Document](../references/research%20abt%20memory%20mcp.pdf)
- [ETS Documentation](https://www.erlang.org/doc/man/ets.html)
- [Human Working Memory Models](https://en.wikipedia.org/wiki/Working_memory)
