# SPEC-004: Hybrid Retrieval System

## 📋 Overview

**Status:** Not Started  
**Priority:** MEDIUM  
**Estimated Effort:** 2-3 days  
**Dependencies:** SPEC-003 (for access tracking fields)

### Purpose

Implement a multi-factor retrieval system that combines semantic similarity with recency, importance, and access patterns to return the most relevant memories. This improves on pure vector search by considering multiple relevance signals.

### Research Foundation

From the Memory MCP research document:
- Pure semantic similarity isn't enough
- Recent memories should be weighted higher
- Frequently accessed memories are likely more relevant
- Different query types need different ranking strategies
- Hybrid scoring combines multiple signals

---

## 🎯 Requirements

### Functional Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| HR-01 | Combine semantic similarity with recency scoring | MUST |
| HR-02 | Factor in importance when ranking | MUST |
| HR-03 | Factor in access patterns (count, recency) | SHOULD |
| HR-04 | Support different ranking strategies/presets | SHOULD |
| HR-05 | Allow custom weight configuration | SHOULD |
| HR-06 | Filter by category before scoring | MUST |
| HR-07 | Support temporal queries (recent, historical) | COULD |
| HR-08 | Emit telemetry for retrieval performance | SHOULD |

### Non-Functional Requirements

| ID | Requirement | Target |
|----|-------------|--------|
| HR-NFR-01 | Retrieval latency | < 50ms p99 |
| HR-NFR-02 | Ranking overhead | < 10ms |
| HR-NFR-03 | Memory efficiency | Stream-based |

---

## 🏗️ Architecture

### Hybrid Scoring Formula

```
final_score = (w_semantic × semantic_similarity) +
              (w_recency × recency_score) +
              (w_importance × importance) +
              (w_access × access_score)

where:
  recency_score = e^(-0.1 × age_in_days)
  access_score = min(1.0, log(1 + access_count) / 5)
  
Default weights:
  w_semantic = 0.5
  w_recency = 0.2
  w_importance = 0.2
  w_access = 0.1
```

### Ranking Presets

| Preset | Semantic | Recency | Importance | Access | Use Case |
|--------|----------|---------|------------|--------|----------|
| `balanced` | 0.5 | 0.2 | 0.2 | 0.1 | General queries |
| `semantic` | 0.8 | 0.1 | 0.1 | 0.0 | Pure similarity |
| `recent` | 0.3 | 0.5 | 0.1 | 0.1 | What happened recently |
| `important` | 0.3 | 0.1 | 0.5 | 0.1 | Critical info |
| `popular` | 0.3 | 0.1 | 0.1 | 0.5 | Frequently accessed |

### Component Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                    Hybrid Retrieval System                   │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Query ──▶ ┌────────────────┐                               │
│            │ Pre-Filter     │ (category, date range)        │
│            └───────┬────────┘                               │
│                    ▼                                        │
│            ┌────────────────┐                               │
│            │ Vector Search  │ (semantic similarity)         │
│            └───────┬────────┘                               │
│                    ▼                                        │
│            ┌────────────────┐                               │
│            │ Hybrid Scorer  │ (multi-factor ranking)        │
│            └───────┬────────┘                               │
│                    ▼                                        │
│            ┌────────────────┐                               │
│            │ Re-Ranker      │ (final sort + limit)          │
│            └───────┬────────┘                               │
│                    ▼                                        │
│            Results (sorted by final_score)                  │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 📝 Implementation Tasks

### Task 1: Create Hybrid Scorer Module
**File:** `lib/mimo/brain/hybrid_scorer.ex`

