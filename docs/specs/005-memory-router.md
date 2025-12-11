# SPEC-005: Unified Memory Router

## 📋 Overview

**Status:** Not Started  
**Priority:** MEDIUM  
**Estimated Effort:** 2 days  
**Dependencies:** SPEC-001 to SPEC-004 (integrates all memory systems)

### Purpose

Create a unified interface that routes queries to the appropriate memory systems (Working Memory, Episodic/Engram, Semantic Graph, Procedural Store) based on query intent, providing a single entry point for memory operations.

### Research Foundation

From the Memory MCP research document:
- Different memory types serve different purposes
- Query intent should determine which stores to query
- Results from multiple stores should be merged intelligently
- Single unified API reduces cognitive load on users

---

## 🎯 Requirements

### Functional Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| MR-01 | Route queries to appropriate memory store(s) | MUST |
| MR-02 | Support explicit store selection | MUST |
| MR-03 | Auto-classify query intent when not specified | SHOULD |
| MR-04 | Merge results from multiple stores | MUST |
| MR-05 | Rank merged results by relevance | SHOULD |
| MR-06 | Support "ask" interface for LLM-enhanced responses | COULD |
| MR-07 | Provide unified storage API | SHOULD |
| MR-08 | Emit telemetry for routing decisions | SHOULD |

### Non-Functional Requirements

| ID | Requirement | Target |
|----|-------------|--------|
| MR-NFR-01 | Routing decision latency | < 5ms |
| MR-NFR-02 | Query latency overhead | < 10% |

---

## 🏗️ Architecture

### Memory Store Types

| Store | Purpose | Data Type | Query Style |
|-------|---------|-----------|-------------|
| Working | Active context | Recent interactions | Recency-based |
| Episodic | Narrative history | Engrams (vector) | Semantic search |
| Semantic | Facts & relationships | Triples (graph) | Graph traversal |
| Procedural | Skills & workflows | Procedures | Name/tag lookup |

### Routing Strategy

```
Query Intent → Store Selection

"What happened recently?" → Working + Episodic (recent preset)
"Who is Alice's manager?" → Semantic (graph query)
"How do I deploy?" → Procedural (skill lookup)
"Tell me about the project" → Episodic (semantic search)
"What's related to X?" → Semantic + Episodic (hybrid)
```

### Component Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                      Memory Router                                   │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Query ──▶ ┌─────────────────┐                                      │
│            │ Intent Classifier│                                      │
│            └────────┬────────┘                                      │
│                     │                                                │
│        ┌───────────┬┴───────────┬────────────┐                      │
│        ▼           ▼            ▼            ▼                      │
│  ┌──────────┐┌──────────┐┌───────────┐┌───────────┐                │
│  │ Working  ││ Episodic ││ Semantic  ││Procedural │                │
│  │ Memory   ││ (Engram) ││  (Graph)  ││  Store    │                │
│  └────┬─────┘└────┬─────┘└─────┬─────┘└─────┬─────┘                │
│       │           │            │            │                       │
│       └───────────┴──────┬─────┴────────────┘                       │
│                          ▼                                          │
│                   ┌─────────────┐                                   │
│                   │   Merger    │                                   │
│                   └──────┬──────┘                                   │
│                          ▼                                          │
│                     Results                                         │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 📝 Implementation Tasks

### Task 1: Create Memory Router Module
**File:** `lib/mimo/brain/memory_router.ex`

