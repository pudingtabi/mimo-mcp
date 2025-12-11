# SPEC-002: Memory Consolidation System

## 📋 Overview

**Status:** Not Started  
**Priority:** CRITICAL  
**Estimated Effort:** 3-4 days  
**Dependencies:** SPEC-001 (Working Memory Buffer)

### Purpose

Implement a memory consolidation system that periodically processes working memory, transferring important items to long-term storage while strengthening connections and organizing memories. This mimics the biological process of memory consolidation during sleep.

### Research Foundation

From the Memory MCP research document:
- Consolidation happens during "sleep" phases (scheduled background tasks)
- Replay mechanism strengthens important memories
- Transfer from working memory → episodic/semantic stores
- Related memories get linked during consolidation
- Importance scores get recalculated based on patterns

---

## 🎯 Requirements

### Functional Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| MC-01 | Process consolidation candidates from working memory | MUST |
| MC-02 | Transfer important items to long-term (Engram) storage | MUST |
| MC-03 | Link related memories during consolidation | MUST |
| MC-04 | Recalculate importance scores based on access patterns | SHOULD |
| MC-05 | Extract and store semantic triples from memories | SHOULD |
| MC-06 | Support manual trigger for immediate consolidation | SHOULD |
| MC-07 | Run scheduled consolidation (configurable interval) | MUST |
| MC-08 | Emit telemetry for monitoring consolidation health | MUST |
| MC-09 | Handle partial failures gracefully | MUST |
| MC-10 | Support dry-run mode for testing | COULD |

### Non-Functional Requirements

| ID | Requirement | Target |
|----|-------------|--------|
| MC-NFR-01 | Consolidation batch latency | < 30s for 100 items |
| MC-NFR-02 | Memory overhead during consolidation | < 100MB |
| MC-NFR-03 | No blocking of main request path | 100% |
| MC-NFR-04 | Failure recovery | Auto-retry with backoff |

---

## 🏗️ Architecture

### Component Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Consolidation System                              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌────────────────┐      ┌─────────────────┐                        │
│  │  Consolidator  │─────▶│ Working Memory  │                        │
│  │   (Scheduler)  │      │ (get candidates)│                        │
│  └───────┬────────┘      └─────────────────┘                        │
│          │                                                           │
│          ▼                                                           │
│  ┌────────────────┐      ┌─────────────────┐                        │
│  │  Consolidation │─────▶│  Brain.Memory   │                        │
│  │    Pipeline    │      │ (persist_memory)│                        │
│  └───────┬────────┘      └─────────────────┘                        │
│          │                                                           │
│          ▼                                                           │
│  ┌────────────────┐      ┌─────────────────┐                        │
│  │    Linker      │─────▶│ Semantic Store  │                        │
│  │ (find related) │      │ (create triples)│                        │
│  └────────────────┘      └─────────────────┘                        │
│                                                                      │
│  Events: [:mimo, :consolidation, :started|:completed|:failed]       │
└─────────────────────────────────────────────────────────────────────┘
```

### Consolidation Pipeline

```
┌─────────────┐    ┌──────────────┐    ┌─────────────┐    ┌──────────────┐
│   Gather    │───▶│   Filter &   │───▶│   Persist   │───▶│    Link &    │
│ Candidates  │    │   Dedupe     │    │  to Engram  │    │   Extract    │
└─────────────┘    └──────────────┘    └─────────────┘    └──────────────┘
      │                  │                   │                   │
      ▼                  ▼                   ▼                   ▼
  Working Mem       Similarity          Brain.Memory       SemanticStore
  Candidates        Clustering          persist_memory     create_triple
```

### State Machine

```
              ┌───────────────────────────────────────┐
              │                                       │
              ▼                                       │
         ┌────────┐                                   │
         │  IDLE  │──── timer/manual ────▶┌──────────┴──┐
         └────────┘                       │  GATHERING  │
              ▲                           └──────┬──────┘
              │                                  │
              │                                  ▼
         ┌────────┐                       ┌────────────┐
         │  DONE  │◀── all processed ────│ PROCESSING │
         └────────┘                       └─────┬──────┘
              │                                 │
              │ reset                           │ error
              │                                 ▼
              └────────────────────────── ┌────────────┐
                                          │   FAILED   │
                                          └────────────┘