```elixir
defmodule Mimo.Brain.HybridScorer do
  @moduledoc """
  Multi-factor scoring for memory retrieval.
  
  Combines semantic similarity, recency, importance, and access patterns
  into a single relevance score.
  
  ## Presets
  
  - `:balanced` - Equal weight to all factors
  - `:semantic` - Prioritize semantic match
  - `:recent` - Prioritize recent memories
  - `:important` - Prioritize high-importance memories
  - `:popular` - Prioritize frequently accessed memories
  """
  
  @presets %{
    balanced: %{semantic: 0.5, recency: 0.2, importance: 0.2, access: 0.1},
    semantic: %{semantic: 0.8, recency: 0.1, importance: 0.1, access: 0.0},
    recent: %{semantic: 0.3, recency: 0.5, importance: 0.1, access: 0.1},
    important: %{semantic: 0.3, recency: 0.1, importance: 0.5, access: 0.1},
    popular: %{semantic: 0.3, recency: 0.1, importance: 0.1, access: 0.5}
  }
  
  @type weights :: %{
    semantic: float(),
    recency: float(),
    importance: float(),
    access: float()
  }
  
  @doc """
  Get weights for a preset.
  """
  @spec preset_weights(atom()) :: weights()
  def preset_weights(preset) when is_atom(preset) do
    Map.get(@presets, preset, @presets.balanced)
  end
  
  @doc """
  Calculate final score for a memory result.
  
  ## Parameters
  
  - `result` - Memory with :similarity, :importance, :access_count, :last_accessed_at
  - `weights` - Weight map or preset atom
  
  ## Returns
  
  Float between 0.0 and 1.0
  """
  @spec calculate_score(map(), weights() | atom()) :: float()
  def calculate_score(result, preset) when is_atom(preset) do
    calculate_score(result, preset_weights(preset))
  end
  
  def calculate_score(result, weights) when is_map(weights) do
    semantic = Map.get(result, :similarity, 0.0)
    importance = Map.get(result, :importance, 0.5)
    access_count = Map.get(result, :access_count, 0)
    last_accessed = Map.get(result, :last_accessed_at) || 
                    Map.get(result, :inserted_at)
    
    recency = calculate_recency_score(last_accessed)
    access = calculate_access_score(access_count)
    
    score = 
      weights.semantic * semantic +
      weights.recency * recency +
      weights.importance * importance +
      weights.access * access
    
    # Normalize to 0-1 range
    min(1.0, max(0.0, score))
  end
  
  @doc """
  Rank a list of results by hybrid score.
  """
  @spec rank(list(map()), weights() | atom()) :: list(map())
  def rank(results, weights) do
    results
    |> Enum.map(fn r ->
      Map.put(r, :final_score, calculate_score(r, weights))
    end)
    |> Enum.sort_by(& &1.final_score, :desc)
  end
  
  # Recency score: e^(-0.1 * age_in_days)
  defp calculate_recency_score(nil), do: 0.5
  defp calculate_recency_score(datetime) do
    age_days = calculate_age_days(datetime)
    :math.exp(-0.1 * age_days)
  end
  
  # Access score: normalized log of access count
  defp calculate_access_score(count) when count <= 0, do: 0.0
  defp calculate_access_score(count) do
    min(1.0, :math.log(1 + count) / 5)
  end
  
  defp calculate_age_days(datetime) do
    now = NaiveDateTime.utc_now()
    diff_seconds = NaiveDateTime.diff(now, datetime, :second)
    max(0, diff_seconds / 86400.0)
  end
end
```

---

### Task 2: Create Hybrid Retriever
**File:** `lib/mimo/brain/hybrid_retriever.ex`

