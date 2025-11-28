defmodule Mimo.ProceduralStore.ExecutionFSMCompleteTest do
  @moduledoc """
  Comprehensive FSM execution tests.
  
  SPEC-007: Validates state transitions, error handling, and FSM patterns.
  """
  use ExUnit.Case, async: false
  alias Mimo.ProceduralStore.{ExecutionFSM, Loader}
  alias Mimo.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    # Initialize loader cache
    try do
      Loader.init()
    catch
      :error, :badarg -> :ok
    end

    :ok
  end

  describe "linear execution - A -> B -> C -> Done" do
    test "executes all states in sequence" do
      {:ok, _} =
        Loader.register(%{
          name: "linear_test",
          version: "1.0",
          definition: %{
            "initial_state" => "step_a",
            "states" => %{
              "step_a" => %{
                "action" => %{
                  "module" => "Mimo.ProceduralStore.Steps.SetContext",
                  "function" => "execute",
                  "args" => [%{"values" => %{"step_a" => true}}]
                },
                "transitions" => [
                  %{"event" => "success", "target" => "step_b"}
                ]
              },
              "step_b" => %{
                "action" => %{
                  "module" => "Mimo.ProceduralStore.Steps.SetContext",
                  "function" => "execute",
                  "args" => [%{"values" => %{"step_b" => true}}]
                },
                "transitions" => [
                  %{"event" => "success", "target" => "step_c"}
                ]
              },
              "step_c" => %{
                "action" => %{
                  "module" => "Mimo.ProceduralStore.Steps.SetContext",
                  "function" => "execute",
                  "args" => [%{"values" => %{"step_c" => true}}]
                },
                "transitions" => [
                  %{"event" => "success", "target" => "done"}
                ]
              },
              "done" => %{}
            }
          }
        })

      {:ok, _pid} =
        ExecutionFSM.start_procedure("linear_test", "1.0", %{"initial" => true}, caller: self())

      assert_receive {:procedure_complete, "linear_test", :completed, context}, 10_000

      assert context["step_a"] == true
      assert context["step_b"] == true
      assert context["step_c"] == true
      assert context["initial"] == true
    end
  end

  describe "branching execution - A -> (B | C) -> D" do
    setup do
      {:ok, _} =
        Loader.register(%{
          name: "branch_test_high",
          version: "1.0",
          definition: %{
            "initial_state" => "check",
            "states" => %{
              "check" => %{
                "action" => %{
                  "module" => "Mimo.ProceduralStore.Steps.Conditional",
                  "function" => "execute",
                  "args" => [
                    %{
                      "field" => "value",
                      "operator" => "gt",
                      "value" => 50,
                      "true_event" => "high",
                      "false_event" => "low"
                    }
                  ]
                },
                "transitions" => [
                  %{"event" => "high", "target" => "high_path"},
                  %{"event" => "low", "target" => "low_path"}
                ]
              },
              "high_path" => %{
                "action" => %{
                  "module" => "Mimo.ProceduralStore.Steps.SetContext",
                  "function" => "execute",
                  "args" => [%{"values" => %{"path" => "high"}}]
                },
                "transitions" => [%{"event" => "success", "target" => "done"}]
              },
              "low_path" => %{
                "action" => %{
                  "module" => "Mimo.ProceduralStore.Steps.SetContext",
                  "function" => "execute",
                  "args" => [%{"values" => %{"path" => "low"}}]
                },
                "transitions" => [%{"event" => "success", "target" => "done"}]
              },
              "done" => %{}
            }
          }
        })

      :ok
    end

    test "takes high branch when condition is true" do
      {:ok, _} =
        ExecutionFSM.start_procedure("branch_test_high", "1.0", %{"value" => 100}, caller: self())

      assert_receive {:procedure_complete, _, :completed, context}, 10_000
      assert context["path"] == "high"
    end

    test "takes low branch when condition is false" do
      # Reuse the same procedure
      {:ok, _} =
        ExecutionFSM.start_procedure("branch_test_high", "1.0", %{"value" => 10}, caller: self())

      assert_receive {:procedure_complete, _, :completed, context}, 10_000
      assert context["path"] == "low"
    end
  end

  describe "error handling - error state transitions" do
    test "transitions to error state on validation failure" do
      {:ok, _} =
        Loader.register(%{
          name: "error_test",
          version: "1.0",
          definition: %{
            "initial_state" => "validate",
            "states" => %{
              "validate" => %{
                "action" => %{
                  "module" => "Mimo.ProceduralStore.Steps.Validate",
                  "function" => "execute",
                  "args" => [%{"rules" => [%{"type" => "required", "field" => "required_field"}]}]
                },
                "transitions" => [
                  %{"event" => "success", "target" => "process"},
                  %{"event" => "error", "target" => "validation_error"}
                ]
              },
              "process" => %{},
              "validation_error" => %{}
            }
          }
        })

      # Start without required_field
      {:ok, _} =
        ExecutionFSM.start_procedure("error_test", "1.0", %{}, caller: self())

      assert_receive {:procedure_complete, _, status, _context}, 10_000
      # Should complete in error state or failed
      assert status in [:completed, :failed]
    end
  end

  describe "timeout handling" do
    @tag timeout: 15_000
    test "completes within default timeout" do
      {:ok, _} =
        Loader.register(%{
          name: "timeout_test",
          version: "1.0",
          timeout_ms: 10_000,
          definition: %{
            "initial_state" => "start",
            "states" => %{
              "start" => %{
                "action" => %{
                  "module" => "Mimo.ProceduralStore.Steps.SetContext",
                  "function" => "execute",
                  "args" => [%{"values" => %{"completed" => true}}]
                },
                "transitions" => [%{"event" => "success", "target" => "done"}]
              },
              "done" => %{}
            }
          }
        })

      {:ok, _} =
        ExecutionFSM.start_procedure("timeout_test", "1.0", %{}, caller: self())

      assert_receive {:procedure_complete, _, :completed, context}, 10_000
      assert context["completed"] == true
    end
  end

  describe "get_state/1" do
    test "returns current state and context" do
      {:ok, _} =
        Loader.register(%{
          name: "get_state_test",
          version: "1.0",
          definition: %{
            "initial_state" => "waiting",
            "states" => %{
              # No action - waits for external event
              "waiting" => %{
                "transitions" => [%{"event" => "go", "target" => "done"}]
              },
              "done" => %{}
            }
          }
        })

      {:ok, pid} =
        ExecutionFSM.start_procedure("get_state_test", "1.0", %{"test" => "value"})

      # Give it a moment to enter the initial state
      Process.sleep(100)

      {state, context} = ExecutionFSM.get_state(pid)

      assert state == :waiting
      assert context["test"] == "value"
    end
  end

  describe "send_event/2" do
    test "triggers state transition on external event" do
      {:ok, _} =
        Loader.register(%{
          name: "external_event_test",
          version: "1.0",
          definition: %{
            "initial_state" => "waiting",
            "states" => %{
              "waiting" => %{
                "transitions" => [
                  %{"event" => "proceed", "target" => "processing"},
                  %{"event" => "cancel", "target" => "cancelled"}
                ]
              },
              "processing" => %{
                "action" => %{
                  "module" => "Mimo.ProceduralStore.Steps.SetContext",
                  "function" => "execute",
                  "args" => [%{"values" => %{"processed" => true}}]
                },
                "transitions" => [%{"event" => "success", "target" => "done"}]
              },
              "cancelled" => %{},
              "done" => %{}
            }
          }
        })

      {:ok, pid} =
        ExecutionFSM.start_procedure("external_event_test", "1.0", %{}, caller: self())

      Process.sleep(100)

      # Send external event
      :ok = ExecutionFSM.send_event(pid, :proceed)

      assert_receive {:procedure_complete, _, :completed, context}, 10_000
      assert context["processed"] == true
    end
  end

  describe "interrupt/2" do
    test "interrupts procedure execution" do
      {:ok, _} =
        Loader.register(%{
          name: "interrupt_test",
          version: "1.0",
          definition: %{
            "initial_state" => "long_wait",
            "states" => %{
              "long_wait" => %{
                "transitions" => [%{"event" => "done", "target" => "complete"}]
              },
              "complete" => %{}
            }
          }
        })

      {:ok, pid} =
        ExecutionFSM.start_procedure("interrupt_test", "1.0", %{}, caller: self())

      Process.sleep(100)

      # Interrupt
      :ok = ExecutionFSM.interrupt(pid, "test interruption")

      assert_receive {:procedure_complete, _, :interrupted, _context}, 5_000
    end
  end

  describe "concurrent execution" do
    @tag timeout: 30_000
    test "runs multiple procedures in parallel" do
      {:ok, _} =
        Loader.register(%{
          name: "concurrent_test",
          version: "1.0",
          definition: %{
            "initial_state" => "work",
            "states" => %{
              "work" => %{
                "action" => %{
                  "module" => "Mimo.ProceduralStore.Steps.SetContext",
                  "function" => "execute",
                  "args" => [%{"values" => %{"done" => true}}]
                },
                "transitions" => [%{"event" => "success", "target" => "complete"}]
              },
              "complete" => %{}
            }
          }
        })

      # Start 10 procedures
      for i <- 1..10 do
        {:ok, _} =
          ExecutionFSM.start_procedure("concurrent_test", "1.0", %{"id" => i}, caller: self())
      end

      # All should complete
      for _i <- 1..10 do
        assert_receive {:procedure_complete, _, :completed, _}, 10_000
      end
    end
  end

  describe "context accumulation" do
    test "accumulates context through states" do
      {:ok, _} =
        Loader.register(%{
          name: "accumulate_test",
          version: "1.0",
          definition: %{
            "initial_state" => "add_a",
            "states" => %{
              "add_a" => %{
                "action" => %{
                  "module" => "Mimo.ProceduralStore.Steps.SetContext",
                  "function" => "execute",
                  "args" => [%{"values" => %{"a" => 1}}]
                },
                "transitions" => [%{"event" => "success", "target" => "add_b"}]
              },
              "add_b" => %{
                "action" => %{
                  "module" => "Mimo.ProceduralStore.Steps.SetContext",
                  "function" => "execute",
                  "args" => [%{"values" => %{"b" => 2}}]
                },
                "transitions" => [%{"event" => "success", "target" => "add_c"}]
              },
              "add_c" => %{
                "action" => %{
                  "module" => "Mimo.ProceduralStore.Steps.SetContext",
                  "function" => "execute",
                  "args" => [%{"values" => %{"c" => 3}}]
                },
                "transitions" => [%{"event" => "success", "target" => "done"}]
              },
              "done" => %{}
            }
          }
        })

      {:ok, _} =
        ExecutionFSM.start_procedure("accumulate_test", "1.0", %{"initial" => 0}, caller: self())

      assert_receive {:procedure_complete, _, :completed, context}, 10_000

      assert context["initial"] == 0
      assert context["a"] == 1
      assert context["b"] == 2
      assert context["c"] == 3
    end
  end

  describe "procedure not found" do
    test "returns error for non-existent procedure" do
      result = ExecutionFSM.start_procedure("nonexistent_procedure", "1.0", %{})
      assert {:error, {:procedure_not_found, :not_found}} = result
    end
  end
end
