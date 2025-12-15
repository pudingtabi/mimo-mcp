defmodule Mimo.Tools.Dispatchers.Autonomous do
  @moduledoc """
  Dispatcher for the autonomous task execution tool.

  Part of SPEC-071: Autonomous Task Execution.

  ## Operations

  - `queue` - Add a task to the autonomous execution queue
  - `status` - Get the current status of the task runner
  - `pause` - Pause autonomous task execution
  - `resume` - Resume autonomous task execution
  - `reset_circuit` - Reset the circuit breaker after resolving issues
  - `list_queue` - List all queued tasks
  - `clear_queue` - Clear all queued tasks

  ## Usage via MCP

      autonomous operation=queue type="test" description="Run test suite" command="mix test"
      autonomous operation=status
      autonomous operation=pause
      autonomous operation=resume

  ## Safety

  All tasks pass through SafetyGuard before execution.
  Dangerous operations (rm -rf, shutdown, etc.) are automatically blocked.
  """

  require Logger

  alias Mimo.Autonomous.{TaskRunner, SafetyGuard}

  @doc """
  Dispatch autonomous operation based on args.
  """
  def dispatch(args) do
    op = Map.get(args, "operation", "status")
    do_dispatch(op, args)
  end

  # Multi-head dispatch
  defp do_dispatch("queue", args), do: dispatch_queue(args)
  defp do_dispatch("status", _args), do: dispatch_status()
  defp do_dispatch("pause", _args), do: dispatch_pause()
  defp do_dispatch("resume", _args), do: dispatch_resume()
  defp do_dispatch("reset_circuit", _args), do: dispatch_reset_circuit()
  defp do_dispatch("list_queue", _args), do: dispatch_list_queue()
  defp do_dispatch("clear_queue", _args), do: dispatch_clear_queue()
  defp do_dispatch("check_safety", args), do: dispatch_check_safety(args)

  defp do_dispatch(op, _args) do
    {:error,
     "Unknown autonomous operation: #{op}. Valid: queue, status, pause, resume, reset_circuit, list_queue, clear_queue"}
  end

  # =============================================================================
  # OPERATION DISPATCHERS
  # =============================================================================

  defp dispatch_queue(args) do
    # Build task spec from args
    task_spec = %{
      "type" => Map.get(args, "type", "general"),
      "description" => Map.get(args, "description"),
      "command" => Map.get(args, "command"),
      "path" => Map.get(args, "path"),
      "query" => Map.get(args, "query")
    }

    # Remove nil values
    task_spec = Map.reject(task_spec, fn {_k, v} -> is_nil(v) end)

    case TaskRunner.queue_task(task_spec) do
      {:ok, task_id} ->
        {:ok,
         %{
           status: "queued",
           task_id: task_id,
           message: "Task queued successfully. It will be executed automatically.",
           type: Map.get(task_spec, "type"),
           description: Map.get(task_spec, "description")
         }}

      {:error, :blocked_dangerous_command} ->
        {:error,
         %{
           status: "blocked",
           reason: :safety_violation,
           message: SafetyGuard.explain_block(:blocked_dangerous_command)
         }}

      {:error, :blocked_protected_path} ->
        {:error,
         %{
           status: "blocked",
           reason: :safety_violation,
           message: SafetyGuard.explain_block(:blocked_protected_path)
         }}

      {:error, :missing_description} ->
        {:error,
         %{
           status: "invalid",
           reason: :missing_description,
           message:
             "Task description is required. Provide a clear description of what the task should do."
         }}

      {:error, reason} ->
        {:error,
         %{
           status: "failed",
           reason: reason,
           message: SafetyGuard.explain_block(reason)
         }}
    end
  end

  defp dispatch_status do
    status = TaskRunner.status()

    # Format for display
    {:ok,
     %{
       status: status.status,
       paused: status.paused,
       queued_tasks: status.queued,
       running_tasks: status.running,
       completed_tasks: status.completed,
       failed_tasks: status.failed,
       circuit_breaker: %{
         state: status.circuit_state,
         details: Map.get(status, :circuit_details)
       },
       message: format_status_message(status)
     }}
  end

  defp dispatch_pause do
    TaskRunner.pause()

    {:ok,
     %{
       status: "paused",
       message:
         "Autonomous task execution paused. Running tasks will complete, but no new tasks will start. Use 'resume' to continue."
     }}
  end

  defp dispatch_resume do
    TaskRunner.resume()

    {:ok,
     %{
       status: "resumed",
       message: "Autonomous task execution resumed. Queued tasks will begin executing."
     }}
  end

  defp dispatch_reset_circuit do
    TaskRunner.reset_circuit()

    {:ok,
     %{
       status: "reset",
       message: "Circuit breaker reset to closed state. Task execution will resume normally."
     }}
  end

  defp dispatch_list_queue do
    queue = TaskRunner.list_queue()

    tasks =
      Enum.map(queue, fn task ->
        %{
          id: task.id,
          type: task.type,
          description: task.description,
          created_at: DateTime.to_iso8601(task.created_at),
          hints_count: length(task.hints || [])
        }
      end)

    {:ok,
     %{
       count: length(tasks),
       tasks: tasks,
       message: if(tasks == [], do: "No tasks in queue", else: "#{length(tasks)} task(s) queued")
     }}
  end

  defp dispatch_clear_queue do
    TaskRunner.clear_queue()

    {:ok,
     %{
       status: "cleared",
       message: "All queued tasks have been cleared. Running tasks will complete."
     }}
  end

  defp dispatch_check_safety(args) do
    task_spec = %{
      "command" => Map.get(args, "command"),
      "path" => Map.get(args, "path"),
      "description" => Map.get(args, "description")
    }

    case SafetyGuard.check_allowed(task_spec) do
      :ok ->
        {:ok,
         %{
           safe: true,
           message: "This task passes safety checks and can be executed."
         }}

      {:error, reason} ->
        {:ok,
         %{
           safe: false,
           reason: reason,
           message: SafetyGuard.explain_block(reason)
         }}
    end
  end

  # =============================================================================
  # HELPERS
  # =============================================================================

  defp format_status_message(status) do
    circuit_msg =
      case status.circuit_state do
        :open -> " â ï¸ Circuit breaker OPEN - tasks paused due to failures."
        :half_open -> " â¡ Circuit breaker testing - allowing limited tasks."
        _ -> ""
      end

    paused_msg = if status.paused, do: " (PAUSED)", else: ""

    "TaskRunner #{status.status}#{paused_msg}: " <>
      "#{status.queued} queued, #{status.running} running, " <>
      "#{status.completed} completed, #{status.failed} failed." <>
      circuit_msg
  end
end