```elixir
defmodule Mimo.Brain.HybridRetriever do
  @moduledoc """
  High-level API for hybrid memory retrieval.
  
  Wraps the existing Memory.search_memories with pre-filtering,
  hybrid scoring, and re-ranking.
  
  ## Examples
  
      # Balanced retrieval
      HybridRetriever.search("project architecture")
      
      # Recent memories about a topic
      HybridRetriever.search("meetings", preset: :recent)
      
      # Custom weights
      HybridRetriever.search("critical bugs", weights: %{
        semantic: 0.4,
        recency: 0.1,
        importance: 0.4,
        access: 0.1
      })
      
      # With filters
      HybridRetriever.search("user preferences",
        category: "observation",
        since: ~N[2025-11-01 00:00:00]
      )
  """
  require Logger
  
  alias Mimo.Brain.{Memory, HybridScorer}
  import Ecto.Query
  alias Mimo.{Repo, Brain.Engram}
  
  @default_limit 10
  @default_preset :balanced
  @candidate_multiplier 3  # Fetch 3x limit for re-ranking
  
  @doc """
  Search memories with hybrid ranking.
  
  ## Options
  
  - `:limit` - Max results (default: 10)
  - `:preset` - Ranking preset atom (default: :balanced)
  - `:weights` - Custom weights map (overrides preset)
  - `:category` - Filter by category
  - `:since` - Only memories after this datetime
  - `:until` - Only memories before this datetime
  - `:min_similarity` - Minimum semantic similarity (default: 0.3)
  - `:track_access` - Whether to track access (default: true)
  
  ## Returns
  
  List of memory maps with `:final_score` added
  """
  @spec search(String.t(), keyword()) :: list(map())
  def search(query, opts \\ []) do
    start_time = System.monotonic_time(:microsecond)
    
    limit = Keyword.get(opts, :limit, @default_limit)
    preset = Keyword.get(opts, :preset, @default_preset)
    weights = Keyword.get(opts, :weights) || HybridScorer.preset_weights(preset)
    min_similarity = Keyword.get(opts, :min_similarity, 0.3)
    track_access = Keyword.get(opts, :track_access, true)
    
    # Phase 1: Pre-filter candidates from DB
    candidate_ids = get_filtered_candidate_ids(opts, limit * @candidate_multiplier)
    
    # Phase 2: Vector search with pre-filter
    candidates = Memory.search_memories(query,
      limit: limit * @candidate_multiplier,
      min_similarity: min_similarity,
      track_access: false  # We'll track access on final results
    )
    
    # Apply pre-filter if we have candidate IDs
    filtered_candidates = 
      if candidate_ids do
        Enum.filter(candidates, & &1.id in candidate_ids)
      else
        candidates
      end
    
    # Phase 3: Enrich with access data
    enriched = enrich_with_access_data(filtered_candidates)
    
    # Phase 4: Hybrid ranking
    ranked = HybridScorer.rank(enriched, weights)
    
    # Phase 5: Take top results
    results = Enum.take(ranked, limit)
    
    # Track access for final results
    if track_access and length(results) > 0 do
      Task.start(fn -> track_access_async(results) end)
    end
    
    duration = System.monotonic_time(:microsecond) - start_time
    
    :telemetry.execute(
      [:mimo, :memory, :hybrid_search],
      %{duration_us: duration, result_count: length(results)},
      %{preset: preset, query_length: String.length(query)}
    )
    
    results
  end
  
  @doc """
  Get recent memories with optional category filter.
  Optimized for recency-focused queries.
  """
  @spec recent(keyword()) :: list(map())
  def recent(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    category = Keyword.get(opts, :category)
    
    query = 
      from(e in Engram,
        order_by: [desc: e.inserted_at],
        limit: ^limit,
        select: %{
          id: e.id,
          content: e.content,
          category: e.category,
          importance: e.importance,
          access_count: e.access_count,
          last_accessed_at: e.last_accessed_at,
          inserted_at: e.inserted_at
        }
      )
    
    query = if category, do: where(query, [e], e.category == ^category), else: query
    
    Repo.all(query)
    |> Enum.map(& Map.put(&1, :final_score, &1.importance))
  end
  
  @doc """
  Get most important memories.
  """
  @spec important(keyword()) :: list(map())
  def important(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    min_importance = Keyword.get(opts, :min_importance, 0.7)
    
    from(e in Engram,
      where: e.importance >= ^min_importance,
      order_by: [desc: e.importance, desc: e.inserted_at],
      limit: ^limit,
      select: %{
        id: e.id,
        content: e.content,
        category: e.category,
        importance: e.importance,
        access_count: e.access_count,
        last_accessed_at: e.last_accessed_at,
        inserted_at: e.inserted_at
      }
    )
    |> Repo.all()
  end
  
  @doc """
  Get frequently accessed memories.
  """
  @spec popular(keyword()) :: list(map())
  def popular(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    min_access = Keyword.get(opts, :min_access_count, 5)
    
    from(e in Engram,
      where: e.access_count >= ^min_access,
      order_by: [desc: e.access_count],
      limit: ^limit,
      select: %{
        id: e.id,
        content: e.content,
        category: e.category,
        importance: e.importance,
        access_count: e.access_count,
        last_accessed_at: e.last_accessed_at,
        inserted_at: e.inserted_at
      }
    )
    |> Repo.all()
  end
  
  # Private helpers
  
  defp get_filtered_candidate_ids(opts, limit) do
    category = Keyword.get(opts, :category)
    since = Keyword.get(opts, :since)
    until_time = Keyword.get(opts, :until)
    
    # Only build query if we have filters
    if category || since || until_time do
      query = from(e in Engram, select: e.id, limit: ^limit)
      
      query = if category, do: where(query, [e], e.category == ^category), else: query
      query = if since, do: where(query, [e], e.inserted_at >= ^since), else: query
      query = if until_time, do: where(query, [e], e.inserted_at <= ^until_time), else: query
      
      Repo.all(query) |> MapSet.new()
    else
      nil
    end
  end
  
  defp enrich_with_access_data(candidates) do
    ids = Enum.map(candidates, & &1.id)
    
    access_data = 
      from(e in Engram,
        where: e.id in ^ids,
        select: {e.id, %{access_count: e.access_count, last_accessed_at: e.last_accessed_at}}
      )
      |> Repo.all()
      |> Map.new()
    
    Enum.map(candidates, fn c ->
      data = Map.get(access_data, c.id, %{access_count: 0, last_accessed_at: nil})
      Map.merge(c, data)
    end)
  end
  
  defp track_access_async(results) do
    ids = Enum.map(results, & &1.id)
    now = NaiveDateTime.utc_now()
    
    from(e in Engram, where: e.id in ^ids)
    |> Repo.update_all(
      inc: [access_count: 1],
      set: [last_accessed_at: now]
    )
  end
end
```

