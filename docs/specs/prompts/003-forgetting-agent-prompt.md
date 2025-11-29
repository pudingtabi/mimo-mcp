# AI Agent Prompt: Forgetting and Decay System

## 🎯 Mission

You are implementing the Forgetting and Decay System for Mimo MCP. This component prevents unbounded memory growth by intelligently forgetting memories based on exponential decay curves, access patterns, and importance scores.

## 📋 Context

**Project:** Mimo MCP (Elixir-based MCP server with memory capabilities)
**Workspace:** `/workspace/mrc-server/mimo-mcp`
**Spec Document:** `docs/specs/003-forgetting-decay.md`
**Dependencies:** None (can be implemented independently)

### Existing Architecture
- Memory storage: `Mimo.Brain.Memory` with `Mimo.Brain.Engram` schema
- Database: SQLite via Ecto (`Mimo.Repo`)
- Current cleanup: `Memory.cleanup_old/1` - simple age-based deletion

### Key Files to Reference
- `lib/mimo/brain/memory.ex` - Memory operations
- `lib/mimo/brain/engram.ex` - Schema to extend
- `priv/repo/migrations/` - Migration patterns

## 🔧 Implementation Requirements

### Files to Create

1. **`priv/repo/migrations/YYYYMMDDHHMMSS_add_decay_fields.exs`**
   - Add `access_count` (integer, default 0)
   - Add `last_accessed_at` (naive_datetime_usec)
   - Add `decay_rate` (float, default 0.1)
   - Add `protected` (boolean, default false)
   - Backfill `last_accessed_at` from `inserted_at`
   - Create index for efficient decay queries

2. **`lib/mimo/brain/decay_scorer.ex`**
   - Pure functions for score calculation
   - `calculate_score/1` - Returns 0.0-1.0 score
   - `should_forget?/2` - Check if below threshold
   - `predict_forgetting/2` - Days until forgotten
   - Formula: `score = importance × e^(-λ×age_days) × (1 + log(1+access_count)×0.1)`

3. **`lib/mimo/brain/forgetting.ex`**
   - GenServer with scheduled cleanup
   - Public API:
     - `run_now/1` - Manual trigger with options
     - `stats/0` - Forgetting statistics
     - `protect/1` - Mark memory as protected
     - `unprotect/1` - Remove protection
   - Query non-protected memories
   - Calculate scores and filter
   - Delete forgotten memories
   - Emit telemetry

4. **`test/mimo/brain/decay_scorer_test.exs`**
   - Test score calculation
   - Test age effects
   - Test access count boost
   - Test protection

5. **`test/mimo/brain/forgetting_test.exs`**
   - Test scheduled runs
   - Test manual trigger
   - Test protection
   - Test dry run mode

### Files to Modify

1. **`lib/mimo/brain/engram.ex`**
   - Add new fields to schema
   - Update changeset

2. **`lib/mimo/brain/memory.ex`**
   - Add access tracking to `search_memories/2`
   - Track access count and last_accessed_at updates
   - Use async Task to avoid blocking

3. **`lib/mimo/application.ex`**
   - Add `{Mimo.Brain.Forgetting, []}`

4. **`config/config.exs`**
   - Add `:forgetting` configuration

5. **`lib/mimo/telemetry/metrics.ex`**
   - Add forgetting and access metrics

## ⚙️ Technical Specifications

### Decay Formula

```elixir
# Effective score calculation
def calculate_score(engram) do
  importance = engram.importance || 0.5
  access_count = engram.access_count || 0
  decay_rate = engram.decay_rate || 0.1
  last_accessed = engram.last_accessed_at || engram.inserted_at
  
  age_days = calculate_age_days(last_accessed)
  
  recency_factor = :math.exp(-decay_rate * age_days)
  access_factor = 1 + :math.log(1 + access_count) * 0.1
  
  min(1.0, importance * recency_factor * access_factor)
end

# Score interpretation:
# - 0.0-0.1: Should be forgotten
# - 0.1-0.3: At risk of forgetting
# - 0.3-0.7: Healthy memory
# - 0.7-1.0: Strong/important memory
```

### Database Migration

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

    # Backfill existing records
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

