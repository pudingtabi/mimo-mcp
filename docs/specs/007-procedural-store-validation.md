# SPEC-007: Procedural Store Production Validation

## Overview

**Goal**: Prove Procedural Store (FSM engine) is production-ready through comprehensive testing.

**Current Status**: ⚠️ Beta (Core Ready)  
**Target Status**: ✅ Production Ready

## Production Readiness Criteria

### 1. Functional Completeness

| Feature | Required | Current | Test Coverage |
|---------|----------|---------|---------------|
| Procedure registration | ✅ | ✅ | Needs validation |
| State transitions | ✅ | ✅ | Needs validation |
| Action execution | ✅ | ✅ | Needs validation |
| Error handling | ✅ | ✅ | Needs validation |
| Rollback support | ✅ | Partial | Needs implementation |
| State persistence | ⚠️ | ❌ | Optional for v1 |

### 2. Performance Benchmarks

| Metric | Target | Test Method |
|--------|--------|-------------|
| Procedure load | < 10ms | Load 100 procedures |
| State transition | < 5ms | Execute 1000 transitions |
| Full procedure (5 states) | < 100ms | End-to-end execution |
| Concurrent procedures | 10 parallel | No deadlocks |

### 3. FSM Correctness Tests

| Scenario | Test |
|----------|------|
| Happy path | All states complete successfully |
| Error in middle | Proper error state transition |
| Retry on failure | Configurable retry with backoff |
| Guard conditions | Transitions blocked when guards fail |
| Timeout handling | States timeout gracefully |

---

## Test Implementation

### Task 1: FSM Core Tests

**File**: `test/mimo/procedural_store/execution_fsm_test.exs`

```elixir
defmodule Mimo.ProceduralStore.ExecutionFSMTest do
  use ExUnit.Case, async: true
  
  alias Mimo.ProceduralStore.{ExecutionFSM, Loader}

  @simple_procedure %{
    name: "test_procedure",
    version: "1.0",
    definition: %{
      "initial_state" => "start",
      "states" => %{
        "start" => %{
          "action" => %{"type" => "log", "message" => "Starting"},
          "transitions" => [%{"event" => "success", "target" => "middle"}]
        },
        "middle" => %{
          "action" => %{"type" => "log", "message" => "Middle"},
          "transitions" => [%{"event" => "success", "target" => "done"}]
        },
        "done" => %{}
      }
    }
  }

  setup do
    {:ok, _} = Loader.register(@simple_procedure)
    :ok
  end

  describe "start_procedure/3" do
    test "starts procedure in initial state" do
      {:ok, pid} = ExecutionFSM.start_procedure("test_procedure", "1.0", %{})
      
      assert Process.alive?(pid)
      state = ExecutionFSM.get_state(pid)
      assert state.current == "start"
    end

    test "returns error for unknown procedure" do
      result = ExecutionFSM.start_procedure("nonexistent", "1.0", %{})
      assert {:error, :not_found} = result
    end
  end

  describe "send_event/2" do
    test "transitions to next state on success" do
      {:ok, pid} = ExecutionFSM.start_procedure("test_procedure", "1.0", %{})
      
      :ok = ExecutionFSM.send_event(pid, :success)
      state = ExecutionFSM.get_state(pid)
      
      assert state.current == "middle"
    end

    test "reaches terminal state" do
      {:ok, pid} = ExecutionFSM.start_procedure("test_procedure", "1.0", %{})
      
      ExecutionFSM.send_event(pid, :success)  # start -> middle
      ExecutionFSM.send_event(pid, :success)  # middle -> done
      
      state = ExecutionFSM.get_state(pid)
      assert state.current == "done"
      assert state.status == :completed
    end
  end

  describe "error handling" do
    @error_procedure %{
      name: "error_procedure",
      version: "1.0",
      definition: %{
        "initial_state" => "start",
        "states" => %{
          "start" => %{
            "action" => %{"type" => "fail"},
            "transitions" => [
              %{"event" => "success", "target" => "done"},
              %{"event" => "error", "target" => "error_state"}
            ]
          },
          "error_state" => %{
            "action" => %{"type" => "log", "message" => "Handling error"}
          },
          "done" => %{}
        }
      }
    }

    test "transitions to error state on failure" do
      {:ok, _} = Loader.register(@error_procedure)
      {:ok, pid} = ExecutionFSM.start_procedure("error_procedure", "1.0", %{})
      
      # Action fails, should auto-transition to error_state
      Process.sleep(100)
      state = ExecutionFSM.get_state(pid)
      
      assert state.current == "error_state"
    end
  end
end
```

### Task 2: Loader & Registry Tests

**File**: `test/mimo/procedural_store/loader_test.exs`

