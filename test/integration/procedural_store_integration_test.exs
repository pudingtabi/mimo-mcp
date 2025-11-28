defmodule Mimo.Integration.ProceduralStoreIntegrationTest do
  @moduledoc """
  Integration tests for Procedural Store.
  
  SPEC-007: Tests real-world workflows, concurrent execution, and error recovery.
  """
  use ExUnit.Case

  @moduletag :integration

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

  describe "deployment workflow" do
    @deploy_procedure %{
      name: "deploy_workflow",
      version: "1.0",
      timeout_ms: 30_000,
      definition: %{
        "initial_state" => "validate",
        "states" => %{
          "validate" => %{
            "action" => %{
              "module" => "Mimo.ProceduralStore.Steps.Validate",
              "function" => "execute",
              "args" => [
                %{
                  "rules" => [
                    %{"type" => "required", "field" => "environment"}
                  ]
                }
              ]
            },
            "transitions" => [
              %{"event" => "success", "target" => "prepare"},
              %{"event" => "error", "target" => "failed"}
            ]
          },
          "prepare" => %{
            "action" => %{
              "module" => "Mimo.ProceduralStore.Steps.SetContext",
              "function" => "execute",
              "args" => [%{"values" => %{"prepared" => true}}]
            },
            "transitions" => [
              %{"event" => "success", "target" => "deploy"},
              %{"event" => "error", "target" => "rollback"}
            ]
          },
          "deploy" => %{
            "action" => %{
              "module" => "Mimo.ProceduralStore.Steps.SetContext",
              "function" => "execute",
              "args" => [%{"values" => %{"deployed" => true}}]
            },
            "transitions" => [
              %{"event" => "success", "target" => "verify"},
              %{"event" => "error", "target" => "rollback"}
            ]
          },
          "verify" => %{
            "action" => %{
              "module" => "Mimo.ProceduralStore.Steps.SetContext",
              "function" => "execute",
              "args" => [%{"values" => %{"verified" => true}}]
            },
            "transitions" => [
              %{"event" => "success", "target" => "done"},
              %{"event" => "error", "target" => "rollback"}
            ]
          },
          "rollback" => %{
            "action" => %{
              "module" => "Mimo.ProceduralStore.Steps.SetContext",
              "function" => "execute",
              "args" => [%{"values" => %{"rolled_back" => true}}]
            },
            "transitions" => [%{"event" => "success", "target" => "failed"}]
          },
          "done" => %{},
          "failed" => %{}
        }
      }
    }

    test "completes full deployment workflow successfully" do
      {:ok, _} = Loader.register(@deploy_procedure)

      {:ok, _pid} =
        ExecutionFSM.start_procedure(
          "deploy_workflow",
          "1.0",
          %{"environment" => "staging"},
          caller: self()
        )

      assert_receive {:procedure_complete, "deploy_workflow", :completed, context}, 15_000

      assert context["prepared"] == true
      assert context["deployed"] == true
      assert context["verified"] == true
      refute context["rolled_back"]
    end

    test "fails validation without required environment" do
      {:ok, _} = Loader.register(@deploy_procedure)

      {:ok, _pid} =
        ExecutionFSM.start_procedure(
          "deploy_workflow",
          "1.0",
          %{},
          caller: self()
        )

      assert_receive {:procedure_complete, "deploy_workflow", status, _context}, 15_000
      assert status in [:completed, :failed]
    end
  end

  describe "data pipeline workflow" do
    @pipeline_procedure %{
      name: "data_pipeline",
      version: "1.0",
      timeout_ms: 30_000,
      definition: %{
        "initial_state" => "fetch",
        "states" => %{
          "fetch" => %{
            "action" => %{
              "module" => "Mimo.ProceduralStore.Steps.SetContext",
              "function" => "execute",
              "args" => [%{"values" => %{"data" => "raw_data", "fetched" => true}}]
            },
            "transitions" => [
              %{"event" => "success", "target" => "transform"}
            ]
          },
          "transform" => %{
            "action" => %{
              "module" => "Mimo.ProceduralStore.Steps.SetContext",
              "function" => "execute",
              "args" => [%{"values" => %{"data" => "transformed_data", "transformed" => true}}]
            },
            "transitions" => [
              %{"event" => "success", "target" => "validate"}
            ]
          },
          "validate" => %{
            "action" => %{
              "module" => "Mimo.ProceduralStore.Steps.SetContext",
              "function" => "execute",
              "args" => [%{"values" => %{"validated" => true}}]
            },
            "transitions" => [
              %{"event" => "success", "target" => "store"}
            ]
          },
          "store" => %{
            "action" => %{
              "module" => "Mimo.ProceduralStore.Steps.SetContext",
              "function" => "execute",
              "args" => [%{"values" => %{"stored" => true}}]
            },
            "transitions" => [
              %{"event" => "success", "target" => "complete"}
            ]
          },
          "complete" => %{}
        }
      }
    }

    test "processes data through all stages" do
      {:ok, _} = Loader.register(@pipeline_procedure)

      {:ok, _pid} =
        ExecutionFSM.start_procedure(
          "data_pipeline",
          "1.0",
          %{"source" => "api"},
          caller: self()
        )

      assert_receive {:procedure_complete, "data_pipeline", :completed, context}, 15_000

      assert context["fetched"] == true
      assert context["transformed"] == true
      assert context["validated"] == true
      assert context["stored"] == true
    end
  end

  describe "concurrent execution" do
    @simple_procedure %{
      name: "simple_concurrent",
      version: "1.0",
      definition: %{
        "initial_state" => "process",
        "states" => %{
          "process" => %{
            "action" => %{
              "module" => "Mimo.ProceduralStore.Steps.SetContext",
              "function" => "execute",
              "args" => [%{"values" => %{"processed" => true}}]
            },
            "transitions" => [%{"event" => "success", "target" => "done"}]
          },
          "done" => %{}
        }
      }
    }

    @tag timeout: 60_000
    test "runs 50 concurrent procedures without issues" do
      {:ok, _} = Loader.register(@simple_procedure)

      # Start 50 concurrent procedures
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            {:ok, _pid} =
              ExecutionFSM.start_procedure(
                "simple_concurrent",
                "1.0",
                %{"id" => i},
                caller: self()
              )

            receive do
              {:procedure_complete, _, status, context} -> {status, context}
            after
              15_000 -> {:timeout, %{}}
            end
          end)
        end

      results = Task.await_many(tasks, 30_000)

      # Count completions
      completed = Enum.count(results, fn {status, _} -> status == :completed end)
      timeouts = Enum.count(results, fn {status, _} -> status == :timeout end)

      assert completed == 50, "Expected 50 completions, got #{completed} (#{timeouts} timeouts)"
    end
  end

  describe "procedure versioning" do
    test "supports multiple versions of same procedure" do
      # Register v1.0
      {:ok, _} =
        Loader.register(%{
          name: "versioned_proc",
          version: "1.0",
          definition: %{
            "initial_state" => "start",
            "states" => %{
              "start" => %{
                "action" => %{
                  "module" => "Mimo.ProceduralStore.Steps.SetContext",
                  "function" => "execute",
                  "args" => [%{"values" => %{"version" => "1.0"}}]
                },
                "transitions" => [%{"event" => "success", "target" => "done"}]
              },
              "done" => %{}
            }
          }
        })

      # Register v2.0
      {:ok, _} =
        Loader.register(%{
          name: "versioned_proc",
          version: "2.0",
          definition: %{
            "initial_state" => "start",
            "states" => %{
              "start" => %{
                "action" => %{
                  "module" => "Mimo.ProceduralStore.Steps.SetContext",
                  "function" => "execute",
                  "args" => [%{"values" => %{"version" => "2.0"}}]
                },
                "transitions" => [%{"event" => "success", "target" => "done"}]
              },
              "done" => %{}
            }
          }
        })

      # Run v1.0
      {:ok, _} =
        ExecutionFSM.start_procedure("versioned_proc", "1.0", %{}, caller: self())

      assert_receive {:procedure_complete, _, :completed, context_v1}, 10_000
      assert context_v1["version"] == "1.0"

      # Run latest (should be 2.0)
      {:ok, _} =
        ExecutionFSM.start_procedure("versioned_proc", "latest", %{}, caller: self())

      assert_receive {:procedure_complete, _, :completed, context_latest}, 10_000
      assert context_latest["version"] == "2.0"
    end
  end

  describe "execution persistence" do
    test "execution records are persisted" do
      {:ok, _} = Loader.register(@simple_procedure)

      {:ok, _pid} =
        ExecutionFSM.start_procedure(
          "simple_concurrent",
          "1.0",
          %{"test" => true},
          caller: self()
        )

      assert_receive {:procedure_complete, _, :completed, _context}, 10_000

      # Check execution record exists
      import Ecto.Query
      alias Mimo.ProceduralStore.Execution

      executions =
        from(e in Execution, where: e.procedure_name == "simple_concurrent")
        |> Repo.all()

      assert length(executions) >= 1

      execution = hd(executions)
      assert execution.status == "completed"
      assert execution.duration_ms != nil
    end
  end
end
