# AI Agent Prompt: Hybrid Retrieval System

## 🎯 Mission

You are implementing the Hybrid Retrieval System for Mimo MCP. This component improves memory search by combining semantic similarity with recency, importance, and access patterns into a unified relevance score.

## 📋 Context

**Project:** Mimo MCP (Elixir-based MCP server with memory capabilities)
**Workspace:** `/workspace/mrc-server/mimo-mcp`
**Spec Document:** `docs/specs/004-hybrid-retrieval.md`
**Dependencies:** SPEC-003 (access_count and last_accessed_at fields)

### Existing Architecture
- Vector search: `Mimo.Brain.Memory.search_memories/2`
- Schema: `Mimo.Brain.Engram` with importance, access_count, last_accessed_at
- Tool registry: `Mimo.ToolRegistry` for MCP tools

## 🔧 Implementation Requirements

### Files to Create

1. **`lib/mimo/brain/hybrid_scorer.ex`**
   - Pure module for score calculations
   - Presets: balanced, semantic, recent, important, popular
   - `calculate_score/2` - Compute final score
   - `rank/2` - Sort results by hybrid score
   - Formula: `w_semantic×similarity + w_recency×recency + w_importance×importance + w_access×access`

2. **`lib/mimo/brain/hybrid_retriever.ex`**
   - High-level search API
   - `search/2` - Hybrid search with options
   - `recent/1` - Recency-optimized query
   - `important/1` - Importance-filtered query
   - `popular/1` - Access-count sorted query
   - Pre-filtering, vector search, enrichment, ranking pipeline

3. **`test/mimo/brain/hybrid_scorer_test.exs`**
   - Test score calculation
   - Test presets
   - Test ranking

4. **`test/mimo/brain/hybrid_retriever_test.exs`**
   - Test search with presets
   - Test filters
   - Test result ordering

### Files to Modify

1. **`lib/mimo/brain/memory.ex`**
   - Add `hybrid_search/2` wrapper function

2. **`lib/mimo/tool_registry.ex`**
   - Add or update search tool with preset option

3. **`lib/mimo/telemetry/metrics.ex`**
   - Add hybrid search metrics

## ⚙️ Technical Specifications

### Scoring Formula

```elixir
# Default weights for balanced preset
%{semantic: 0.5, recency: 0.2, importance: 0.2, access: 0.1}

# Score calculation
final_score = 
  weights.semantic * similarity +
  weights.recency * recency_score +
  weights.importance * importance +
  weights.access * access_score

# Recency score (recent = higher)
recency_score = :math.exp(-0.1 * age_in_days)

# Access score (more accesses = higher, capped)
access_score = min(1.0, :math.log(1 + access_count) / 5)
```

### Presets

```elixir
@presets %{
  balanced:  %{semantic: 0.5, recency: 0.2, importance: 0.2, access: 0.1},
  semantic:  %{semantic: 0.8, recency: 0.1, importance: 0.1, access: 0.0},
  recent:    %{semantic: 0.3, recency: 0.5, importance: 0.1, access: 0.1},
  important: %{semantic: 0.3, recency: 0.1, importance: 0.5, access: 0.1},
  popular:   %{semantic: 0.3, recency: 0.1, importance: 0.1, access: 0.5}
}
```

### Search Pipeline

```elixir
def search(query, opts) do
  # 1. Pre-filter: Get candidate IDs matching category/date filters
  candidate_ids = get_filtered_candidate_ids(opts)
  
  # 2. Vector search: Get semantically similar results (3x limit)
  candidates = Memory.search_memories(query, 
    limit: limit * 3,
    track_access: false
  )
  
  # 3. Apply pre-filter if exists
  filtered = if candidate_ids, 
    do: Enum.filter(candidates, & &1.id in candidate_ids),
    else: candidates
  
  # 4. Enrich: Add access_count and last_accessed_at
  enriched = enrich_with_access_data(filtered)
  
  # 5. Rank: Apply hybrid scoring
  ranked = HybridScorer.rank(enriched, weights)
  
  # 6. Return top results
  Enum.take(ranked, limit)
end
```