```elixir
defmodule Mimo.ProceduralStore.LoaderTest do
  use ExUnit.Case, async: true
  
  alias Mimo.ProceduralStore.Loader

  describe "register/1" do
    test "registers valid procedure" do
      procedure = %{
        name: "valid_proc",
        version: "1.0",
        definition: %{
          "initial_state" => "start",
          "states" => %{"start" => %{}}
        }
      }
      
      assert {:ok, _} = Loader.register(procedure)
    end

    test "validates procedure schema" do
      invalid = %{name: "bad", version: "1.0"}  # Missing definition
      
      assert {:error, :invalid_schema} = Loader.register(invalid)
    end

    test "allows version updates" do
      proc_v1 = %{name: "versioned", version: "1.0", definition: %{"initial_state" => "a", "states" => %{"a" => %{}}}}
      proc_v2 = %{name: "versioned", version: "2.0", definition: %{"initial_state" => "b", "states" => %{"b" => %{}}}}
      
      {:ok, _} = Loader.register(proc_v1)
      {:ok, _} = Loader.register(proc_v2)
      
      {:ok, loaded} = Loader.get("versioned", "2.0")
      assert loaded.definition["initial_state"] == "b"
    end
  end

  describe "list/0" do
    test "lists all registered procedures" do
      Loader.register(%{name: "list_test_1", version: "1.0", definition: %{"initial_state" => "s", "states" => %{"s" => %{}}}})
      Loader.register(%{name: "list_test_2", version: "1.0", definition: %{"initial_state" => "s", "states" => %{"s" => %{}}}})
      
      procedures = Loader.list()
      names = Enum.map(procedures, & &1.name)
      
      assert "list_test_1" in names
      assert "list_test_2" in names
    end
  end
end
```

### Task 3: Integration Tests

**File**: `test/integration/procedural_store_integration_test.exs`

```elixir
defmodule Mimo.Integration.ProceduralStoreIntegrationTest do
  use ExUnit.Case
  
  @moduletag :integration

  alias Mimo.ProceduralStore.{ExecutionFSM, Loader}

  describe "deployment workflow" do
    @deploy_procedure %{
      name: "deploy_workflow",
      version: "1.0",
      definition: %{
        "initial_state" => "validate",
        "states" => %{
          "validate" => %{
            "action" => %{
              "type" => "function",
              "module" => "Mimo.ProceduralStore.TestActions",
              "function" => "validate"
            },
            "transitions" => [
              %{"event" => "success", "target" => "build"},
              %{"event" => "error", "target" => "failed"}
            ]
          },
          "build" => %{
            "action" => %{
              "type" => "function",
              "module" => "Mimo.ProceduralStore.TestActions",
              "function" => "build"
            },
            "transitions" => [
              %{"event" => "success", "target" => "deploy"},
              %{"event" => "error", "target" => "rollback"}
            ]
          },
          "deploy" => %{
            "action" => %{
              "type" => "function",
              "module" => "Mimo.ProceduralStore.TestActions",
              "function" => "deploy"
            },
            "transitions" => [
              %{"event" => "success", "target" => "done"},
              %{"event" => "error", "target" => "rollback"}
            ]
          },
          "rollback" => %{
            "action" => %{
              "type" => "function",
              "module" => "Mimo.ProceduralStore.TestActions",
              "function" => "rollback"
            },
            "transitions" => [%{"event" => "success", "target" => "failed"}]
          },
          "done" => %{},
          "failed" => %{}
        }
      }
    }

    test "completes full deployment workflow" do
      {:ok, _} = Loader.register(@deploy_procedure)
      {:ok, pid} = ExecutionFSM.start_procedure("deploy_workflow", "1.0", %{env: "staging"})
      
      # Run through all states
      :ok = ExecutionFSM.run_to_completion(pid, timeout: 5000)
      
      state = ExecutionFSM.get_state(pid)
      assert state.current == "done"
      assert state.status == :completed
    end
  end

  describe "concurrent execution" do
    test "runs multiple procedures in parallel" do
      simple = %{
        name: "parallel_test",
        version: "1.0",
        definition: %{
          "initial_state" => "work",
          "states" => %{
            "work" => %{
              "action" => %{"type" => "sleep", "ms" => 100},
              "transitions" => [%{"event" => "success", "target" => "done"}]
            },
            "done" => %{}
          }
        }
      }
      
      {:ok, _} = Loader.register(simple)
      
      # Start 10 parallel procedures
      pids = for i <- 1..10 do
        {:ok, pid} = ExecutionFSM.start_procedure("parallel_test", "1.0", %{id: i})
        pid
      end
      
      # All should complete
      for pid <- pids do
        :ok = ExecutionFSM.run_to_completion(pid, timeout: 5000)
      end
      
      # Verify all completed
      states = Enum.map(pids, &ExecutionFSM.get_state/1)
      assert Enum.all?(states, &(&1.current == "done"))
    end
  end
end

# Test action module
defmodule Mimo.ProceduralStore.TestActions do
  def validate(%{env: env}) when env in ["staging", "prod"], do: {:ok, :validated}
  def validate(_), do: {:error, :invalid_env}
  
  def build(_context), do: {:ok, :built}
  def deploy(_context), do: {:ok, :deployed}
  def rollback(_context), do: {:ok, :rolled_back}
end
```

### Task 4: Performance Benchmarks

**File**: `bench/procedural_store_bench.exs`