```

---

## 📝 Implementation Tasks

### Task 1: Create Consolidator GenServer
**File:** `lib/mimo/brain/consolidator.ex`

```elixir
defmodule Mimo.Brain.Consolidator do
  @moduledoc """
  Memory consolidation system.
  
  Periodically processes working memory, transferring important
  memories to long-term storage and creating semantic links.
  
  ## Configuration
  
      config :mimo_mcp, :consolidation,
        enabled: true,
        interval_ms: 300_000,        # 5 minutes
        min_importance: 0.4,         # Minimum importance to consolidate
        batch_size: 50,              # Process N items per cycle
        link_threshold: 0.7,         # Similarity threshold for linking
        extract_triples: true        # Extract semantic triples
  """
  use GenServer
  require Logger
  
  alias Mimo.Brain.{WorkingMemory, Memory, Engram}
  alias Mimo.SemanticStore.Repository
  
  @default_interval 300_000  # 5 minutes
  
  # Public API
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  @doc "Trigger immediate consolidation"
  def consolidate_now do
    GenServer.call(__MODULE__, :consolidate_now, 60_000)
  end
  
  @doc "Get current consolidation status"
  def status do
    GenServer.call(__MODULE__, :status)
  end
  
  @doc "Get consolidation statistics"
  def stats do
    GenServer.call(__MODULE__, :stats)
  end
  
  # GenServer callbacks
  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)
    
    state = %{
      status: :idle,
      last_run: nil,
      last_result: nil,
      stats: %{
        total_consolidated: 0,
        total_linked: 0,
        total_triples: 0,
        failures: 0
      },
      interval: interval
    }
    
    if Application.get_env(:mimo_mcp, [:consolidation, :enabled], true) do
      schedule_consolidation(interval)
    end
    
    {:ok, state}
  end
  
  @impl true
  def handle_call(:consolidate_now, _from, state) do
    result = run_consolidation(state)
    {:reply, result, update_state_after_consolidation(state, result)}
  end
  
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end
  
  def handle_call(:stats, _from, state) do
    {:reply, state.stats, state}
  end
  
  @impl true
  def handle_info(:consolidate, state) do
    result = run_consolidation(state)
    schedule_consolidation(state.interval)
    {:noreply, update_state_after_consolidation(state, result)}
  end
  
  # Private implementation
  defp run_consolidation(state) do
    start_time = System.monotonic_time(:millisecond)
    
    :telemetry.execute([:mimo, :consolidation, :started], %{}, %{})
    
    try do
      # 1. Gather candidates
      candidates = gather_candidates()
      
      # 2. Filter and dedupe
      filtered = filter_and_dedupe(candidates)
      
      # 3. Persist to long-term
      {persisted, failed} = persist_memories(filtered)
      
      # 4. Link related memories
      links_created = link_related_memories(persisted)
      
      # 5. Extract semantic triples
      triples_created = extract_and_store_triples(persisted)
      
      # 6. Clean up working memory
      cleanup_consolidated(persisted)
      
      duration = System.monotonic_time(:millisecond) - start_time
      
      result = %{
        status: :success,
        candidates: length(candidates),
        filtered: length(filtered),
        persisted: length(persisted),
        failed: length(failed),
        links: links_created,
        triples: triples_created,
        duration_ms: duration
      }
      
      :telemetry.execute(
        [:mimo, :consolidation, :completed],
        %{
          duration_ms: duration,
          persisted_count: length(persisted),
          links_count: links_created,
          triples_count: triples_created
        },
        %{}
      )
      
      Logger.info("Consolidation complete: #{inspect(result)}")
      {:ok, result}
      
    rescue
      e ->
        :telemetry.execute(
          [:mimo, :consolidation, :failed],
          %{count: 1},
          %{error: Exception.message(e)}
        )
        Logger.error("Consolidation failed: #{Exception.message(e)}")
        {:error, e}
    end
  end
  
  defp gather_candidates do
    # Get items marked for consolidation
    marked = WorkingMemory.get_consolidation_candidates()
    
    # Also get high-importance items that weren't explicitly marked
    config = Application.get_env(:mimo_mcp, :consolidation, [])
    min_importance = Keyword.get(config, :min_importance, 0.4)
    
    recent = WorkingMemory.get_recent(100)
    high_importance = Enum.filter(recent, & &1.importance >= min_importance)
    
    # Combine and dedupe by ID
    (marked ++ high_importance)
    |> Enum.uniq_by(& &1.id)
  end
  
  defp filter_and_dedupe(candidates) do
    # Remove near-duplicates using content similarity
    candidates
    |> Enum.reduce([], fn candidate, acc ->
      if similar_exists?(candidate, acc) do
        acc
      else
        [candidate | acc]
      end
    end)
    |> Enum.reverse()
  end
  
  defp similar_exists?(candidate, existing) do
    Enum.any?(existing, fn e ->
      String.jaro_distance(candidate.content, e.content) > 0.85
    end)
  end
  
  defp persist_memories(items) do
    Enum.reduce(items, {[], []}, fn item, {ok, err} ->
      case Memory.persist_memory(item.content, item.context[:source] || "consolidation", item.importance) do
        {:ok, id} ->
          {[Map.put(item, :engram_id, id) | ok], err}
        {:error, reason} ->
          Logger.warning("Failed to persist memory: #{inspect(reason)}")
          {ok, [item | err]}
      end
    end)
  end
  
  defp link_related_memories(persisted) do
    # Find and link related memories
    config = Application.get_env(:mimo_mcp, :consolidation, [])
    threshold = Keyword.get(config, :link_threshold, 0.7)
    
    persisted
    |> Enum.reduce(0, fn item, count ->
      related = Memory.search_memories(item.content, limit: 5, min_similarity: threshold)
      
      links = related
      |> Enum.reject(& &1.id == item.engram_id)
      |> Enum.map(fn related_item ->
        create_link(item.engram_id, related_item.id, related_item.similarity)
      end)
      |> Enum.count(& &1 == :ok)
      
      count + links
    end)
  end
  
  defp create_link(from_id, to_id, confidence) do
    case Repository.create(%{
      subject_id: to_string(from_id),
      subject_type: "engram",
      predicate: "related_to",
      object_id: to_string(to_id),
      object_type: "engram",
      confidence: confidence,
      source: "consolidation"
    }) do
      {:ok, _} -> :ok
      {:error, _} -> :error
    end
  end
  
  defp extract_and_store_triples(persisted) do
    config = Application.get_env(:mimo_mcp, :consolidation, [])
    
    if Keyword.get(config, :extract_triples, true) do
      persisted
      |> Enum.reduce(0, fn item, count ->
        case extract_triples(item.content) do
          {:ok, triples} ->
            stored = store_triples(triples, item.engram_id)
            count + stored
          _ ->
            count
        end
      end)
    else
      0
    end
  end
  
  defp extract_triples(content) do
    # Use LLM to extract subject-predicate-object triples
    # This is optional and can be expensive
    prompt = """
    Extract factual relationships from this text as JSON triples.
    Format: [{"subject": "...", "predicate": "...", "object": "..."}]
    Only extract clear, factual relationships. Return [] if none found.
    
    Text: #{content}
    """
    
    case Mimo.Brain.LLM.complete(prompt, format: :json, max_tokens: 500) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, triples} when is_list(triples) -> {:ok, triples}
          _ -> {:ok, []}
        end
      error ->
        error
    end
  end
  
  defp store_triples(triples, source_id) do
    triples
    |> Enum.map(fn t ->
      Repository.create(%{
        subject_id: t["subject"],
        subject_type: "entity",
        predicate: t["predicate"],
        object_id: t["object"],
        object_type: "entity",
        confidence: 0.8,
        source: "consolidation:#{source_id}"
      })
    end)
    |> Enum.count(&match?({:ok, _}, &1))
  end
  
  defp cleanup_consolidated(persisted) do
    Enum.each(persisted, fn item ->
      WorkingMemory.delete(item.id)
    end)
  end
  
  defp schedule_consolidation(interval) do
    Process.send_after(self(), :consolidate, interval)
  end
  
  defp update_state_after_consolidation(state, result) do
    case result do
      {:ok, r} ->
        %{state |
          status: :idle,
          last_run: DateTime.utc_now(),
          last_result: r,
          stats: update_stats(state.stats, r)
        }
      {:error, _} ->
        %{state |
          status: :idle,
          last_run: DateTime.utc_now(),
          stats: Map.update!(state.stats, :failures, & &1 + 1)
        }
    end
  end
  
  defp update_stats(stats, result) do
    %{stats |
      total_consolidated: stats.total_consolidated + result.persisted,
      total_linked: stats.total_linked + result.links,
      total_triples: stats.total_triples + result.triples
    }
  end
