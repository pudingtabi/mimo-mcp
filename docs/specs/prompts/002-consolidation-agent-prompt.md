# AI Agent Prompt: Memory Consolidation System

## 🎯 Mission

You are implementing the Memory Consolidation System for Mimo MCP. This is a CRITICAL component that processes working memory and transfers important items to long-term storage, mimicking biological memory consolidation during sleep.

## 📋 Context

**Project:** Mimo MCP (Elixir-based MCP server with memory capabilities)
**Workspace:** `/workspace/mrc-server/mimo-mcp`
**Spec Document:** `docs/specs/002-memory-consolidation.md`
**Dependency:** SPEC-001 (Working Memory Buffer) must be implemented first

### Existing Architecture
- Working Memory: `Mimo.Brain.WorkingMemory` (from SPEC-001)
- Long-term Memory: `Mimo.Brain.Memory` with `persist_memory/3`
- Semantic Store: `Mimo.SemanticStore.Repository` for triples
- LLM: `Mimo.Brain.LLM.complete/2` for optional triple extraction

### Key Files to Reference
- `lib/mimo/brain/working_memory.ex` - Source of consolidation candidates
- `lib/mimo/brain/memory.ex` - Long-term storage target
- `lib/mimo/semantic_store/repository.ex` - Triple creation
- `lib/mimo/brain/llm.ex` - LLM integration patterns

## 🔧 Implementation Requirements

### Files to Create

