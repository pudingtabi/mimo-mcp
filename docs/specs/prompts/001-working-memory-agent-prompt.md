# AI Agent Prompt: Working Memory Buffer Implementation

## 🎯 Mission

You are implementing the Working Memory Buffer system for Mimo MCP. This is a CRITICAL foundational component that provides short-lived, in-memory storage for active context during AI interactions.

## 📋 Context

**Project:** Mimo MCP (Elixir-based MCP server with memory capabilities)
**Workspace:** `/workspace/mrc-server/mimo-mcp`
**Spec Document:** `docs/specs/001-working-memory-buffer.md`

### Existing Architecture
- Memory system uses `Mimo.Brain.Memory` for long-term storage (SQLite + Ecto)
- `Mimo.Brain.Engram` is the schema for persistent memories
- `Mimo.AutoMemory` captures tool interactions automatically
- Telemetry is configured in `lib/mimo/telemetry.ex` and `lib/mimo/telemetry/metrics.ex`
- Supervision tree is in `lib/mimo/application.ex`

### Key Files to Reference
- `lib/mimo/brain/memory.ex` - Existing memory implementation
- `lib/mimo/brain/engram.ex` - Memory schema pattern
- `lib/mimo/auto_memory.ex` - Where to integrate
- `lib/mimo/application.ex` - Supervision tree
- `config/config.exs` - Configuration patterns

## 🔧 Implementation Requirements

### Files to Create

1. **`lib/mimo/brain/working_memory_item.ex`**
   - Embedded Ecto schema (NOT persisted to DB)
   - Fields: id, content, context, embedding, importance, tokens, session_id, source, created_at, expires_at, accessed_at, consolidation_candidate
   - Changeset with validation
   - Auto-set timestamps with TTL calculation

2. **`lib/mimo/brain/working_memory.ex`**
   - GenServer managing ETS table
   - Public API functions:
     - `store/2` - Store content with options (importance, session_id, source, ttl)
     - `get/1` - Retrieve by ID, update accessed_at
     - `get_recent/1` - Get N most recent items
     - `search/2` - Search by query (simple text match, or semantic if embeddings enabled)
     - `mark_for_consolidation/1` - Flag for transfer to long-term
     - `get_consolidation_candidates/0` - Get all flagged items
     - `delete/1` - Remove specific item
     - `clear_session/1` - Clear all items for a session
     - `clear_expired/0` - Remove expired items
     - `stats/0` - Return buffer statistics
   - ETS table: `:mimo_working_memory`, type `:ordered_set`
   - Handle capacity limits with FIFO eviction
   - Emit telemetry events on all operations

3. **`lib/mimo/brain/working_memory_cleaner.ex`**
   - GenServer that runs periodic cleanup
   - Default interval: 30 seconds
   - Calls `WorkingMemory.clear_expired/0`
   - Emits telemetry for monitoring

4. **`test/mimo/brain/working_memory_test.exs`**
   - Comprehensive tests for all public functions
   - Test TTL expiration
   - Test FIFO eviction
   - Test concurrent access
   - Test telemetry emissions

### Files to Modify

1. **`lib/mimo/application.ex`**
   - Add `{Mimo.Brain.WorkingMemory, []}` to children
   - Add `{Mimo.Brain.WorkingMemoryCleaner, []}` to children
   - Position AFTER Repo but BEFORE other memory components

2. **`lib/mimo/auto_memory.ex`**
   - Add `store_to_working_memory/3` function
   - Modify `wrap_tool_call/3` to store in working memory first
   - Only persist to long-term if importance > threshold

3. **`config/config.exs`**
   - Add `:working_memory` configuration block

4. **`lib/mimo/telemetry/metrics.ex`**
   - Add working memory metrics (stored, expired, evicted, size)

## ⚙️ Technical Specifications

### ETS Table Design