```elixir
defmodule ProceduralStoreBench do
  alias Mimo.ProceduralStore.{ExecutionFSM, Loader}

  def run do
    IO.puts("=== Procedural Store Benchmarks ===\n")
    
    setup_procedures()
    bench_load()
    bench_transitions()
    bench_full_execution()
    bench_concurrent()
  end

  defp setup_procedures do
    # 5-state procedure
    Loader.register(%{
      name: "bench_proc",
      version: "1.0",
      definition: %{
        "initial_state" => "s1",
        "states" => %{
          "s1" => %{"action" => %{"type" => "noop"}, "transitions" => [%{"event" => "next", "target" => "s2"}]},
          "s2" => %{"action" => %{"type" => "noop"}, "transitions" => [%{"event" => "next", "target" => "s3"}]},
          "s3" => %{"action" => %{"type" => "noop"}, "transitions" => [%{"event" => "next", "target" => "s4"}]},
          "s4" => %{"action" => %{"type" => "noop"}, "transitions" => [%{"event" => "next", "target" => "s5"}]},
          "s5" => %{}
        }
      }
    })
  end

  defp bench_load do
    IO.puts("## Procedure Load Performance")
    
    {time, _} = :timer.tc(fn ->
      for i <- 1..100 do
        Loader.register(%{
          name: "load_test_#{i}",
          version: "1.0",
          definition: %{"initial_state" => "s", "states" => %{"s" => %{}}}
        })
      end
    end)
    
    avg_ms = time / 100 / 1000
    IO.puts("100 procedure loads: #{Float.round(time/1000, 2)}ms (avg: #{Float.round(avg_ms, 3)}ms)")
    IO.puts("Target: < 10ms per load")
    IO.puts("Status: #{if avg_ms < 10, do: "✅ PASS", else: "❌ FAIL"}\n")
  end

  defp bench_transitions do
    IO.puts("## State Transition Performance")
    
    {:ok, pid} = ExecutionFSM.start_procedure("bench_proc", "1.0", %{})
    
    {time, _} = :timer.tc(fn ->
      for _ <- 1..1000 do
        ExecutionFSM.send_event(pid, :next)
        # Reset for next iteration
        ExecutionFSM.reset(pid)
      end
    end)
    
    avg_ms = time / 1000 / 1000
    IO.puts("1000 transitions: #{Float.round(time/1000, 2)}ms (avg: #{Float.round(avg_ms, 3)}ms)")
    IO.puts("Target: < 5ms per transition")
    IO.puts("Status: #{if avg_ms < 5, do: "✅ PASS", else: "❌ FAIL"}\n")
  end

  defp bench_full_execution do
    IO.puts("## Full Procedure Execution (5 states)")
    
    times = for _ <- 1..100 do
      {:ok, pid} = ExecutionFSM.start_procedure("bench_proc", "1.0", %{})
      
      {time, _} = :timer.tc(fn ->
        for _ <- 1..4 do
          ExecutionFSM.send_event(pid, :next)
        end
      end)
      
      time
    end
    
    avg_ms = Enum.sum(times) / 100 / 1000
    IO.puts("100 full executions: avg #{Float.round(avg_ms, 2)}ms")
    IO.puts("Target: < 100ms per execution")
    IO.puts("Status: #{if avg_ms < 100, do: "✅ PASS", else: "❌ FAIL"}\n")
  end

  defp bench_concurrent do
    IO.puts("## Concurrent Execution (10 parallel)")
    
    {time, results} = :timer.tc(fn ->
      tasks = for i <- 1..10 do
        Task.async(fn ->
          {:ok, pid} = ExecutionFSM.start_procedure("bench_proc", "1.0", %{id: i})
          for _ <- 1..4, do: ExecutionFSM.send_event(pid, :next)
          ExecutionFSM.get_state(pid)
        end)
      end
      
      Task.await_many(tasks, 5000)
    end)
    
    completed = Enum.count(results, &(&1.current == "s5"))
    IO.puts("10 concurrent procedures: #{Float.round(time/1000, 2)}ms")
    IO.puts("Completed: #{completed}/10")
    IO.puts("Status: #{if completed == 10, do: "✅ PASS", else: "❌ FAIL"}\n")
  end
end

# Run with: mix run bench/procedural_store_bench.exs
ProceduralStoreBench.run()
```

---

## Acceptance Criteria

### Must Pass for ✅ Production Ready

1. **FSM Correctness**: All state transitions work as defined
2. **Error Handling**: Errors transition to error states properly
3. **Performance**: All benchmarks meet targets
4. **Concurrency**: 10+ parallel procedures without issues
5. **Validation**: Invalid procedures rejected

### Optional for v1 (can be ⚠️)

- State persistence across restarts
- Distributed procedure execution
- Visual state diagram export

---

## Agent Prompt

```markdown
# Procedural Store Validation Agent

## Mission
Implement and run all tests from SPEC-007 to prove Procedural Store is production-ready.

## Tasks
1. Create test files as specified
2. Implement TestActions module for integration tests
3. Run all tests and benchmarks
4. Fix any failures
5. Document results

## Success Criteria
- All FSM tests pass
- All benchmarks meet targets
- Concurrent execution stable
- Error handling works correctly

## Output
Generate validation report with pass/fail status and recommendation.
```
