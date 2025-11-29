# SPEC-003: Forgetting and Decay System

## 📋 Overview

**Status:** Not Started  
**Priority:** HIGH  
**Estimated Effort:** 2 days  
**Dependencies:** None (can run independently)

### Purpose

Implement intelligent memory forgetting based on decay curves, access patterns, and importance scores. This prevents unbounded memory growth while preserving the most valuable information, mimicking human memory's natural forgetting process.

### Research Foundation

From the Memory MCP research document:
- Memories should decay over time if not accessed
- Low-importance + old + never-accessed = forget
- Forgetting follows exponential decay curves
- Access refreshes decay timers (spaced repetition effect)
- Some memories are "protected" (high importance, frequently accessed)

---

## 🎯 Requirements

### Functional Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| FD-01 | Implement exponential decay scoring | MUST |
| FD-02 | Track access count and last access time | MUST |
| FD-03 | Scheduled cleanup of decayed memories | MUST |
| FD-04 | Protect high-importance memories from decay | MUST |
| FD-05 | Refresh decay on memory access | MUST |
| FD-06 | Configurable decay parameters | SHOULD |
| FD-07 | Emit telemetry for forgotten memories | SHOULD |
| FD-08 | Support manual protection of specific memories | COULD |
| FD-09 | Provide decay predictions (when will X be forgotten?) | COULD |

### Non-Functional Requirements

| ID | Requirement | Target |
|----|-------------|--------|
| FD-NFR-01 | Cleanup cycle time | < 10s for 10K memories |
| FD-NFR-02 | No impact on read latency | < 1ms overhead |
| FD-NFR-03 | Predictable decay behavior | Deterministic |

---

## 🏗️ Architecture

### Decay Formula

```
effective_score = importance × recency_factor × access_factor

where:
  recency_factor = e^(-λ × age_in_days)
  access_factor = 1 + log(1 + access_count) × 0.1
  λ (lambda) = decay_rate (default 0.1)

Memory is forgotten when: effective_score < threshold (default 0.1)
```

### Component Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                    Forgetting System                         │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────────┐    ┌─────────────────┐                │
│  │   Forgetting    │───▶│   Brain.Memory  │                │
│  │   (Scheduler)   │    │  (delete/update)│                │
│  └────────┬────────┘    └─────────────────┘                │
│           │                                                 │
│           ▼                                                 │
│  ┌─────────────────┐    ┌─────────────────┐                │
│  │  Decay Scorer   │───▶│     Engram      │                │
│  │ (calc scores)   │    │ (access_count,  │                │
│  └─────────────────┘    │  last_accessed) │                │
│                          └─────────────────┘                │
│                                                             │
│  Events: [:mimo, :memory, :decayed|:refreshed|:protected]  │
└─────────────────────────────────────────────────────────────┘
```

### Database Changes

```sql
-- Add to engrams table
ALTER TABLE engrams ADD COLUMN access_count INTEGER DEFAULT 0;
ALTER TABLE engrams ADD COLUMN last_accessed_at TIMESTAMP;
ALTER TABLE engrams ADD COLUMN decay_rate FLOAT DEFAULT 0.1;
ALTER TABLE engrams ADD COLUMN protected BOOLEAN DEFAULT FALSE;

-- Index for efficient decay queries
CREATE INDEX engrams_decay_idx ON engrams (importance, last_accessed_at, protected);
```

---

## 📝 Implementation Tasks

### Task 1: Database Migration
**File:** `priv/repo/migrations/YYYYMMDDHHMMSS_add_decay_fields.exs`

```elixir
defmodule Mimo.Repo.Migrations.AddDecayFields do
  use Ecto.Migration

  def change do
    alter table(:engrams) do
      add :access_count, :integer, default: 0
      add :last_accessed_at, :naive_datetime_usec
      add :decay_rate, :float, default: 0.1
      add :protected, :boolean, default: false
    end

    # Set last_accessed_at for existing records
    execute """
      UPDATE engrams 
      SET last_accessed_at = inserted_at 
      WHERE last_accessed_at IS NULL
    """

    create index(:engrams, [:importance, :last_accessed_at, :protected],
      name: :engrams_decay_idx
    )
  end