1. **`lib/mimo/brain/consolidator.ex`**
   - GenServer with scheduled consolidation
   - Public API:
     - `consolidate_now/0` - Trigger immediate consolidation
     - `status/0` - Current state (idle/running)
     - `stats/0` - Consolidation statistics
   - Pipeline:
     1. Gather candidates from WorkingMemory
     2. Filter and dedupe (Jaro distance > 0.85 = duplicate)
     3. Persist to Brain.Memory
     4. Link related memories via SemanticStore
     5. Optionally extract semantic triples via LLM
     6. Cleanup consolidated items from WorkingMemory
   - Emit telemetry events
   - Handle failures gracefully (don't crash)

2. **`test/mimo/brain/consolidator_test.exs`**
   - Test scheduled execution
   - Test manual trigger
   - Test deduplication
   - Test linking
   - Test failure recovery

### Files to Modify

1. **`lib/mimo/application.ex`**
   - Add `{Mimo.Brain.Consolidator, []}` after WorkingMemory

2. **`config/config.exs`**
   - Add `:consolidation` configuration block

3. **`lib/mimo/telemetry/metrics.ex`**
   - Add consolidation metrics

4. **`lib/mimo/tool_registry.ex`** (Optional)
   - Add `consolidate_memory` tool for manual trigger

## ⚙️ Technical Specifications

### Consolidation Pipeline Steps

```elixir
def run_consolidation(state) do
  # 1. Gather candidates from working memory
  candidates = gather_candidates()
  #    - Get items marked for consolidation
  #    - Get high-importance items (>= 0.4)
  #    - Dedupe by ID
  
  # 2. Filter near-duplicates
  filtered = filter_and_dedupe(candidates)
  #    - Use String.jaro_distance > 0.85 as duplicate threshold
  
  # 3. Persist to long-term storage
  {persisted, failed} = persist_memories(filtered)
  #    - Call Memory.persist_memory/3 for each
  #    - Track engram_id for linking
  
  # 4. Link related memories
  links_created = link_related_memories(persisted)
  #    - Search existing memories by similarity
  #    - Create "related_to" triples in SemanticStore
  
  # 5. Extract semantic triples (if enabled)
  triples_created = extract_and_store_triples(persisted)
  #    - Use LLM to extract subject-predicate-object
  #    - Store in SemanticStore
  
  # 6. Cleanup consolidated items
  cleanup_consolidated(persisted)
  #    - Delete from WorkingMemory
end
```

### Configuration Schema

```elixir
config :mimo_mcp, :consolidation,
  enabled: true,
  interval_ms: 300_000,        # 5 minutes
  min_importance: 0.4,         # Minimum importance to consolidate
  batch_size: 50,              # Process N items per cycle
  link_threshold: 0.7,         # Similarity threshold for linking
  extract_triples: true        # Extract semantic triples (LLM cost)
```

### Telemetry Events

```elixir
# On start
:telemetry.execute([:mimo, :consolidation, :started], %{}, %{})

# On completion
:telemetry.execute(
  [:mimo, :consolidation, :completed],
  %{
    duration_ms: duration,
    persisted_count: count,
    links_count: links,
    triples_count: triples
  },
  %{}
)

# On failure
:telemetry.execute(
  [:mimo, :consolidation, :failed],
  %{count: 1},
  %{error: error_message}
)
```

### Linking Related Memories

```elixir
defp link_related_memories(persisted) do
  threshold = 0.7  # from config
  
  Enum.reduce(persisted, 0, fn item, count ->
    # Find similar existing memories
    related = Memory.search_memories(item.content, 
      limit: 5, 
      min_similarity: threshold
    )
    
    # Create links (exclude self)
    links = related
    |> Enum.reject(& &1.id == item.engram_id)
    |> Enum.map(fn related_item ->
      Repository.create(%{
        subject_id: to_string(item.engram_id),
        subject_type: "engram",
        predicate: "related_to",
        object_id: to_string(related_item.id),
        object_type: "engram",
        confidence: related_item.similarity,
        source: "consolidation"
      })
    end)
    
    count + Enum.count(links, &match?({:ok, _}, &1))
  end)
end
```

### Triple Extraction (Optional)

```elixir
defp extract_triples(content) do
  prompt = """
  Extract factual relationships from this text as JSON triples.
  Format: [{"subject": "...", "predicate": "...", "object": "..."}]
  Only extract clear, factual relationships. Return [] if none found.
  
  Text: #{content}
  """
  
  case Mimo.Brain.LLM.complete(prompt, format: :json, max_tokens: 500) do
    {:ok, json} -> Jason.decode(json)
    error -> error
  end
end
```

## ✅ Acceptance Criteria

### Must Pass
- [ ] `mix test test/mimo/brain/consolidator_test.exs` passes
- [ ] Consolidation runs on configured schedule
- [ ] `Consolidator.consolidate_now/0` works
- [ ] High-importance items transferred to long-term storage
- [ ] Near-duplicates filtered out
- [ ] Related memories linked via SemanticStore
- [ ] Consolidated items removed from WorkingMemory
- [ ] Failures don't crash the process
- [ ] Telemetry events fire correctly

### Quality Gates
- [ ] No compiler warnings
- [ ] Consolidation completes in < 30s for 100 items
- [ ] Main request path not blocked during consolidation
- [ ] Stats accurately reflect operations

## 🚫 Constraints

1. **REQUIRES** Working Memory (SPEC-001) to be implemented first
2. **DO NOT** block the main request path
3. **DO NOT** crash on individual item failures (continue processing)
4. **DO NOT** make LLM calls mandatory (triple extraction should be optional)
5. **MUST** use existing `Memory.persist_memory/3` for storage
6. **MUST** use existing `Repository.create/1` for triples

## 📝 Implementation Order

1. Create `Consolidator` GenServer skeleton with schedule
2. Implement `gather_candidates/0`
3. Implement `filter_and_dedupe/1`
4. Implement `persist_memories/1`
5. Add to supervision tree, verify starts
6. Implement `link_related_memories/1`
7. Implement `extract_and_store_triples/1` (optional feature)
8. Implement `cleanup_consolidated/1`
9. Add telemetry
10. Write tests
11. Add configuration
12. Final testing

## 🔍 Verification Commands

```bash
# Compile check
mix compile --warnings-as-errors

# Run specific tests
mix test test/mimo/brain/consolidator_test.exs

# Interactive testing
iex -S mix

# Add some working memory items
iex> Mimo.Brain.WorkingMemory.store("User prefers dark mode", importance: 0.8)
iex> Mimo.Brain.WorkingMemory.store("Project uses Elixir", importance: 0.9)

# Trigger consolidation
iex> Mimo.Brain.Consolidator.consolidate_now()

# Check results
iex> Mimo.Brain.Consolidator.stats()
iex> Mimo.Brain.Memory.search_memories("dark mode")
iex> Mimo.Brain.WorkingMemory.stats()  # Should show fewer items
```

## 💡 Tips

- The `filter_and_dedupe/1` function should be efficient - avoid O(n²) if possible
- Use `String.jaro_distance/2` for fuzzy matching (returns 0.0-1.0)
- The LLM extraction is expensive - make it configurable and optional
- Consider batching LLM calls if extracting many triples
- Test with `Process.sleep/1` to verify schedule timing
- Use `try/rescue` around each item processing to prevent cascade failures

## 🎬 Start Here

1. Read `docs/specs/002-memory-consolidation.md` fully
2. Verify SPEC-001 (WorkingMemory) is implemented
3. Create `lib/mimo/brain/consolidator.ex` skeleton
4. Implement basic gather → persist → cleanup flow
5. Add to supervision tree
6. Test interactively with `iex -S mix`
7. Add linking and triple extraction
8. Write comprehensive tests