end
```

---

### Task 2: Add Configuration
**File:** `config/config.exs`

```elixir
config :mimo_mcp, :consolidation,
  enabled: true,
  interval_ms: 300_000,        # 5 minutes
  min_importance: 0.4,         # Minimum importance to consolidate
  batch_size: 50,              # Process N items per cycle
  link_threshold: 0.7,         # Similarity threshold for linking
  extract_triples: true        # Extract semantic triples (requires LLM)
```

---

### Task 3: Add to Supervision Tree
**File:** `lib/mimo/application.ex`

Add after WorkingMemory:
```elixir
{Mimo.Brain.Consolidator, []},
```

---

### Task 4: Add Telemetry Metrics
**File:** `lib/mimo/telemetry/metrics.ex`

```elixir
# Consolidation Metrics
counter("mimo.consolidation.started.total"),
counter("mimo.consolidation.completed.total"),
counter("mimo.consolidation.failed.total"),
distribution("mimo.consolidation.duration",
  unit: {:native, :millisecond},
  buckets: [100, 500, 1000, 5000, 10000, 30000]
),
counter("mimo.consolidation.persisted.total"),
counter("mimo.consolidation.links.total"),
counter("mimo.consolidation.triples.total"),
```

---

### Task 5: Add MCP Tool for Manual Consolidation
**File:** `lib/mimo/tool_registry.ex`

Add tool definition:
```elixir
%{
  "name" => "consolidate_memory",
  "description" => "Trigger memory consolidation process. Transfers important working memories to long-term storage.",
  "inputSchema" => %{
    "type" => "object",
    "properties" => %{},
    "required" => []
  }
}
```

---

### Task 6: Write Tests
**File:** `test/mimo/brain/consolidator_test.exs`

Test cases:
- [ ] Consolidation runs on schedule
- [ ] Manual consolidation trigger works
- [ ] High-importance items get persisted
- [ ] Near-duplicates are filtered
- [ ] Related memories get linked
- [ ] Cleanup removes processed items from working memory
- [ ] Failures don't crash the process
- [ ] Stats are accurate

---

## 🧪 Testing Strategy

### Unit Tests

```elixir
describe "consolidation pipeline" do
  test "transfers high-importance items to long-term storage" do
    # Setup: Add items to working memory
    {:ok, id} = WorkingMemory.store("Important fact about project", importance: 0.8)
    WorkingMemory.mark_for_consolidation(id)
    
    # Act: Run consolidation
    {:ok, result} = Consolidator.consolidate_now()
    
    # Assert
    assert result.persisted == 1
    assert {:error, :not_found} = WorkingMemory.get(id)
    assert Memory.search_memories("Important fact") |> length() > 0
  end
  
  test "filters near-duplicate content" do
    {:ok, _} = WorkingMemory.store("User prefers dark mode", importance: 0.8)
    {:ok, _} = WorkingMemory.store("User prefers dark themes", importance: 0.8)
    
    {:ok, result} = Consolidator.consolidate_now()
    
    assert result.persisted == 1  # Only one should persist
  end
end
```

---

## 📊 Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| Consolidation latency | < 30s for 100 items | Telemetry |
| Memory dedup rate | > 20% | Stats |
| Link creation rate | > 1 per 5 memories | Stats |
| Zero main thread blocking | 100% | Load testing |
| Recovery from failures | Auto-resume | Testing |

---

## 🔗 Dependencies & Interfaces

### Consumes
- `Mimo.Brain.WorkingMemory` - Consolidation candidates
- `Mimo.Brain.Memory` - Long-term persistence
- `Mimo.SemanticStore.Repository` - Triple storage
- `Mimo.Brain.LLM` - Triple extraction (optional)

### Provides
- `Mimo.Brain.Consolidator` API
- Scheduled consolidation process
- Manual consolidation trigger

### Events Emitted
- `[:mimo, :consolidation, :started]`
- `[:mimo, :consolidation, :completed]`
- `[:mimo, :consolidation, :failed]`

---

## 📚 References

- [Memory MCP Research Document](../references/research%20abt%20memory%20mcp.pdf)
- [Memory Consolidation (Neuroscience)](https://en.wikipedia.org/wiki/Memory_consolidation)
- SPEC-001: Working Memory Buffer