end
```

---

### Task 2: Update Engram Schema
**File:** `lib/mimo/brain/engram.ex`

Add new fields:
```elixir
schema "engrams" do
  field(:content, :string)
  field(:category, :string)
  field(:importance, :float, default: 0.5)
  field(:embedding, Mimo.Brain.EctoJsonList, default: [])
  field(:metadata, Mimo.Brain.EctoJsonMap, default: %{})
  
  # New decay-related fields
  field(:access_count, :integer, default: 0)
  field(:last_accessed_at, :naive_datetime_usec)
  field(:decay_rate, :float, default: 0.1)
  field(:protected, :boolean, default: false)

  timestamps()
end
```

Update changeset to include new fields.

---

### Task 3: Create Decay Scorer Module
**File:** `lib/mimo/brain/decay_scorer.ex`

```elixir
defmodule Mimo.Brain.DecayScorer do
  @moduledoc """
  Calculates decay scores for memories using exponential decay formula.
  
  Score = importance × recency_factor × access_factor
  
  Where:
  - recency_factor = e^(-λ × age_in_days)
  - access_factor = 1 + log(1 + access_count) × 0.1
  - λ = decay_rate (default 0.1)
  """
  
  @default_decay_rate 0.1
  @default_threshold 0.1
  
  @doc """
  Calculate the effective score for a memory.
  Returns a value between 0 and 1.
  """
  @spec calculate_score(map()) :: float()
  def calculate_score(%{} = engram) do
    importance = engram.importance || 0.5
    access_count = engram.access_count || 0
    decay_rate = engram.decay_rate || @default_decay_rate
    last_accessed = engram.last_accessed_at || engram.inserted_at
    
    age_days = calculate_age_days(last_accessed)
    
    recency_factor = :math.exp(-decay_rate * age_days)
    access_factor = 1 + :math.log(1 + access_count) * 0.1
    
    # Clamp to 0-1 range
    min(1.0, importance * recency_factor * access_factor)
  end
  
  @doc """
  Check if a memory should be forgotten based on its score.
  """
  @spec should_forget?(map(), float()) :: boolean()
  def should_forget?(engram, threshold \\ @default_threshold) do
    # Protected memories are never forgotten
    if engram.protected do
      false
    else
      calculate_score(engram) < threshold
    end
  end
  
  @doc """
  Predict when a memory will be forgotten (days from now).
  Returns :never for protected or very high importance memories.
  """
  @spec predict_forgetting(map(), float()) :: float() | :never
  def predict_forgetting(engram, threshold \\ @default_threshold) do
    if engram.protected or engram.importance >= 0.9 do
      :never
    else
      importance = engram.importance || 0.5
      access_count = engram.access_count || 0
      decay_rate = engram.decay_rate || @default_decay_rate
      
      access_factor = 1 + :math.log(1 + access_count) * 0.1
      
      # Solve: threshold = importance * access_factor * e^(-λ*t)
      # t = -ln(threshold / (importance * access_factor)) / λ
      
      ratio = threshold / (importance * access_factor)
      
      if ratio >= 1 do
        0.0  # Already below threshold
      else
        -:math.log(ratio) / decay_rate
      end
    end
  end
  
  defp calculate_age_days(nil), do: 0.0
  defp calculate_age_days(datetime) do
    now = NaiveDateTime.utc_now()
    diff_seconds = NaiveDateTime.diff(now, datetime, :second)
    diff_seconds / 86400.0  # Convert to days
  end