---

### Task 3: Update Memory Module
**File:** `lib/mimo/brain/memory.ex`

Add hybrid search wrapper:

```elixir
@doc """
Hybrid search combining semantic similarity with recency and importance.
Delegates to HybridRetriever.

## Options

See `Mimo.Brain.HybridRetriever.search/2` for full options.
"""
def hybrid_search(query, opts \\ []) do
  Mimo.Brain.HybridRetriever.search(query, opts)
end
```

---

### Task 4: Add MCP Tool
**File:** `lib/mimo/tool_registry.ex`

Update `search_vibes` tool or add new hybrid search tool:

```elixir
%{
  "name" => "search_memory",
  "description" => "Search memories with hybrid ranking. Combines semantic similarity with recency, importance, and access patterns.",
  "inputSchema" => %{
    "type" => "object",
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "Search query"
      },
      "limit" => %{
        "type" => "integer",
        "description" => "Maximum results (default: 10)"
      },
      "preset" => %{
        "type" => "string",
        "enum" => ["balanced", "semantic", "recent", "important", "popular"],
        "description" => "Ranking strategy preset"
      },
      "category" => %{
        "type" => "string",
        "description" => "Filter by category"
      }
    },
    "required" => ["query"]
  }
}
```

---

### Task 5: Add Telemetry
**File:** `lib/mimo/telemetry/metrics.ex`

```elixir
# Hybrid Retrieval Metrics
distribution("mimo.memory.hybrid_search.duration",
  unit: {:native, :microsecond},
  buckets: [1000, 5000, 10000, 25000, 50000]
),
counter("mimo.memory.hybrid_search.total"),
summary("mimo.memory.hybrid_search.result_count"),
```

---

### Task 6: Write Tests
**File:** `test/mimo/brain/hybrid_scorer_test.exs`
**File:** `test/mimo/brain/hybrid_retriever_test.exs`

---

## 🧪 Testing Strategy

### Unit Tests

```elixir
describe "HybridScorer.calculate_score/2" do
  test "semantic preset prioritizes similarity" do
    high_sim = %{similarity: 0.9, importance: 0.5, access_count: 0}
    low_sim = %{similarity: 0.3, importance: 0.9, access_count: 100}
    
    assert HybridScorer.calculate_score(high_sim, :semantic) >
           HybridScorer.calculate_score(low_sim, :semantic)
  end
  
  test "recent preset prioritizes recency" do
    now = NaiveDateTime.utc_now()
    old = NaiveDateTime.add(now, -30, :day)
    
    recent = %{similarity: 0.5, importance: 0.5, last_accessed_at: now}
    older = %{similarity: 0.9, importance: 0.9, last_accessed_at: old}
    
    assert HybridScorer.calculate_score(recent, :recent) >
           HybridScorer.calculate_score(older, :recent)
  end
end

describe "HybridRetriever.search/2" do
  test "returns results sorted by final_score" do
    results = HybridRetriever.search("test query")
    
    scores = Enum.map(results, & &1.final_score)
    assert scores == Enum.sort(scores, :desc)
  end
  
  test "category filter works" do
    results = HybridRetriever.search("test", category: "observation")
    
    assert Enum.all?(results, & &1.category == "observation")
  end
end
```

---

## 📊 Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| Search latency | < 50ms p99 | Telemetry |
| Ranking accuracy | Improved relevance | User feedback |
| Filter efficiency | < 5ms overhead | Profiling |

---

## 🔗 Dependencies & Interfaces

### Consumes
- `Mimo.Brain.Memory.search_memories/2`
- `Mimo.Brain.Engram` (with access fields from SPEC-003)

### Provides
- `Mimo.Brain.HybridScorer` - Scoring utilities
- `Mimo.Brain.HybridRetriever` - High-level search API
- MCP tool `search_memory`

### Events Emitted
- `[:mimo, :memory, :hybrid_search]`

---

## 📚 References

- [Memory MCP Research Document](../references/research%20abt%20memory%20mcp.pdf)
- [Learning to Rank](https://en.wikipedia.org/wiki/Learning_to_rank)
- SPEC-003: Forgetting/Decay (access tracking fields)
