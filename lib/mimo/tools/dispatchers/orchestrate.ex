defmodule Mimo.Tools.Dispatchers.Orchestrate do
  @moduledoc """
  Dispatcher for the orchestrate tool.

  Routes orchestration operations to Mimo.Orchestrator.
  Consolidates: run_procedure, list_procedures (Phase 3 consolidation)
  Includes SmartPlanner for intelligent tool selection (SPEC-2026-004)
  """

  require Logger

  alias Mimo.Orchestrator
  alias Mimo.Orchestration.SmartPlanner
  alias Mimo.ProceduralStore.ExecutionFSM
  alias Mimo.Repo

  @doc """
  Dispatch orchestrate tool operations.
  """
  def dispatch(args) do
    operation = Map.get(args, "operation", "execute")

    case operation do
      "execute" -> execute(args)
      "execute_plan" -> execute_plan(args)
      # NEW: Smart execution with learned tool selection
      "smart_execute" -> smart_execute(args)
      "smart_plan" -> smart_plan(args)
      "classify" -> classify(args)
      "status" -> status()
      # Consolidated from run_procedure tool
      "run_procedure" -> run_procedure(args)
      # Consolidated from list_procedures tool
      "list_procedures" -> list_procedures()
      _ -> {:error, "Unknown operation: #{operation}"}
    end
  end

  # --- Smart Orchestration (SPEC-2026-004) ---

  defp smart_execute(args) do
    description = Map.get(args, "description", "")

    if description == "" do
      {:error, "Description is required for smart_execute operation"}
    else
      # Use SmartPlanner to analyze and plan
      case SmartPlanner.plan(%{"description" => description}) do
        {:ok, plan} ->
          # Execute the plan and learn from outcome
          case SmartPlanner.execute_and_learn(plan) do
            {:ok, result} ->
              {:ok,
               %{
                 status: "success",
                 type: "smart_executed",
                 plan_id: plan.id,
                 tools_used: Enum.map(plan.tools, & &1.tool),
                 confidence: plan.confidence,
                 planning_latency_ms: plan.planning_latency_ms,
                 result: result
               }}

            {:error, reason} ->
              {:error, format_error(reason)}
          end

        {:blocked, reason} ->
          {:ok,
           %{
             status: "blocked",
             type: "pre_check_blocked",
             reason: reason,
             message:
               "Action blocked by SmartPlanner pre-check. Address warnings before proceeding."
           }}
      end
    end
  end

  defp smart_plan(args) do
    description = Map.get(args, "description", "")

    if description == "" do
      {:error, "Description is required for smart_plan operation"}
    else
      case SmartPlanner.plan(%{"description" => description}) do
        {:ok, plan} ->
          {:ok,
           %{
             status: "success",
             type: "plan_generated",
             plan_id: plan.id,
             tools:
               Enum.map(plan.tools, fn t ->
                 %{tool: t.tool, operation: t.operation}
               end),
             confidence: plan.confidence,
             complexity: plan.analysis.complexity,
             planning_latency_ms: plan.planning_latency_ms,
             message: "Use 'orchestrate operation=execute_plan' to execute this plan"
           }}

        {:blocked, reason} ->
          {:ok,
           %{
             status: "blocked",
             reason: reason
           }}
      end
    end
  end

  defp execute(args) do
    description = Map.get(args, "description", "")
    context = Map.get(args, "context", %{})
    timeout = Map.get(args, "timeout", 300_000)

    if description == "" do
      {:error, "Description is required for execute operation"}
    else
      task_spec = %{
        description: description,
        context: context
      }

      case Orchestrator.execute(task_spec, timeout: timeout) do
        {:ok, result} ->
          {:ok,
           %{
             status: "success",
             type: "executed",
             result: result
           }}

        {:escalate, reason, context} ->
          {:ok,
           %{
             status: "escalate",
             reason: reason,
             context: context,
             message: "Task requires LLM reasoning. Please handle this task directly."
           }}

        {:error, reason} ->
          {:error, format_error(reason)}
      end
    end
  end

  defp execute_plan(args) do
    plan = Map.get(args, "plan", [])
    timeout = Map.get(args, "timeout", 300_000)

    if plan == [] do
      {:error, "Plan is required for execute_plan operation"}
    else
      # Convert string keys to atoms for steps
      steps =
        Enum.map(plan, fn step ->
          %{
            tool: Map.get(step, "tool") |> String.to_existing_atom(),
            operation: Map.get(step, "operation"),
            args: Map.get(step, "args", %{}),
            on_error: Map.get(step, "on_error", "halt") |> String.to_existing_atom()
          }
        end)

      case Orchestrator.execute_plan(steps, timeout: timeout) do
        {:ok, result} ->
          {:ok,
           %{
             status: "success",
             type: "plan_executed",
             result: result
           }}

        {:error, reason} ->
          {:error, format_error(reason)}
      end
    end
  rescue
    ArgumentError ->
      {:error, "Invalid tool name in plan. Use: file, terminal, code, web, memory, knowledge"}
  end

  defp classify(args) do
    description = Map.get(args, "description", "")

    if description == "" do
      {:error, "Description is required for classify operation"}
    else
      task_spec = %{description: description}

      case Orchestrator.classify(task_spec) do
        {:ok, task_type, reason} ->
          {:ok,
           %{
             status: "success",
             classification: to_string(task_type),
             reason: reason,
             recommendation: classification_recommendation(task_type)
           }}

        {:error, reason} ->
          {:error, format_error(reason)}
      end
    end
  end

  defp status do
    metrics = Orchestrator.status()

    {:ok,
     %{
       status: "success",
       metrics: metrics
     }}
  end

  defp classification_recommendation(:procedure) do
    "This task matches a known procedure and will execute deterministically via ExecutionFSM."
  end

  defp classification_recommendation(:orchestrated) do
    "This task can be decomposed into tool steps and executed without LLM reasoning."
  end

  defp classification_recommendation(:needs_reasoning) do
    "This task requires LLM judgment. Consider handling it directly rather than through orchestration."
  end

  defp run_procedure(args) do
    name = Map.get(args, "name")
    version = Map.get(args, "version", "latest")
    context = Map.get(args, "context", %{})
    async = Map.get(args, "async", false)
    timeout = Map.get(args, "timeout", 60_000)

    cond do
      is_nil(name) or name == "" ->
        {:error, "Procedure name is required"}

      async ->
        # Async execution - start and return ID
        case ExecutionFSM.start_procedure(name, version, context) do
          {:ok, pid} ->
            # Get execution ID from the FSM if available
            exec_id = "exec_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"

            {:ok,
             %{
               status: "started",
               execution_id: exec_id,
               procedure: name,
               version: version,
               pid: inspect(pid)
             }}

          {:error, reason} ->
            {:error, format_error(reason)}
        end

      true ->
        # Sync execution - wait for completion
        case ExecutionFSM.start_procedure(name, version, context) do
          {:ok, pid} ->
            ref = Process.monitor(pid)

            receive do
              {:DOWN, ^ref, :process, ^pid, :normal} ->
                {:ok, %{status: "completed", procedure: name}}

              {:DOWN, ^ref, :process, ^pid, reason} ->
                {:error, "Procedure failed: #{inspect(reason)}"}
            after
              timeout ->
                Process.exit(pid, :kill)
                {:error, "Procedure timed out after #{timeout}ms"}
            end

          {:error, {:procedure_not_found, _}} ->
            {:error,
             "Procedure '#{name}' not found. Use 'orchestrate operation=list_procedures' to see available procedures."}

          {:error, reason} ->
            {:error, format_error(reason)}
        end
    end
  end

  defp list_procedures do
    import Ecto.Query

    procedures =
      Mimo.ProceduralStore.Procedure
      |> where([p], p.active == true)
      |> order_by([p], asc: p.name, desc: p.version)
      |> Repo.all()
      |> Enum.map(fn p ->
        %{
          name: p.name,
          version: p.version,
          description: p.description,
          timeout_ms: p.timeout_ms,
          max_retries: p.max_retries
        }
      end)

    {:ok,
     %{
       status: "success",
       count: length(procedures),
       procedures: procedures
     }}
  rescue
    e ->
      Logger.warning("Failed to list procedures: #{Exception.message(e)}")

      {:ok,
       %{
         status: "success",
         count: 0,
         procedures: [],
         note: "No procedures registered yet"
       }}
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: to_string(reason)

  defp format_error({:step_failed, step_id, reason}),
    do: "Step #{step_id} failed: #{inspect(reason)}"

  defp format_error({:procedure_failed, reason}), do: "Procedure failed: #{inspect(reason)}"
  defp format_error({:procedure_not_found, name}), do: "Procedure '#{name}' not found"
  defp format_error(reason), do: inspect(reason)
end
