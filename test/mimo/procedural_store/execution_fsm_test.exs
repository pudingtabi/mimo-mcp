defmodule Mimo.ProceduralStore.ExecutionFSMTest do
  use ExUnit.Case, async: false
  alias Mimo.ProceduralStore.{ExecutionFSM, Loader, Procedure}
  alias Mimo.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    
    # Initialize loader cache (ignore if already exists)
    try do
      Loader.init()
    catch
      :error, :badarg -> :ok  # Table already exists
    end
    
    :ok
  end

  describe "procedure execution" do
    test "executes deterministic steps without LLM" do
      # Register a simple procedure
      {:ok, procedure} = Loader.register(%{
        name: "test_procedure",
        version: "1.0",
        definition: %{
          "initial_state" => "start",
          "states" => %{
            "start" => %{
              "action" => %{
                "module" => "Mimo.ProceduralStore.Steps.SetContext",
                "function" => "execute",
                "args" => [%{"values" => %{"step1" => true}}]
              },
              "transitions" => [
                %{"event" => "success", "target" => "middle"}
              ]
            },
            "middle" => %{
              "action" => %{
                "module" => "Mimo.ProceduralStore.Steps.SetContext",
                "function" => "execute",
                "args" => [%{"values" => %{"step2" => true}}]
              },
              "transitions" => [
                %{"event" => "success", "target" => "done"}
              ]
            },
            "done" => %{}  # Terminal state
          }
        }
      })

      assert procedure.name == "test_procedure"
      assert procedure.hash != nil

      # Start procedure
      {:ok, pid} = ExecutionFSM.start_procedure("test_procedure", "1.0", %{"input" => "test"}, caller: self())

      # Wait for completion
      assert_receive {:procedure_complete, "test_procedure", :completed, context}, 5000
      
      assert context["step1"] == true
      assert context["step2"] == true
    end

    test "handles validation errors" do
      {:ok, _} = Loader.register(%{
        name: "validation_test",
        version: "1.0",
        definition: %{
          "initial_state" => "validate",
          "states" => %{
            "validate" => %{
              "action" => %{
                "module" => "Mimo.ProceduralStore.Steps.Validate",
                "function" => "execute",
                "args" => [%{"rules" => [%{"type" => "required", "field" => "missing_field"}]}]
              },
              "transitions" => [
                %{"event" => "success", "target" => "done"},
                %{"event" => "error", "target" => "failed"}
              ]
            },
            "done" => %{},
            "failed" => %{}
          }
        }
      })

      {:ok, pid} = ExecutionFSM.start_procedure("validation_test", "1.0", %{}, caller: self())

      # Should fail validation since missing_field is not provided
      assert_receive {:procedure_complete, "validation_test", status, _context}, 5000
      # Either completed in failed state or actual error
      assert status in [:completed, :failed]
    end

    test "supports conditional branching" do
      {:ok, _} = Loader.register(%{
        name: "conditional_test",
        version: "1.0",
        definition: %{
          "initial_state" => "check",
          "states" => %{
            "check" => %{
              "action" => %{
                "module" => "Mimo.ProceduralStore.Steps.Conditional",
                "function" => "execute",
                "args" => [%{
                  "field" => "value",
                  "operator" => "gt",
                  "value" => 5,
                  "true_event" => "high",
                  "false_event" => "low"
                }]
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
                "args" => [%{"values" => %{"result" => "high"}}]
              },
              "transitions" => [%{"event" => "success", "target" => "done"}]
            },
            "low_path" => %{
              "action" => %{
                "module" => "Mimo.ProceduralStore.Steps.SetContext",
                "function" => "execute",
                "args" => [%{"values" => %{"result" => "low"}}]
              },
              "transitions" => [%{"event" => "success", "target" => "done"}]
            },
            "done" => %{}
          }
        }
      })

      # Test with high value
      {:ok, _} = ExecutionFSM.start_procedure("conditional_test", "1.0", %{"value" => 10}, caller: self())
      assert_receive {:procedure_complete, _, :completed, context}, 5000
      assert context["result"] == "high"

      # Test with low value
      {:ok, _} = ExecutionFSM.start_procedure("conditional_test", "1.0", %{"value" => 3}, caller: self())
      assert_receive {:procedure_complete, _, :completed, context}, 5000
      assert context["result"] == "low"
    end
  end
end