end
```

---

### Task 4: Create Forgetting GenServer
**File:** `lib/mimo/brain/forgetting.ex`

```elixir
defmodule Mimo.Brain.Forgetting do
  @moduledoc """
  Scheduled memory forgetting based on decay scores.
  
  Runs periodically to identify and remove memories that have
  decayed below the threshold.
  
  ## Configuration
  
      config :mimo_mcp, :forgetting,
        enabled: true,
        interval_ms: 3_600_000,    # 1 hour
        threshold: 0.1,            # Forget below this score
        batch_size: 1000,          # Process N at a time
        dry_run: false             # Log but don't delete
  """
  use GenServer
  require Logger
  
  import Ecto.Query
  alias Mimo.{Repo, Brain.Engram, Brain.DecayScorer}
  
  @default_interval 3_600_000  # 1 hour
  
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  @doc "Trigger immediate forgetting cycle"
  def run_now(opts \\ []) do
    GenServer.call(__MODULE__, {:run_now, opts}, 60_000)
  end
  
  @doc "Get forgetting statistics"
  def stats do
    GenServer.call(__MODULE__, :stats)
  end
  
  @doc "Protect a memory from forgetting"
  def protect(id) do
    GenServer.call(__MODULE__, {:protect, id})
  end
  
  @doc "Unprotect a memory"
  def unprotect(id) do
    GenServer.call(__MODULE__, {:unprotect, id})
  end
  
  # GenServer callbacks
  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)
    
    state = %{
      last_run: nil,
      total_forgotten: 0,
      last_batch_count: 0,
      interval: interval
    }
    
    if Application.get_env(:mimo_mcp, [:forgetting, :enabled], true) do
      schedule_run(interval)
    end
    
    {:ok, state}
  end
  
  @impl true
  def handle_call({:run_now, opts}, _from, state) do
    {count, new_state} = run_forgetting_cycle(state, opts)
    {:reply, {:ok, count}, new_state}
  end
  
  def handle_call(:stats, _from, state) do
    {:reply, Map.take(state, [:last_run, :total_forgotten, :last_batch_count]), state}
  end
  
  def handle_call({:protect, id}, _from, state) do
    result = set_protection(id, true)
    {:reply, result, state}
  end
  
  def handle_call({:unprotect, id}, _from, state) do
    result = set_protection(id, false)
    {:reply, result, state}
  end
  
  @impl true
  def handle_info(:run, state) do
    {_count, new_state} = run_forgetting_cycle(state, [])
    schedule_run(state.interval)
    {:noreply, new_state}
  end
  
  # Private
  defp run_forgetting_cycle(state, opts) do
    config = Application.get_env(:mimo_mcp, :forgetting, [])
    threshold = opts[:threshold] || Keyword.get(config, :threshold, 0.1)
    batch_size = opts[:batch_size] || Keyword.get(config, :batch_size, 1000)
    dry_run = opts[:dry_run] || Keyword.get(config, :dry_run, false)
    
    :telemetry.execute([:mimo, :memory, :forgetting, :started], %{}, %{})
    
    # Query all non-protected memories
    candidates = 
      from(e in Engram,
        where: e.protected == false,
        limit: ^batch_size,
        select: e
      )
      |> Repo.all()
    
    # Calculate scores and filter
    to_forget = 
      candidates
      |> Enum.filter(&DecayScorer.should_forget?(&1, threshold))
    
    count = 
      if dry_run do
        Logger.info("Forgetting dry run: would delete #{length(to_forget)} memories")
        length(to_forget)
      else
        delete_memories(to_forget)
      end
    
    :telemetry.execute(
      [:mimo, :memory, :forgetting, :completed],
      %{forgotten_count: count},
      %{dry_run: dry_run, threshold: threshold}
    )
    
    Logger.info("Forgetting cycle complete: #{count} memories forgotten")
    
    new_state = %{state |
      last_run: DateTime.utc_now(),
      total_forgotten: state.total_forgotten + count,
      last_batch_count: count
    }
    
    {count, new_state}
  end
  
  defp delete_memories(memories) do
    ids = Enum.map(memories, & &1.id)
    
    {count, _} = 
      from(e in Engram, where: e.id in ^ids)
      |> Repo.delete_all()
    
    # Emit individual events for monitoring
    Enum.each(memories, fn m ->
      :telemetry.execute(
        [:mimo, :memory, :decayed],
        %{score: DecayScorer.calculate_score(m)},
        %{id: m.id, category: m.category, age_days: calculate_age(m)}
      )
    end)
    
    count
  end
  
  defp set_protection(id, protected) do
    case Repo.get(Engram, id) do
      nil -> 
        {:error, :not_found}
      engram ->
        engram
        |> Ecto.Changeset.change(protected: protected)
        |> Repo.update()
    end
  end
  
  defp calculate_age(engram) do
    now = NaiveDateTime.utc_now()
    NaiveDateTime.diff(now, engram.inserted_at, :second) / 86400.0
  end
  
  defp schedule_run(interval) do
    Process.send_after(self(), :run, interval)
  end
end
```

---

### Task 5: Update Memory Module for Access Tracking
**File:** `lib/mimo/brain/memory.ex`

Add access tracking to search and retrieval:

```elixir
# After search_memories returns results, track access
defp track_access(results) do
  ids = Enum.map(results, & &1.id)
  now = NaiveDateTime.utc_now()
  
  from(e in Engram, where: e.id in ^ids)
  |> Repo.update_all(
    inc: [access_count: 1],
    set: [last_accessed_at: now]
  )
  
  # Emit telemetry for each access
  Enum.each(results, fn r ->
    :telemetry.execute(
      [:mimo, :memory, :accessed],
      %{count: 1},
      %{id: r.id, category: r.category}
    )
  end)
end

