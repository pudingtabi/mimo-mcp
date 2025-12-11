# AI Agent Prompt: Unified Memory Router

## 🎯 Mission

You are implementing the Unified Memory Router for Mimo MCP. This component provides a single entry point for all memory operations, automatically routing queries to the appropriate memory stores and merging results.

## 📋 Context

**Project:** Mimo MCP (Elixir-based MCP server with memory capabilities)
**Workspace:** `/workspace/mrc-server/mimo-mcp`
**Spec Document:** `docs/specs/005-memory-router.md`
**Dependencies:** SPEC-001 through SPEC-004 (integrates all memory systems)

### Memory Stores to Integrate
- **Working Memory** - `Mimo.Brain.WorkingMemory` (SPEC-001)
- **Episodic Memory** - `Mimo.Brain.HybridRetriever` (SPEC-004)
- **Semantic Store** - `Mimo.SemanticStore.Query`
- **Procedural Store** - `Mimo.Skills.HotReload`

### Key Files to Reference
- `lib/mimo/brain/working_memory.ex`
- `lib/mimo/brain/hybrid_retriever.ex`
- `lib/mimo/semantic_store/query.ex`
- `lib/mimo/brain/classifier.ex` - For query intent classification
- `lib/mimo/skills/hot_reload.ex`

## 🔧 Implementation Requirements

### Files to Create

1. **`lib/mimo/brain/memory_router.ex`**
   - Main router module
   - `query/2` - Unified query with auto-routing
   - `working/2` - Query working memory
   - `episodic/2` - Query episodic (Engrams)
   - `semantic/2` - Query knowledge graph
   - `procedural/2` - Query skills/procedures
   - `store/2` - Unified storage with type routing
   - Query classification using existing Classifier
   - Parallel queries to multiple stores
   - Result merging and ranking

2. **`test/mimo/brain/memory_router_test.exs`**
   - Test auto-routing
   - Test explicit store selection
   - Test result merging
   - Test storage routing

### Files to Modify

1. **`lib/mimo/tool_registry.ex`**
   - Add `query_memory` unified tool

2. **`lib/mimo/ports/tool_interface.ex`**
   - Add handler for `query_memory` tool

3. **`lib/mimo/telemetry/metrics.ex`**
   - Add router metrics

## ⚙️ Technical Specifications

### Query Routing Logic

```elixir
# Auto-classify query intent using existing Classifier
defp classify_query(query_text) do
  case Classifier.classify(query_text) do
    {:ok, :graph, _} -> [:semantic, :episodic]
    {:ok, :vector, _} -> [:episodic, :working]
    {:ok, :hybrid, _} -> [:episodic, :semantic]
    _ -> [:episodic]  # Default
  end
end
```

### Parallel Query Execution

```elixir
# Query multiple stores in parallel
results = 
  stores
  |> Enum.map(fn store ->
    Task.async(fn -> query_store(store, query_text, limit) end)
  end)
  |> Task.await_many(5000)
  |> List.flatten()
```

### Result Format

```elixir
%{
  source: :episodic | :working | :semantic | :procedural,
  content: "The actual content",
  score: 0.85,  # Relevance score (0-1)
  metadata: %{
    id: "uuid",
    category: "fact",
    # Store-specific metadata
  }
}
```

### API Design

```elixir
# Main query API
@spec query(String.t(), keyword()) :: {:ok, [result()]} | {:error, term()}
def query(query_text, opts \\ [])

# Options:
# - :stores - [:working, :episodic, :semantic, :procedural] or auto-detect
# - :limit - Max results per store (default: 5)
# - :merge - Merge and rank results (default: true)

# Store-specific queries
@spec working(String.t(), keyword()) :: [result()]
@spec episodic(String.t(), keyword()) :: [result()]
@spec semantic(String.t(), keyword()) :: [result()]
@spec procedural(String.t(), keyword()) :: [result()]

# Unified storage
@spec store(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
# Options:
# - :type - :working | :episodic | :semantic (required)
# - :importance - For episodic (default: 0.5)
# - :category - For episodic (default: "fact")
```

### Semantic Query Parsing

```elixir
# Support special query patterns
defp parse_semantic_query(query) do
  cond do
    # Entity lookup: "who:Alice"
    String.starts_with?(query, "who:") ->
      entity = String.replace_prefix(query, "who:", "") |> String.trim()
      {:entity, entity}
      
    # Relationship: "Alice -> manages"
    String.contains?(query, "->") ->
      [subject, predicate] = String.split(query, "->", parts: 2)
      {:relationship, String.trim(subject), String.trim(predicate)}
      
    true ->
      :natural  # Fall back to natural language
  end
end
```

## ✅ Acceptance Criteria

### Must Pass
- [ ] `mix test test/mimo/brain/memory_router_test.exs` passes
- [ ] Auto-routing works based on query intent
- [ ] Explicit store selection works
- [ ] Results from multiple stores merged correctly
- [ ] Scores sorted descending
- [ ] Storage routes to correct store
- [ ] MCP tool works

### Quality Gates
- [ ] No compiler warnings
- [ ] Query overhead < 10ms
- [ ] All public functions have @doc and @spec

## 🚫 Constraints

1. **REQUIRES** SPEC-001 to SPEC-004 to be implemented
2. **DO NOT** duplicate query logic - delegate to existing modules
3. **DO NOT** block on slow stores - use timeouts
4. **MUST** use Task.async for parallel queries
5. **MUST** handle store failures gracefully (return empty, don't crash)

## 📝 Implementation Order

1. Create `MemoryRouter` skeleton
2. Implement store-specific query functions
3. Implement `query/2` with auto-routing
4. Implement parallel execution
5. Implement result merging
6. Implement `store/2`
7. Write tests
8. Add MCP tool
9. Add telemetry
10. Final testing

## 🔍 Verification Commands

```bash
# Run tests
mix test test/mimo/brain/memory_router_test.exs

# Interactive testing
iex -S mix

# Test auto-routing
iex> alias Mimo.Brain.MemoryRouter
iex> MemoryRouter.query("tell me about the project")
iex> MemoryRouter.query("who:Alice")
iex> MemoryRouter.query("What happened recently?")

# Test explicit stores
iex> MemoryRouter.query("test", stores: [:working, :episodic])

# Test storage
iex> MemoryRouter.store("New fact", type: :episodic, importance: 0.8)
iex> MemoryRouter.store("Active context", type: :working)

# Test individual stores
iex> MemoryRouter.working("recent")
iex> MemoryRouter.episodic("project")
iex> MemoryRouter.semantic("who:Alice")
```

## 💡 Tips

- Use `Task.async/1` and `Task.await_many/2` for parallel queries
- Set reasonable timeouts (5000ms) to handle slow stores
- Use `rescue` blocks in task functions to prevent crashes
- The existing `Classifier.classify/1` returns `:graph`, `:vector`, or `:hybrid`
- Keep result format consistent across all stores

## 🎬 Start Here

1. Read `docs/specs/005-memory-router.md` fully
2. Verify all dependent specs are implemented
3. Create `MemoryRouter` with store-specific functions first
4. Test individual stores work
5. Add `query/2` with auto-routing
6. Add result merging
7. Write comprehensive tests