### API Design

```elixir
# Main search function
@spec search(String.t(), keyword()) :: list(map())

# Options:
# - :limit (integer) - Max results, default 10
# - :preset (atom) - :balanced, :semantic, :recent, :important, :popular
# - :weights (map) - Custom weights, overrides preset
# - :category (string) - Filter by category
# - :since (NaiveDateTime) - Only after this time
# - :until (NaiveDateTime) - Only before this time
# - :min_similarity (float) - Minimum vector similarity
# - :track_access (boolean) - Update access stats

# Return format - list of maps with :final_score added:
[
  %{
    id: 1,
    content: "...",
    category: "fact",
    importance: 0.8,
    similarity: 0.75,
    access_count: 5,
    last_accessed_at: ~N[2025-11-28 10:00:00],
    final_score: 0.72
  },
  ...
]
```

## ✅ Acceptance Criteria

### Must Pass
- [ ] `mix test test/mimo/brain/hybrid_scorer_test.exs` passes
- [ ] `mix test test/mimo/brain/hybrid_retriever_test.exs` passes
- [ ] Results sorted by final_score descending
- [ ] Different presets produce different rankings
- [ ] Category filter works correctly
- [ ] Date filters work correctly
- [ ] Access tracking on final results
- [ ] Search latency < 50ms for normal queries

### Quality Gates
- [ ] No compiler warnings
- [ ] All public functions have @doc and @spec
- [ ] Telemetry events fire

## 🚫 Constraints

1. **REQUIRES** access tracking fields from SPEC-003
2. **DO NOT** modify existing `Memory.search_memories/2` behavior
3. **DO NOT** block on enrichment - use batch queries
4. **MUST** use existing vector search as foundation
5. **MUST** track access asynchronously

## 📝 Implementation Order

1. Create `HybridScorer` with presets and scoring
2. Write HybridScorer tests
3. Create `HybridRetriever` with basic search
4. Add filtering support
5. Add enrichment pipeline
6. Write HybridRetriever tests
7. Add `hybrid_search/2` to Memory module
8. Add telemetry
9. Update/add MCP tool
10. Final testing

## 🔍 Verification Commands

```bash
# Run tests
mix test test/mimo/brain/hybrid_scorer_test.exs
mix test test/mimo/brain/hybrid_retriever_test.exs

# Interactive testing
iex -S mix

# Create test data
iex> Mimo.Brain.Memory.persist_memory("Important project note", "fact", 0.9)
iex> Mimo.Brain.Memory.persist_memory("Old meeting notes", "observation", 0.3)
iex> Mimo.Brain.Memory.persist_memory("Frequently used info", "fact", 0.5)

# Test hybrid search
iex> alias Mimo.Brain.HybridRetriever
iex> HybridRetriever.search("project")
iex> HybridRetriever.search("project", preset: :recent)
iex> HybridRetriever.search("project", preset: :important)
iex> HybridRetriever.search("notes", category: "observation")

# Test scoring
iex> alias Mimo.Brain.HybridScorer
iex> HybridScorer.calculate_score(%{similarity: 0.8, importance: 0.5}, :balanced)
iex> HybridScorer.preset_weights(:semantic)
```

## 💡 Tips

- Use `:math.exp/1` for exponential decay
- Use `:math.log/1` for logarithmic scaling
- Batch database queries for enrichment (single query for all IDs)
- Use MapSet for efficient ID filtering
- The candidate_multiplier (3x) ensures enough results for re-ranking
- Track access using Task.start to avoid blocking

## 🎬 Start Here

1. Read `docs/specs/004-hybrid-retrieval.md` fully
2. Verify SPEC-003 fields exist (access_count, last_accessed_at)
3. Create `HybridScorer` with presets
4. Test scoring interactively
5. Create `HybridRetriever`
6. Write comprehensive tests
