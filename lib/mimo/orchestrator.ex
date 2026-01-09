defmodule Mimo.Orchestrator do
  @moduledoc """
  Multi-Tool Orchestrator for Mimo.

  Executes complex tasks by orchestrating multiple tools internally,
  avoiding the token overhead of spawning LLM subagents.

  ## Architecture

  ```
  Task → Classifier → Router
                        ↓
          ┌─────────────┼─────────────┐
          ↓             ↓             ↓
     Procedure    Orchestrated    Escalate
     (FSM)        (ToolExecutor)  (LLM call)
          ↓             ↓             ↓
          └─────────────┴─────────────┘
                        ↓
                  ResultAggregator
  ```

  ## Benefits over Subagents

  - **Token efficiency**: No new context per task (saves 20-50K tokens/subagent)
  - **Observability**: All tool calls visible and logged
  - **Reliability**: Deterministic execution for known patterns
  - **Speed**: Direct tool calls vs LLM latency

  ## Usage

      # Execute a task with automatic routing
      {:ok, result} = Orchestrator.execute(%{
        description: "Run tests and fix failures",
        tools: [:terminal, :file, :code]
      })

      # Execute with explicit plan
      {:ok, result} = Orchestrator.execute_plan([
        %{tool: :terminal, operation: "execute", args: %{command: "mix test"}},
        %{tool: :code, operation: "diagnose", args: %{path: "lib/"}}
      ])
  """

  use GenServer
  require Logger

  alias Mimo.Autonomous.GoalDecomposer
  alias Mimo.ProceduralStore.ExecutionFSM
  alias Mimo.Tools

  # Task classification types
  @type task_type :: :procedure | :orchestrated | :needs_reasoning

  # Execution result
  @type result :: {:ok, map()} | {:error, term()} | {:escalate, String.t(), map()}

  # Task specification
  @type task_spec :: %{
          optional(:id) => String.t(),
          required(:description) => String.t(),
          optional(:type) => String.t(),
          optional(:tools) => [atom()],
          optional(:plan) => [step()],
          optional(:context) => map()
        }

  # Execution step
  @type step :: %{
          required(:tool) => atom(),
          required(:operation) => String.t(),
          optional(:args) => map(),
          optional(:depends_on) => [String.t()],
          optional(:on_error) => :halt | :continue | :escalate
        }

  # Execution state
  @type exec_state :: %{
          task_id: String.t(),
          steps_completed: [String.t()],
          results: %{String.t() => term()},
          errors: [map()],
          started_at: DateTime.t()
        }

  @doc """
  Start the Orchestrator GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Execute a task with automatic classification and routing.

  The task is classified as:
  - `:procedure` - Known workflow, executed via ExecutionFSM
  - `:orchestrated` - Can be decomposed, executed via ToolExecutor
  - `:needs_reasoning` - Requires LLM, returns escalation request

  ## Options

  - `:timeout` - Execution timeout in ms (default: 5 minutes)
  - `:parallel` - Allow parallel step execution (default: false)
  - `:max_steps` - Maximum steps before forcing escalation (default: 20)
  """
  @spec execute(task_spec(), keyword()) :: result()
  def execute(task_spec, opts \\ []) do
    GenServer.call(__MODULE__, {:execute, task_spec, opts}, opts[:timeout] || 300_000)
  end

  @doc """
  Execute a pre-defined plan directly.

  Skips classification and decomposition - executes steps in order.
  """
  @spec execute_plan([step()], keyword()) :: result()
  def execute_plan(steps, opts \\ []) do
    GenServer.call(__MODULE__, {:execute_plan, steps, opts}, opts[:timeout] || 300_000)
  end

  @doc """
  Classify a task without executing it.

  Returns the classification and reasoning.
  """
  @spec classify(task_spec()) :: {:ok, task_type(), String.t()}
  def classify(task_spec) do
    GenServer.call(__MODULE__, {:classify, task_spec})
  end

  @doc """
  Get orchestrator status and metrics.
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @impl true
  def init(_opts) do
    state = %{
      executions: %{},
      metrics: %{
        total_executed: 0,
        by_type: %{procedure: 0, orchestrated: 0, escalated: 0},
        avg_steps: 0,
        total_tools_called: 0
      }
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:execute, task_spec, opts}, _from, state) do
    task_id = generate_task_id()
    start_time = System.monotonic_time(:millisecond)
    Logger.info("[Orchestrator] Executing task #{task_id}: #{task_spec[:description]}")

    # Classify the task
    {task_type, reason} = do_classify(task_spec)

    # Emit start telemetry
    emit_telemetry([:task, :start], %{count: 1}, %{
      task_id: task_id,
      task_type: task_type,
      description: task_spec[:description],
      reason: reason
    })

    # Route to appropriate executor
    result =
      case task_type do
        :procedure ->
          execute_as_procedure(task_spec, opts)

        :orchestrated ->
          execute_as_orchestrated(task_spec, task_id, opts)

        :needs_reasoning ->
          {:escalate, reason, %{task: task_spec, context: build_context(state)}}
      end

    # Emit completion telemetry
    duration = System.monotonic_time(:millisecond) - start_time

    emit_telemetry([:task, :complete], %{duration_ms: duration}, %{
      task_id: task_id,
      task_type: task_type,
      success: match?({:ok, _}, result),
      escalated: match?({:escalate, _, _}, result)
    })

    # Update metrics
    new_state = update_metrics(state, task_type, result)

    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:execute_plan, steps, opts}, _from, state) do
    task_id = generate_task_id()
    start_time = System.monotonic_time(:millisecond)
    step_count = length(steps)

    # Emit plan start telemetry
    emit_telemetry([:plan, :start], %{step_count: step_count}, %{
      task_id: task_id,
      steps: Enum.map(steps, fn s -> "#{s[:tool]}.#{s[:operation]}" end)
    })

    result = execute_steps(steps, task_id, opts)

    # Emit plan completion telemetry
    duration = System.monotonic_time(:millisecond) - start_time

    emit_telemetry([:plan, :complete], %{duration_ms: duration, step_count: step_count}, %{
      task_id: task_id,
      success: match?({:ok, _}, result)
    })

    new_state = update_metrics(state, :orchestrated, result)
    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:classify, task_spec}, _from, state) do
    {task_type, reason} = do_classify(task_spec)
    {:reply, {:ok, task_type, reason}, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.metrics, state}
  end

  @procedure_patterns [
    {~r/\b(run|execute)\s+(tests?|test suite)\b/i, "test_suite"},
    {~r/\b(compile|build)\s*(project|code)?\b/i, "compile"},
    {~r/\b(format|fmt)\s*(code|files?)?\b/i, "format"},
    {~r/\bcredo\b/i, "credo"},
    {~r/\bdialyz(er|e)\b/i, "dialyzer"},
    {~r/\b(lint|linter)\b/i, "lint"}
  ]

  @orchestration_patterns [
    ~r/\b(fix|resolve|address)\s+(errors?|warnings?|issues?)\b/i,
    ~r/\b(search|find|locate)\s+(and|then)\s+(fix|update|change)\b/i,
    ~r/\b(read|check)\s+.*\s+(and|then)\s+(update|modify)\b/i,
    ~r/\b(analyze|diagnose)\s+.*\s+(and|then)\s+/i
  ]

  @reasoning_patterns [
    ~r/\b(implement|create|design|architect)\b/i,
    ~r/\b(refactor|restructure|redesign)\b/i,
    ~r/\b(explain|understand|why|how does)\b/i,
    ~r/\b(best|better|optimal|should i)\b/i,
    ~r/\b(complex|complicated|tricky)\b/i,
    ~r/\b(oauth|authentication|authorization|security)\b/i,
    ~r/\b(database|schema|migration)\s+(design|structure)\b/i,
    ~r/\b(api|endpoint)\s+(design|architecture)\b/i
  ]

  defp do_classify(task_spec) do
    description = task_spec[:description] || ""

    cond do
      # Check for exact procedure match first
      procedure = match_procedure(description) ->
        {:procedure, "Matched procedure: #{procedure}"}

      # Check if it's clearly a reasoning task
      matches_patterns?(description, @reasoning_patterns) ->
        {:needs_reasoning, "Task requires creative reasoning or decision-making"}

      # Check if it can be orchestrated
      matches_patterns?(description, @orchestration_patterns) ->
        {:orchestrated, "Task can be decomposed into tool sequence"}

      # Check if GoalDecomposer thinks it's complex enough
      decomposable?(task_spec) ->
        {:orchestrated, "GoalDecomposer identified subtasks"}

      # Default to orchestrated for simple tasks, escalate for ambiguous
      String.length(description) < 50 ->
        {:orchestrated, "Simple task, attempting direct execution"}

      true ->
        {:needs_reasoning, "Ambiguous task, requires LLM judgment"}
    end
  end

  defp match_procedure(description) do
    Enum.find_value(@procedure_patterns, fn {pattern, name} ->
      if Regex.match?(pattern, description), do: name
    end)
  end

  defp matches_patterns?(text, patterns) do
    Enum.any?(patterns, &Regex.match?(&1, text))
  end

  defp decomposable?(task_spec) do
    case GoalDecomposer.maybe_decompose(task_spec) do
      {:decomposed, subtasks, _deps} when length(subtasks) > 1 -> true
      _ -> false
    end
  end

  defp execute_as_procedure(task_spec, opts) do
    description = task_spec[:description] || ""

    case match_procedure(description) do
      nil ->
        {:error, :no_matching_procedure}

      procedure_name ->
        context = Map.get(task_spec, :context, %{})
        timeout = Keyword.get(opts, :timeout, 60_000)

        # Try to start the procedure from ProceduralStore
        case ExecutionFSM.start_procedure(procedure_name, "latest", context) do
          {:ok, pid} ->
            ref = Process.monitor(pid)

            receive do
              {:DOWN, ^ref, :process, ^pid, :normal} ->
                {:ok, %{procedure: procedure_name, status: :completed}}

              {:DOWN, ^ref, :process, ^pid, reason} ->
                {:error, {:procedure_failed, reason}}
            after
              timeout ->
                Process.exit(pid, :kill)
                {:error, :timeout}
            end

          {:error, {:procedure_not_found, _}} ->
            # Fallback: execute the procedure's command directly
            Logger.info(
              "[Orchestrator] Procedure #{procedure_name} not found, executing command directly"
            )

            execute_procedure_command(procedure_name, context, timeout)

          {:error, reason} ->
            {:error, {:procedure_start_failed, reason}}
        end
    end
  end

  # Direct command execution for known procedures
  defp execute_procedure_command("test_suite", context, timeout) do
    path = Map.get(context, :path, Map.get(context, "path", "."))
    command = "cd #{path} && mix test"
    execute_shell_command(command, timeout)
  end

  defp execute_procedure_command("compile", context, timeout) do
    path = Map.get(context, :path, Map.get(context, "path", "."))
    command = "cd #{path} && mix compile"
    execute_shell_command(command, timeout)
  end

  defp execute_procedure_command("format", context, timeout) do
    path = Map.get(context, :path, Map.get(context, "path", "."))
    command = "cd #{path} && mix format"
    execute_shell_command(command, timeout)
  end

  defp execute_procedure_command("credo", context, timeout) do
    path = Map.get(context, :path, Map.get(context, "path", "."))
    command = "cd #{path} && mix credo"
    execute_shell_command(command, timeout)
  end

  defp execute_procedure_command("dialyzer", context, timeout) do
    path = Map.get(context, :path, Map.get(context, "path", "."))
    command = "cd #{path} && mix dialyzer"
    execute_shell_command(command, timeout)
  end

  defp execute_procedure_command("lint", context, timeout) do
    execute_procedure_command("credo", context, timeout)
  end

  defp execute_procedure_command(procedure_name, _context, _timeout) do
    {:error, {:unknown_procedure, procedure_name}}
  end

  defp execute_shell_command(command, timeout) do
    Logger.debug("[Orchestrator] Executing: #{command}")

    case Tools.dispatch("terminal", %{
           "operation" => "execute",
           "command" => command,
           "timeout" => timeout
         }) do
      {:ok, result} ->
        {:ok, %{type: :shell_command, command: command, result: result}}

      {:error, reason} ->
        {:error, {:command_failed, command, reason}}
    end
  end

  defp execute_as_orchestrated(task_spec, task_id, opts) do
    # Decompose the task
    case GoalDecomposer.maybe_decompose(task_spec) do
      {:simple, _task} ->
        # Single-step task, execute directly
        execute_single_tool(task_spec, opts)

      {:decomposed, subtasks, _dependencies} ->
        # Convert subtasks to execution steps
        steps = subtasks_to_steps(subtasks)
        execute_steps(steps, task_id, opts)
    end
  end

  defp execute_single_tool(task_spec, _opts) do
    # Infer tool from description
    description = task_spec[:description] || ""

    {tool, operation, args} = infer_tool_call(description)

    case Tools.dispatch(tool, %{"operation" => operation} |> Map.merge(args)) do
      {:ok, result} -> {:ok, %{tool: tool, result: result}}
      {:error, reason} -> {:error, {:tool_failed, tool, reason}}
    end
  end

  defp execute_steps(steps, task_id, opts) do
    max_steps = Keyword.get(opts, :max_steps, 20)

    exec_state = %{
      task_id: task_id,
      steps_completed: [],
      results: %{},
      errors: [],
      started_at: DateTime.utc_now()
    }

    steps
    |> Enum.take(max_steps)
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, exec_state}, fn {step, idx}, {:ok, state} ->
      step_id = "step_#{idx}"
      on_error = Map.get(step, :on_error, :halt)

      case execute_step(step, state) do
        {:ok, result} ->
          new_state = %{
            state
            | steps_completed: [step_id | state.steps_completed],
              results: Map.put(state.results, step_id, result)
          }

          {:cont, {:ok, new_state}}

        {:error, reason} ->
          handle_step_error(reason, step_id, step, state, on_error)
      end
    end)
    |> case do
      {:ok, final_state} ->
        {:ok,
         %{
           task_id: task_id,
           steps_completed: length(final_state.steps_completed),
           results: final_state.results,
           errors: final_state.errors,
           duration_ms: DateTime.diff(DateTime.utc_now(), final_state.started_at, :millisecond)
         }}

      other ->
        other
    end
  end

  defp handle_step_error(reason, step_id, _step, state, :continue) do
    new_state = %{
      state
      | errors: [%{step: step_id, error: reason} | state.errors]
    }

    {:cont, {:ok, new_state}}
  end

  defp handle_step_error(reason, step_id, step, state, :escalate) do
    {:halt, {:escalate, "Step #{step_id} failed", %{step: step, error: reason, state: state}}}
  end

  defp handle_step_error(reason, step_id, _step, _state, _halt) do
    {:halt, {:error, {:step_failed, step_id, reason}}}
  end

  defp execute_step(step, _state) do
    tool = step[:tool] || step["tool"]
    operation = step[:operation] || step["operation"]
    args = step[:args] || step["args"] || %{}

    tool_args = Map.put(args, "operation", operation)

    Logger.debug("[Orchestrator] Executing step: #{tool}.#{operation}")

    case Tools.dispatch(to_string(tool), tool_args) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp subtasks_to_steps(subtasks) do
    Enum.map(subtasks, fn subtask ->
      {tool, operation, args} = infer_tool_call(subtask.description)

      %{
        id: subtask.id,
        tool: tool,
        operation: operation,
        args: args,
        depends_on: subtask.depends_on || [],
        on_error: :halt
      }
    end)
  end

  defp infer_tool_call(description) do
    cond do
      String.contains?(description, ["test", "compile", "mix", "run"]) ->
        {:terminal, "execute", %{"command" => infer_command(description)}}

      String.contains?(description, ["read", "file", "content"]) ->
        {:file, "read", %{"path" => "."}}

      String.contains?(description, ["search", "find", "grep"]) ->
        {:file, "search", %{"pattern" => extract_pattern(description)}}

      String.contains?(description, ["diagnose", "error", "lint"]) ->
        {:code, "diagnose", %{"path" => "."}}

      true ->
        {:terminal, "execute", %{"command" => "echo 'Unknown task: #{description}'"}}
    end
  end

  defp infer_command(description) do
    cond do
      String.contains?(description, "test") -> "mix test"
      String.contains?(description, "compile") -> "mix compile"
      String.contains?(description, "format") -> "mix format"
      String.contains?(description, "credo") -> "mix credo"
      true -> "echo '#{description}'"
    end
  end

  defp extract_pattern(description) do
    # Simple extraction - could be improved
    description
    |> String.split()
    |> Enum.find("TODO", &(String.length(&1) > 3))
  end

  defp generate_task_id do
    "orch_" <> Base.encode32(:crypto.strong_rand_bytes(8), padding: false, case: :lower)
  end

  defp build_context(state) do
    %{
      metrics: state.metrics,
      recent_results: state.executions |> Map.values() |> Enum.take(5)
    }
  end

  defp update_metrics(state, task_type, result) do
    type_key =
      case task_type do
        :procedure -> :procedure
        :orchestrated -> :orchestrated
        :needs_reasoning -> :escalated
      end

    steps_count =
      case result do
        {:ok, %{steps_completed: n}} when is_integer(n) -> n
        _ -> 1
      end

    new_metrics = %{
      state.metrics
      | total_executed: state.metrics.total_executed + 1,
        by_type: Map.update!(state.metrics.by_type, type_key, &(&1 + 1)),
        total_tools_called: state.metrics.total_tools_called + steps_count
    }

    %{state | metrics: new_metrics}
  end

  defp emit_telemetry(event, measurements, metadata) do
    :telemetry.execute(
      [:mimo, :orchestrator | event],
      measurements,
      metadata
    )
  rescue
    _ -> :ok
  end
end