# Modify search_memories to call track_access
def search_memories(query, opts \\ []) do
  # ... existing code ...
  results = stream_search(query_embedding, limit, min_similarity, batch_size)
  
  # Track that these memories were accessed
  if Keyword.get(opts, :track_access, true) do
    Task.start(fn -> track_access(results) end)
  end
  
  results
end
```

---

### Task 6: Add Configuration
**File:** `config/config.exs`

```elixir
config :mimo_mcp, :forgetting,
  enabled: true,
  interval_ms: 3_600_000,    # 1 hour
  threshold: 0.1,            # Forget below this score
  batch_size: 1000,          # Process N memories per cycle
  dry_run: false             # Set true to log without deleting
```

---

### Task 7: Add Telemetry
**File:** `lib/mimo/telemetry/metrics.ex`

```elixir
# Forgetting Metrics
counter("mimo.memory.forgetting.started.total"),
counter("mimo.memory.forgetting.completed.total"),
counter("mimo.memory.decayed.total"),
counter("mimo.memory.accessed.total"),
summary("mimo.memory.decay_score",
  description: "Distribution of decay scores at forgetting time"
)
```

---

### Task 8: Write Tests
**File:** `test/mimo/brain/forgetting_test.exs`

Test cases:
- [ ] Decay scoring calculation
- [ ] Age-based decay
- [ ] Access count boost
- [ ] Protection prevents forgetting
- [ ] Scheduled runs work
- [ ] Manual run works
- [ ] Dry run doesn't delete
- [ ] Access tracking updates fields

---

## 🧪 Testing Strategy

### Unit Tests

```elixir
describe "DecayScorer" do
  test "new memory has high score" do
    engram = %{importance: 0.5, access_count: 0, decay_rate: 0.1,
               last_accessed_at: NaiveDateTime.utc_now()}
    
    score = DecayScorer.calculate_score(engram)
    assert score >= 0.45  # Close to importance
  end
  
  test "old memory has low score" do
    old_time = NaiveDateTime.add(NaiveDateTime.utc_now(), -30, :day)
    engram = %{importance: 0.5, access_count: 0, decay_rate: 0.1,
               last_accessed_at: old_time}
    
    score = DecayScorer.calculate_score(engram)
    assert score < 0.1  # Decayed significantly
  end
  
  test "high access count boosts score" do
    old_time = NaiveDateTime.add(NaiveDateTime.utc_now(), -10, :day)
    
    low_access = %{importance: 0.5, access_count: 0, decay_rate: 0.1,
                   last_accessed_at: old_time}
    high_access = %{importance: 0.5, access_count: 100, decay_rate: 0.1,
                    last_accessed_at: old_time}
    
    assert DecayScorer.calculate_score(high_access) > 
           DecayScorer.calculate_score(low_access)
  end
end

describe "Forgetting" do
  test "low-score memories are forgotten" do
    # Create an old, low-importance memory
    {:ok, engram} = create_old_memory(days_ago: 60, importance: 0.2)
    
    {:ok, count} = Forgetting.run_now()
    
    assert count >= 1
    assert Repo.get(Engram, engram.id) == nil
  end
  
  test "protected memories are not forgotten" do
    {:ok, engram} = create_old_memory(days_ago: 60, importance: 0.2)
    Forgetting.protect(engram.id)
    
    {:ok, _count} = Forgetting.run_now()
    
    assert Repo.get(Engram, engram.id) != nil
  end
end
```

---

## 📊 Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| Cleanup cycle time | < 10s for 10K | Telemetry |
| Memory savings | 20-40% reduction over time | DB size |
| High-value retention | 100% of protected | Testing |
| Predictable decay | Matches formula | Unit tests |

---

## 🔗 Dependencies & Interfaces

### Consumes
- `Mimo.Repo` for database access
- `Mimo.Brain.Engram` schema

### Provides
- `Mimo.Brain.Forgetting` API
- `Mimo.Brain.DecayScorer` utility
- Access tracking in Memory searches

### Events Emitted
- `[:mimo, :memory, :forgetting, :started]`
- `[:mimo, :memory, :forgetting, :completed]`
- `[:mimo, :memory, :decayed]`
- `[:mimo, :memory, :accessed]`

---

## 📚 References

- [Memory MCP Research Document](../references/research%20abt%20memory%20mcp.pdf)
- [Forgetting Curve (Ebbinghaus)](https://en.wikipedia.org/wiki/Forgetting_curve)
- [Spaced Repetition](https://en.wikipedia.org/wiki/Spaced_repetition)