### Access Tracking

```elixir
# In Memory.search_memories/2, after getting results:
defp track_access(results) do
  ids = Enum.map(results, & &1.id)
  now = NaiveDateTime.utc_now()
  
  from(e in Engram, where: e.id in ^ids)
  |> Repo.update_all(
    inc: [access_count: 1],
    set: [last_accessed_at: now]
  )
  
  :telemetry.execute([:mimo, :memory, :accessed], 
    %{count: length(ids)}, %{})
end

# Call asynchronously to avoid blocking:
Task.start(fn -> track_access(results) end)
```

### Configuration

```elixir
config :mimo_mcp, :forgetting,
  enabled: true,
  interval_ms: 3_600_000,    # 1 hour
  threshold: 0.1,            # Forget below this score
  batch_size: 1000,          # Process N memories per cycle
  dry_run: false             # Log but don't delete
```

## ✅ Acceptance Criteria

### Must Pass
- [ ] Migration runs successfully
- [ ] `mix test test/mimo/brain/decay_scorer_test.exs` passes
- [ ] `mix test test/mimo/brain/forgetting_test.exs` passes
- [ ] Old memories get lower scores than new ones
- [ ] Frequently accessed memories get higher scores
- [ ] Protected memories are never forgotten
- [ ] Scheduled forgetting runs on interval
- [ ] Manual `run_now/1` works
- [ ] Access tracking updates on search
- [ ] Telemetry events fire

### Quality Gates
- [ ] No compiler warnings
- [ ] Migration is reversible
- [ ] Cleanup cycle < 10s for 1000 memories
- [ ] No impact on search latency

## 🚫 Constraints

1. **DO NOT** delete memories synchronously during search
2. **DO NOT** change existing `cleanup_old/1` behavior (keep it)
3. **DO NOT** block the main request path with access tracking
4. **MUST** use Task.start for async access tracking
5. **MUST** support dry_run mode
6. **MUST** be configurable (threshold, interval, etc.)

## 📝 Implementation Order

1. Create migration for new fields
2. Run migration: `mix ecto.migrate`
3. Update `Engram` schema
4. Create `DecayScorer` with pure functions
5. Write DecayScorer tests
6. Create `Forgetting` GenServer
7. Add to supervision tree
8. Write Forgetting tests
9. Add access tracking to `Memory.search_memories/2`
10. Add configuration
11. Add telemetry metrics
12. Final testing

## 🔍 Verification Commands

```bash
# Create migration
mix ecto.gen.migration add_decay_fields

# Run migration
mix ecto.migrate

# Run tests
mix test test/mimo/brain/decay_scorer_test.exs
mix test test/mimo/brain/forgetting_test.exs

# Interactive testing
iex -S mix

# Create test memories
iex> Mimo.Brain.Memory.persist_memory("Old test memory", "fact", 0.3)
iex> Mimo.Brain.Memory.persist_memory("Important memory", "fact", 0.9)

# Check decay scores
iex> alias Mimo.Brain.{Engram, DecayScorer}
iex> Mimo.Repo.all(Engram) |> Enum.map(&{&1.id, DecayScorer.calculate_score(&1)})

# Run forgetting (dry run first)
iex> Mimo.Brain.Forgetting.run_now(dry_run: true)

# Run for real
iex> Mimo.Brain.Forgetting.run_now()

# Check stats
iex> Mimo.Brain.Forgetting.stats()
```

## 💡 Tips

- Use `NaiveDateTime` for SQLite compatibility (not DateTime)
- The decay formula uses `:math.exp/1` and `:math.log/1`
- Test with memories of varying ages using direct Repo.insert
- Use `Process.sleep/1` for integration tests that need timing
- The access tracking should be non-blocking (use Task.start)
- Consider edge cases: nil values, zero access_count, etc.

## 🎬 Start Here

1. Read `docs/specs/003-forgetting-decay.md` fully
2. Create and run the migration
3. Update `Engram` schema with new fields
4. Create `DecayScorer` module with tests
5. Create `Forgetting` GenServer
6. Add access tracking to Memory searches
7. Test interactively with `iex -S mix`
