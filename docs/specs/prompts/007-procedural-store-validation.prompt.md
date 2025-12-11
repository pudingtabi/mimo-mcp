# Agent Prompt: SPEC-007 Procedural Store Production Validation

## Mission
Validate Procedural Store FSM engine for production readiness. Transform status from "⚠️ Beta" to "✅ Production Ready".

## Context
- **Workspace**: `/workspace/mrc-server/mimo-mcp`
- **Spec**: `docs/specs/007-procedural-store-validation.md`
- **Target Modules**: `lib/mimo/procedural_store/*.ex`
- **Test Location**: `test/mimo/procedural_store/`

## Phase 1: FSM Completeness Testing

### Task 1.1: State Machine Test Suite
Create `test/mimo/procedural_store/fsm_complete_test.exs`:

```elixir
# Test all FSM patterns:
# 1. Linear: A -> B -> C -> Done
# 2. Branching: A -> (B | C) -> D
# 3. Looping: A -> B -> A (with exit condition)
# 4. Error recovery: A -> B(fail) -> A(retry)
# 5. Timeout handling: A -> B(timeout) -> Error
```

**Test Cases:**
- [ ] Happy path execution
- [ ] Error state transitions
- [ ] Retry logic (max 3 retries)
- [ ] Timeout handling
- [ ] State persistence across restarts
- [ ] Concurrent FSM instances

### Task 1.2: Create Real-World Procedure Tests
Create `test/mimo/procedural_store/real_procedures_test.exs`:

```elixir
# Test realistic procedures:
# 1. Deploy workflow: validate -> build -> test -> deploy
# 2. Data pipeline: fetch -> transform -> validate -> store
# 3. Approval flow: submit -> review -> (approve | reject)
```

## Phase 2: State Persistence

### Task 2.1: Add FSM State Persistence
Create `lib/mimo/procedural_store/state_store.ex`:

```elixir
defmodule Mimo.ProceduralStore.StateStore do
  @moduledoc """
  Persist FSM execution state for crash recovery.
  """
  
  def save_state(execution_id, state) do
    # Save to SQLite: execution_id, current_state, context, timestamp
  end
  
  def load_state(execution_id) do
    # Restore from SQLite
  end
  
  def resume_execution(execution_id) do
    # Resume FSM from saved state
  end
end
```

### Task 2.2: Create Migration for State Table
Create `priv/repo/migrations/YYYYMMDDHHMMSS_create_fsm_states.exs`:

```elixir
def change do
  create table(:fsm_states) do
    add :execution_id, :string, null: false
    add :procedure_name, :string, null: false
    add :current_state, :string, null: false
    add :context, :map, default: %{}
    add :retry_count, :integer, default: 0
    add :started_at, :utc_datetime
    add :updated_at, :utc_datetime
    timestamps()
  end
  
  create unique_index(:fsm_states, [:execution_id])
  create index(:fsm_states, [:procedure_name, :current_state])
end
```

### Task 2.3: Crash Recovery Test
Create `test/mimo/procedural_store/crash_recovery_test.exs`:

```elixir
# Simulate:
# 1. Start FSM, reach state B
# 2. Kill process (simulate crash)
# 3. Restart and verify resume from B
# 4. Complete execution
```

## Phase 3: Error Handling Enhancement

### Task 3.1: Comprehensive Error States
Update `lib/mimo/procedural_store/execution_fsm.ex`:

```elixir
# Add error handling:
# - :timeout_error - action took too long
# - :validation_error - input validation failed
# - :execution_error - action raised exception
# - :max_retries_exceeded - gave up after N retries
# - :manual_intervention - needs human input
```

### Task 3.2: Rollback Support
Add to `lib/mimo/procedural_store/execution_fsm.ex`:

```elixir
def rollback(execution_id) do
  # Execute compensating actions in reverse order
  # A -> B -> C becomes C_rollback -> B_rollback -> A_rollback
end
```

Create test `test/mimo/procedural_store/rollback_test.exs`

## Phase 4: Observability

### Task 4.1: FSM Telemetry Events
Add events:

```elixir
[:mimo, :procedural, :execution, :start]
[:mimo, :procedural, :execution, :stop]
[:mimo, :procedural, :state, :transition]
[:mimo, :procedural, :action, :start]
[:mimo, :procedural, :action, :stop]
[:mimo, :procedural, :error, :retry]
[:mimo, :procedural, :error, :failed]
```

### Task 4.2: Execution History
Create `lib/mimo/procedural_store/history.ex`:

```elixir
def record_transition(execution_id, from_state, to_state, metadata) do
  # Store in fsm_history table
end

def get_execution_history(execution_id) do
  # Return full execution trace
end
```

## Phase 5: Performance Testing

### Task 5.1: Concurrent Execution Benchmark
Create `bench/procedural_store/concurrent_bench.exs`:

```elixir
# Run 100 concurrent FSM instances
# Measure:
# - Total throughput (executions/second)
# - Average execution time
# - Memory per instance
# - No deadlocks or race conditions
```

**Targets:**
- [ ] 50+ concurrent FSMs without degradation
- [ ] < 100ms state transition overhead
- [ ] < 10MB memory per active FSM

## Phase 6: Validation Report

### Task 6.1: Generate Report
Create `docs/verification/procedural-store-validation-report.md`:

```markdown
# Procedural Store Production Validation Report

## FSM Completeness
- Linear workflows: ✅
- Branching: ✅
- Looping: ✅
- Error recovery: ✅

## Crash Recovery
- State persistence: ✅
- Resume from crash: ✅
- No data loss: ✅

## Performance
- Concurrent FSMs: X supported
- Transition overhead: Xms
- Memory per FSM: XMB

## Recommendation
[READY/NOT READY] for production
```

## Execution Order

```
1. Phase 1 (FSM Testing) - Verify current functionality
2. Phase 2 (Persistence) - Add crash recovery
3. Phase 3 (Error Handling) - Enhance robustness
4. Phase 4 (Observability) - Add monitoring
5. Phase 5 (Performance) - Benchmark
6. Phase 6 (Report) - Document results
```

## Success Criteria

All must be GREEN:
- [ ] All FSM patterns tested and working
- [ ] State persistence implemented
- [ ] Crash recovery verified
- [ ] Rollback support added
- [ ] 50+ concurrent FSMs pass
- [ ] All tests pass
- [ ] Validation report generated

## Commands

```bash
# Run FSM tests
mix test test/mimo/procedural_store/

# Run crash recovery test
mix test test/mimo/procedural_store/crash_recovery_test.exs

# Run concurrent benchmark
mix run bench/procedural_store/concurrent_bench.exs

# Full validation
mix test test/mimo/procedural_store/ --include integration
```

## Notes for Agent

1. **Test existing FSM first** - understand current capabilities
2. **Add persistence BEFORE crash recovery tests**
3. **Run migration before testing persistence**
4. **Document any limitations found**
5. **Update README.md status only after ALL criteria pass**