```elixir
defmodule Mimo.Brain.MemoryRouter do
  @moduledoc """
  Unified interface for all memory operations.
  
  Routes queries to the appropriate memory stores based on intent
  and merges results into a unified response.
  
  ## Examples
  
      # Auto-route based on query
      MemoryRouter.query("What happened recently?")
      
      # Explicit store selection
      MemoryRouter.query("project details", stores: [:episodic])
      
      # Query specific store
      MemoryRouter.episodic("user preferences")
      MemoryRouter.semantic("who:Alice")
      MemoryRouter.procedural("deployment")
      
      # Store to appropriate location
      MemoryRouter.store("New fact", type: :episodic)
      MemoryRouter.store("Alice manages Bob", type: :semantic)
  """
  require Logger
  
  alias Mimo.Brain.{
    WorkingMemory,
    Memory,
    HybridRetriever,
    Classifier
  }
  alias Mimo.SemanticStore.Query, as: SemanticQuery
  alias Mimo.ProceduralStore
  
  @type store :: :working | :episodic | :semantic | :procedural | :all
  @type result :: %{
    source: store(),
    content: String.t(),
    score: float(),
    metadata: map()
  }
  
  @doc """
  Query memories with automatic routing.
  
  ## Options
  
  - `:stores` - List of stores to query (default: auto-detect)
  - `:limit` - Max results per store (default: 5)
  - `:merge` - Whether to merge results (default: true)
  
  ## Returns
  
  List of results with `:source` indicating origin store
  """
  @spec query(String.t(), keyword()) :: {:ok, [result()]} | {:error, term()}
  def query(query_text, opts \\ []) do
    stores = Keyword.get(opts, :stores) || classify_query(query_text)
    limit = Keyword.get(opts, :limit, 5)
    merge = Keyword.get(opts, :merge, true)
    
    :telemetry.execute(
      [:mimo, :memory_router, :query],
      %{stores_count: length(stores)},
      %{stores: stores}
    )
    
    results = 
      stores
      |> Enum.map(fn store ->
        Task.async(fn -> query_store(store, query_text, limit) end)
      end)
      |> Task.await_many(5000)
      |> List.flatten()
    
    final = if merge, do: merge_results(results, limit * 2), else: results
    
    {:ok, final}
  end
  
  @doc "Query working memory specifically"
  @spec working(String.t(), keyword()) :: [result()]
  def working(query_text, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    
    WorkingMemory.get_recent(limit)
    |> Enum.map(&format_working_result/1)
  end
  
  @doc "Query episodic memory (Engrams) specifically"
  @spec episodic(String.t(), keyword()) :: [result()]
  def episodic(query_text, opts \\ []) do
    preset = Keyword.get(opts, :preset, :balanced)
    limit = Keyword.get(opts, :limit, 10)
    
    HybridRetriever.search(query_text, limit: limit, preset: preset)
    |> Enum.map(&format_episodic_result/1)
  end
  
  @doc "Query semantic store (knowledge graph) specifically"
  @spec semantic(String.t(), keyword()) :: [result()]
  def semantic(query_text, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    
    # Parse query for entity patterns
    case parse_semantic_query(query_text) do
      {:entity, entity_id} ->
        SemanticQuery.about(entity_id, limit: limit)
        |> format_semantic_results()
        
      {:relationship, subject, predicate} ->
        SemanticQuery.find(subject, predicate, limit: limit)
        |> format_semantic_results()
        
      :natural ->
        # Fall back to natural language query
        SemanticQuery.natural(query_text, limit: limit)
        |> format_semantic_results()
    end
  end
  
  @doc "Query procedural store (skills) specifically"
  @spec procedural(String.t(), keyword()) :: [result()]
  def procedural(query_text, opts \\ []) do
    # Search skills by name/description
    case Mimo.Skills.HotReload.find_skill(query_text) do
      {:ok, skill} ->
        [format_procedural_result(skill)]
      {:error, _} ->
        []
    end
  end
  
  @doc """
  Store to appropriate memory system.
  
  ## Options
  
  - `:type` - :working, :episodic, :semantic (required)
  - `:importance` - For episodic (default: 0.5)
  - `:category` - For episodic (default: "fact")
  - Other options passed to specific store
  """
  @spec store(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def store(content, opts) do
    type = Keyword.get(opts, :type, :working)
    
    case type do
      :working ->
        WorkingMemory.store(content, opts)
        
      :episodic ->
        importance = Keyword.get(opts, :importance, 0.5)
        category = Keyword.get(opts, :category, "fact")
        Memory.persist_memory(content, category, importance)
        
      :semantic ->
        # Parse as triple and store
        case parse_triple(content) do
          {:ok, triple} ->
            Mimo.SemanticStore.Repository.create(triple)
          error ->
            error
        end
        
      _ ->
        {:error, :invalid_store_type}
    end
  end
  
  # Private - Query classification
  
  defp classify_query(query_text) do
    # Use existing classifier or heuristics
    case Classifier.classify(query_text) do
      {:ok, :graph, _} -> [:semantic, :episodic]
      {:ok, :vector, _} -> [:episodic, :working]
      {:ok, :hybrid, _} -> [:episodic, :semantic]
      _ -> [:episodic]  # Default to episodic
    end
  end
  
  defp query_store(:working, query, limit) do
    working(query, limit: limit)
  end
  
  defp query_store(:episodic, query, limit) do
    episodic(query, limit: limit)
  end
  
  defp query_store(:semantic, query, limit) do
    semantic(query, limit: limit)
  end
  
  defp query_store(:procedural, query, limit) do
    procedural(query, limit: limit)
  end
  
  # Private - Result formatting
  
  defp format_working_result(item) do
    %{
      source: :working,
      content: item.content,
      score: 0.8,  # Working memory is always relevant
      metadata: %{
        created_at: item.created_at,
        session_id: item.session_id
      }
    }
  end
  
  defp format_episodic_result(item) do
    %{
      source: :episodic,
      content: item.content,
      score: item[:final_score] || item[:similarity] || 0.5,
      metadata: %{
        id: item.id,
        category: item.category,
        importance: item.importance
      }
    }
  end
  
  defp format_semantic_results({:ok, triples}) do
    Enum.map(triples, fn t ->
      %{
        source: :semantic,
        content: "#{t.subject_id} #{t.predicate} #{t.object_id}",
        score: t.confidence,
        metadata: %{
          subject: t.subject_id,
          predicate: t.predicate,
          object: t.object_id
        }
      }
    end)
  end
  
  defp format_semantic_results(_), do: []
  
  defp format_procedural_result(skill) do
    %{
      source: :procedural,
      content: skill.description || skill.name,
      score: 1.0,
      metadata: %{
        name: skill.name,
        type: "skill"
      }
    }
  end
  
  # Private - Result merging
  
  defp merge_results(results, limit) do
    results
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
  end
  
  # Private - Query parsing
  
  defp parse_semantic_query(query) do
    cond do
      String.starts_with?(query, "who:") ->
        entity = String.replace_prefix(query, "who:", "") |> String.trim()
        {:entity, entity}
        
      String.contains?(query, "->") ->
        [subject, predicate] = String.split(query, "->", parts: 2)
        {:relationship, String.trim(subject), String.trim(predicate)}
        
      true ->
        :natural
    end
  end
  
  defp parse_triple(content) do
    # Simple triple parsing: "Subject predicate Object"
    # Or JSON format
    case Jason.decode(content) do
      {:ok, %{"subject" => s, "predicate" => p, "object" => o}} ->
        {:ok, %{
          subject_id: s,
          subject_type: "entity",
          predicate: p,
          object_id: o,
          object_type: "entity",
          confidence: 1.0
        }}
      _ ->
        {:error, :invalid_triple_format}
    end
  end
end
```