```elixir
# Table creation
:ets.new(:mimo_working_memory, [
  :ordered_set,           # Allows efficient range queries
  :public,                # Accessible from any process
  :named_table,
  read_concurrency: true,
  write_concurrency: true
])

# Key structure: {expires_at_unix, id}
# This allows efficient cleanup: delete all keys where first element < now

# Value structure: WorkingMemoryItem struct (full item)
```

### Configuration Schema

```elixir
config :mimo_mcp, :working_memory,
  enabled: true,
  ttl_seconds: 600,           # 10 minutes
  max_items: 100,             # Max buffer size
  cleanup_interval_ms: 30_000, # Cleanup every 30s
  embedding_enabled: false     # Semantic search in working memory
```

### Telemetry Events

```elixir
# On store
:telemetry.execute([:mimo, :working_memory, :stored], %{count: 1}, %{
  source: source,
  importance: importance,
  session_id: session_id
})

# On retrieve
:telemetry.execute([:mimo, :working_memory, :retrieved], %{count: 1}, %{
  age_ms: age_in_ms
})

# On expire
:telemetry.execute([:mimo, :working_memory, :expired], %{count: expired_count}, %{})

# On evict (capacity)
:telemetry.execute([:mimo, :working_memory, :evicted], %{count: evicted_count}, %{
  reason: :capacity
})
```

## ✅ Acceptance Criteria

### Must Pass
- [ ] `mix test test/mimo/brain/working_memory_test.exs` passes
- [ ] Items expire after TTL
- [ ] FIFO eviction when over capacity
- [ ] `WorkingMemory.stats()` returns accurate counts
- [ ] Telemetry events fire correctly
- [ ] Application starts without errors
- [ ] No memory leaks under sustained load

### Quality Gates
- [ ] No compiler warnings
- [ ] Dialyzer passes (if configured)
- [ ] Code follows existing project patterns
- [ ] All public functions have @doc and @spec

## 🚫 Constraints

1. **DO NOT** modify `Mimo.Brain.Memory` or `Mimo.Brain.Engram`
2. **DO NOT** add database migrations (ETS only)
3. **DO NOT** block on embeddings - make them optional
4. **DO NOT** change existing tests
5. **MUST** use ETS for storage (not GenServer state)
6. **MUST** handle process restarts gracefully (data loss is acceptable)

## 📝 Implementation Order

1. Create `WorkingMemoryItem` schema
2. Create `WorkingMemory` GenServer with basic store/get
3. Add to supervision tree, verify starts
4. Implement capacity limits and eviction
5. Create `WorkingMemoryCleaner`
6. Add telemetry
7. Write tests
8. Integrate with `AutoMemory`
9. Add configuration
10. Final testing and cleanup

## 🔍 Verification Commands

```bash
# Compile check
mix compile --warnings-as-errors

# Run specific tests
mix test test/mimo/brain/working_memory_test.exs

# Run all tests
mix test

# Check for dialyzer issues (if configured)
mix dialyzer

# Interactive testing
iex -S mix
iex> Mimo.Brain.WorkingMemory.store("test content")
iex> Mimo.Brain.WorkingMemory.stats()
iex> Mimo.Brain.WorkingMemory.get_recent(5)
```

## 💡 Tips

- Look at `Mimo.Cache.Classifier` for ETS usage patterns in this codebase
- The existing `Mimo.Brain.Memory.search_memories/2` shows streaming patterns
- Use `Task.start/1` for async operations (like in AutoMemory)
- Follow the telemetry patterns in `lib/mimo/telemetry.ex`
- Test with `Process.sleep/1` for TTL expiration tests

## 🎬 Start Here

1. Read `docs/specs/001-working-memory-buffer.md` fully
2. Examine `lib/mimo/brain/memory.ex` for patterns
3. Create `lib/mimo/brain/working_memory_item.ex`
4. Create `lib/mimo/brain/working_memory.ex` with basic functionality
5. Test interactively with `iex -S mix`
6. Iterate until all acceptance criteria pass