---

### Task 2: Create MCP Tool
**File:** Update `lib/mimo/tool_registry.ex`

```elixir
# Unified memory query tool
%{
  "name" => "query_memory",
  "description" => "Query across all memory systems (working, episodic, semantic, procedural). Auto-routes to appropriate stores based on query intent.",
  "inputSchema" => %{
    "type" => "object",
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "The query to search for"
      },
      "stores" => %{
        "type" => "array",
        "items" => %{
          "type" => "string",
          "enum" => ["working", "episodic", "semantic", "procedural"]
        },
        "description" => "Specific stores to query (optional, auto-detects if not provided)"
      },
      "limit" => %{
        "type" => "integer",
        "description" => "Maximum results (default: 10)"
      }
    },
    "required" => ["query"]
  }
}
```

---

### Task 3: Add Telemetry
**File:** `lib/mimo/telemetry/metrics.ex`

```elixir
# Memory Router Metrics
counter("mimo.memory_router.query.total"),
distribution("mimo.memory_router.query.duration",
  unit: {:native, :millisecond}
),
counter("mimo.memory_router.store_hits",
  tags: [:store]
),
```

---

### Task 4: Write Tests
**File:** `test/mimo/brain/memory_router_test.exs`

---

## 🧪 Testing Strategy

### Unit Tests

```elixir
describe "query/2" do
  test "routes to episodic for general queries" do
    {:ok, results} = MemoryRouter.query("tell me about the project")
    
    assert Enum.any?(results, & &1.source == :episodic)
  end
  
  test "routes to semantic for relationship queries" do
    {:ok, results} = MemoryRouter.query("who:Alice")
    
    assert Enum.any?(results, & &1.source == :semantic)
  end
  
  test "explicit store selection works" do
    {:ok, results} = MemoryRouter.query("test", stores: [:working])
    
    assert Enum.all?(results, & &1.source == :working)
  end
end

describe "store/2" do
  test "routes to working memory" do
    {:ok, _} = MemoryRouter.store("test content", type: :working)
    
    recent = MemoryRouter.working("test")
    assert length(recent) > 0
  end
end
```

---

## 📊 Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| Routing accuracy | > 80% | User feedback |
| Query overhead | < 10% vs direct | Benchmarks |
| Store coverage | 100% | Testing |

---

## 🔗 Dependencies & Interfaces

### Consumes
- `Mimo.Brain.WorkingMemory`
- `Mimo.Brain.HybridRetriever`
- `Mimo.SemanticStore.Query`
- `Mimo.Brain.Classifier`
- `Mimo.Skills.HotReload`

### Provides
- `Mimo.Brain.MemoryRouter` unified API
- MCP tool `query_memory`

---

## 📚 References

- [Memory MCP Research Document](../references/research%20abt%20memory%20mcp.pdf)
- SPEC-001: Working Memory
- SPEC-002: Consolidation
- SPEC-003: Forgetting
- SPEC-004: Hybrid Retrieval
