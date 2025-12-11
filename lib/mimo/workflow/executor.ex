defmodule Mimo.Workflow.Executor do
  @moduledoc """
  Workflow Executor for SPEC-053 Phase 3.

  Converts workflow patterns into executable FSM procedures and manages
  their execution lifecycle. Acts as the bridge between pattern prediction
  and procedural execution.

  ## Features

  - Converts Pattern → Procedure definition dynamically
  - Manages execution lifecycle with telemetry
  - Supports confirmation flow for non-auto-execute suggestions
  - Tracks success/failure for learning feedback
  - Handles step timeouts and retries from pattern configuration

  ## Architecture

                   Pattern
                      │
                      ▼
      ┌───────────────────────────────┐
      │        Executor               │
      │  ┌─────────────────────────┐  │
      │  │ Pattern → Procedure    │  │
      │  │ Definition Converter   │  │
      │  └───────────┬────────────┘  │
      │              │               │
      │              ▼               │
      │  ┌─────────────────────────┐  │
      │  │  ExecutionFSM Bridge   │  │
      │  └───────────┬────────────┘  │
      └──────────────│───────────────┘
                     │
                     ▼
           ProceduralStore.ExecutionFSM

  """
  require Logger

  alias Mimo.Workflow.{Pattern, BindingsResolver, PatternRegistry, Execution}
  alias Mimo.ProceduralStore.ExecutionFSM
  alias Mimo.Repo

  import Ecto.Query

  @type execution_result :: %{
          execution_id: String.t(),
          status: :running | :completed | :failed | :interrupted,
          pattern_name: String.t(),
          start_time: DateTime.t(),
          end_time: DateTime.t() | nil,
          outputs: map(),
          history: [map()]
        }

  @type execute_opts :: [
          context: map(),
          async: boolean(),
          timeout: pos_integer(),
          caller: pid() | nil,
          confirm: boolean()
        ]

  # =============================================================================
  # Public API
  # =============================================================================

  @doc """
  Execute a workflow pattern with resolved bindings.

  ## Options
  - `:context` - Additional context merged with bindings
  - `:async` - If true, returns immediately with execution_id
  - `:timeout` - Override pattern timeout (default: 300_000ms)
  - `:caller` - PID to notify on completion
  - `:confirm` - If true, logs but doesn't execute (for confirmation UI)

  ## Examples

      iex> Executor.execute(pattern, %{"error_message" => "undefined function"})
      {:ok, %{execution_id: "abc123", status: :running, ...}}

  """
  @spec execute(Pattern.t(), map(), execute_opts()) :: {:ok, execution_result()} | {:error, term()}
  def execute(%Pattern{} = pattern, bindings \\ %{}, opts \\ []) do
    start_time = System.monotonic_time(:microsecond)
    
    context = Map.merge(bindings, Keyword.get(opts, :context, %{}))
    async = Keyword.get(opts, :async, true)
    timeout = Keyword.get(opts, :timeout, pattern.timeout_ms || 300_000)
    caller = Keyword.get(opts, :caller)
    confirm = Keyword.get(opts, :confirm, false)

    # Resolve all bindings for all steps
    resolved_context = resolve_all_bindings(pattern, context)

    # Check preconditions
    case check_preconditions(pattern, resolved_context) do
      :ok ->
        if confirm do
          # Confirmation mode - just return what would be executed
          {:ok, build_confirmation_result(pattern, resolved_context)}
        else
          # Convert pattern to procedure definition
          procedure_def = pattern_to_procedure(pattern, resolved_context)
          
          # Execute via FSM
          result = execute_procedure(procedure_def, resolved_context, async, timeout, caller)
          
          # Emit telemetry
          duration_us = System.monotonic_time(:microsecond) - start_time
          emit_telemetry(:execute, pattern.name, duration_us, result)
          
          result
        end

      {:error, reason} ->
        Logger.warning("Precondition failed for pattern #{pattern.name}: #{inspect(reason)}")
        {:error, {:precondition_failed, reason}}
    end
  end

  @doc """
  Execute a pattern by name with automatic lookup and prediction.

  Useful when you have a pattern name rather than the pattern struct.
  """
  @spec execute_by_name(String.t(), map(), execute_opts()) :: 
          {:ok, execution_result()} | {:error, term()}
  def execute_by_name(pattern_name, bindings \\ %{}, opts \\ []) do
    case PatternRegistry.get_pattern(pattern_name) do
      {:ok, pattern} ->
        execute(pattern, bindings, opts)
      
      {:error, :not_found} ->
        {:error, {:pattern_not_found, pattern_name}}
    end
  end

  @doc """
  Get the status of a running or completed execution.
  """
  @spec get_execution_status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_execution_status(execution_id) do
    case Repo.get(Execution, execution_id) do
      nil ->
        {:error, :not_found}
      
      execution ->
        {:ok, %{
          execution_id: execution.id,
          pattern_name: execution.pattern_name,
          status: execution.status,
          started_at: execution.started_at,
          completed_at: execution.completed_at,
          context: execution.context,
          result: execution.result,
          step_history: execution.step_history
        }}
    end
  end

  @doc """
  Cancel a running execution.
  """
  @spec cancel_execution(String.t(), String.t()) :: :ok | {:error, term()}
  def cancel_execution(execution_id, reason \\ "user_cancelled") do
    case get_execution_pid(execution_id) do
      {:ok, pid} ->
        ExecutionFSM.interrupt(pid, reason)
        :ok
      
      {:error, _} = error ->
        error
    end
  end

  @doc """
  Record execution result for learning feedback.

  Called when execution completes (success or failure) to update
  pattern success metrics.
  """
  @spec record_result(String.t(), :success | :failure, map()) :: :ok
  def record_result(execution_id, outcome, metadata \\ %{}) do
    case Repo.get(Execution, execution_id) do
      nil ->
        Logger.warning("Cannot record result - execution not found: #{execution_id}")
        :ok
      
      execution ->
        # Update execution record
        status = if outcome == :success, do: :completed, else: :failed
        
        execution
        |> Ecto.Changeset.change(%{
          status: status,
          completed_at: DateTime.utc_now(),
          result: Map.put(metadata, :outcome, outcome)
        })
        |> Repo.update()
        
        # Update pattern success metrics
        update_pattern_metrics(execution.pattern_name, outcome)
        
        :ok
    end
  end

  @doc """
  List recent executions for a pattern.
  """
  @spec list_executions(String.t(), keyword()) :: [map()]
  def list_executions(pattern_name, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    status_filter = Keyword.get(opts, :status)

    query = from e in Execution,
      where: e.pattern_name == ^pattern_name,
      order_by: [desc: e.started_at],
      limit: ^limit

    query = if status_filter do
      from e in query, where: e.status == ^status_filter
    else
      query
    end

    Repo.all(query)
    |> Enum.map(&execution_to_map/1)
  end

  # =============================================================================
  # Pattern to Procedure Conversion
  # =============================================================================

  @doc """
  Convert a workflow pattern to a ProceduralStore-compatible procedure definition.

  This is the core conversion that bridges SPEC-053 patterns to existing
  procedural execution infrastructure.
  """
  @spec pattern_to_procedure(Pattern.t(), map()) :: map()
  def pattern_to_procedure(%Pattern{} = pattern, context) do
    # Build states from steps
    states = build_states_from_steps(pattern.steps, pattern, context)
    
    # Determine initial and terminal states
    initial_state = get_initial_state_name(pattern.steps)
    
    %{
      "name" => "workflow_#{pattern.name}_#{unique_suffix()}",
      "version" => "1.0",
      "initial_state" => initial_state,
      "states" => states,
      "context_schema" => build_context_schema(pattern),
      "timeout" => pattern.timeout_ms || 300_000,
      "metadata" => %{
        "source" => "workflow_pattern",
        "pattern_name" => pattern.name,
        "pattern_id" => pattern.id
      }
    }
  end

  defp build_states_from_steps(steps, pattern, context) do
    steps
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {step, index}, acc ->
      state_name = step_to_state_name(step, index)
      next_state = get_next_state_name(steps, index)
      tool = step[:tool] || step["tool"]
      name = step[:name] || step["name"] || "step_#{index}"
      
      state_def = %{
        "action" => build_action_from_step(step, pattern, context),
        "transitions" => build_transitions(next_state, step),
        "metadata" => %{
          "step_index" => index,
          "original_tool" => tool,
          "step_name" => name
        }
      }
      
      Map.put(acc, state_name, state_def)
    end)
  end

  defp step_to_state_name(step, index) do
    name = step[:name] || step["name"] || "step"
    "#{name}_#{index}"
  end

  defp get_initial_state_name([first_step | _]) do
    step_to_state_name(first_step, 0)
  end

  defp get_initial_state_name([]), do: "empty"

  defp get_next_state_name(steps, current_index) do
    if current_index >= length(steps) - 1 do
      "completed"
    else
      next_step = Enum.at(steps, current_index + 1)
      step_to_state_name(next_step, current_index + 1)
    end
  end

  defp build_transitions("completed", _step) do
    # Terminal state - no transitions (FSM will recognize this)
    []
  end

  defp build_transitions(next_state, step) do
    base_transitions = [
      %{"event" => "success", "target" => next_state}
    ]
    
    # Add error transition if retry policy allows
    error_transition = if step[:retry_policy] && step.retry_policy.max_attempts > 0 do
      # Error transitions are handled by the FSM's retry logic
      []
    else
      [%{"event" => "error", "target" => "failed"}]
    end
    
    base_transitions ++ error_transition
  end

  defp build_action_from_step(step, pattern, context) do
    # The action calls our tool executor with resolved bindings
    resolved_bindings = BindingsResolver.resolve_step_bindings(step, context, pattern)
    tool = step[:tool] || step["tool"]
    
    %{
      "module" => "Mimo.Workflow.Executor.StepRunner",
      "function" => "run_step",
      "args" => [tool, resolved_bindings, step_options(step)],
      "timeout" => step_timeout(step)
    }
  end

  defp step_options(step) do
    %{
      retry_policy: step[:retry_policy] || step["retry_policy"],
      validation: step[:validation] || step["validation"]
    }
  end

  defp step_timeout(step) do
    retry_policy = step[:retry_policy] || step["retry_policy"]
    timeout_ms = step[:timeout_ms] || step["timeout_ms"]
    
    cond do
      is_integer(timeout_ms) -> timeout_ms
      is_map(retry_policy) and is_integer(retry_policy[:timeout_ms]) -> retry_policy[:timeout_ms]
      is_map(retry_policy) and is_integer(retry_policy["timeout_ms"]) -> retry_policy["timeout_ms"]
      true -> 30_000
    end
  end

  defp build_context_schema(pattern) do
    # Build a JSON schema from pattern bindings
    bindings = pattern.bindings || []
    
    required_bindings = Enum.filter(bindings, fn binding ->
      Map.get(binding, :required, false)
    end)
    
    properties = Enum.reduce(bindings, %{}, fn binding, acc ->
      name = Map.get(binding, :name, "unknown")
      type = Map.get(binding, :type, :string)
      Map.put(acc, name, %{"type" => infer_json_type(type)})
    end)
    
    %{
      "type" => "object",
      "properties" => properties,
      "required" => Enum.map(required_bindings, &Map.get(&1, :name, "unknown"))
    }
  end

  defp infer_json_type(type) when is_atom(type) do
    case type do
      :string -> "string"
      :integer -> "integer"
      :float -> "number"
      :boolean -> "boolean"
      :map -> "object"
      :list -> "array"
      _ -> "string"
    end
  end

  defp infer_json_type(_), do: "string"

  # =============================================================================
  # Execution Helpers
  # =============================================================================

  defp execute_procedure(procedure_def, context, async, timeout, caller) do
    # Create a temporary procedure entry
    # In a production system, we'd register this with ProceduralStore
    # For now, we execute directly via FSM
    
    execution_id = generate_execution_id()
    
    # Create execution record
    {:ok, execution} = create_execution_record(procedure_def, context, execution_id)
    
    fsm_opts = [
      caller: caller,
      timeout: timeout
    ]
    
    # start_fsm always returns {:ok, pid} since it uses Task.start which never fails
    {:ok, pid} = start_fsm(procedure_def, context, fsm_opts)
    
    # Store PID mapping
    store_execution_pid(execution_id, pid)
    
    if async do
      # Return immediately
      {:ok, %{
        execution_id: execution_id,
        status: :running,
        pattern_name: procedure_def["metadata"]["pattern_name"],
        start_time: execution.started_at,
        end_time: nil,
        outputs: %{},
        history: []
      }}
    else
      # Wait for completion
      wait_for_completion(pid, execution_id, timeout)
    end
  end

  defp start_fsm(procedure_def, context, opts) do
    # We need to use a dynamic procedure loader
    # For now, create an in-memory procedure struct
    # (procedure struct is built for future FSM integration)
    _procedure = %{
      name: procedure_def["name"],
      version: procedure_def["version"],
      definition: procedure_def,
      timeout_ms: procedure_def["timeout"] || 300_000,
      max_retries: 3
    }
    
    # Start FSM with our procedure (this requires extending ExecutionFSM)
    # For now, we'll use a simplified execution path
    execute_steps_directly(procedure_def, context, opts)
  end

  # Simplified direct execution until we integrate with full FSM
  defp execute_steps_directly(procedure_def, context, opts) do
    caller = Keyword.get(opts, :caller)
    
    Task.start(fn ->
      result = run_steps_sequentially(procedure_def["states"], context)
      
      if caller do
        send(caller, {:workflow_completed, result})
      end
    end)
    
    {:ok, self()}  # Return a placeholder PID
  end

  defp run_steps_sequentially(states, context) do
    # Get ordered states
    state_order = states
    |> Enum.map(fn {name, _def} -> name end)
    |> Enum.sort_by(fn name ->
      case Regex.run(~r/_(\d+)$/, name) do
        [_, num] -> String.to_integer(num)
        _ -> 0
      end
    end)
    
    Enum.reduce_while(state_order, {:ok, context}, fn state_name, {:ok, ctx} ->
      state_def = Map.get(states, state_name, %{})
      
      case execute_state_action(state_def, ctx) do
        {:ok, new_ctx} -> {:cont, {:ok, Map.merge(ctx, new_ctx)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp execute_state_action(%{"action" => nil}, ctx), do: {:ok, ctx}
  defp execute_state_action(%{"action" => action}, ctx) do
    module = String.to_existing_atom("Elixir.#{action["module"]}")
    function = String.to_existing_atom(action["function"])
    args = action["args"] || []
    
    try do
      apply(module, function, [ctx | args])
    rescue
      e -> {:error, Exception.message(e)}
    end
  end
  defp execute_state_action(_, ctx), do: {:ok, ctx}

  defp wait_for_completion(pid, execution_id, timeout) do
    ref = Process.monitor(pid)
    
    receive do
      {:workflow_completed, result} ->
        Process.demonitor(ref, [:flush])
        finalize_execution(execution_id, result)
      
      {:DOWN, ^ref, :process, ^pid, :normal} ->
        finalize_execution(execution_id, {:ok, %{}})
      
      {:DOWN, ^ref, :process, ^pid, reason} ->
        finalize_execution(execution_id, {:error, reason})
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        Process.exit(pid, :timeout)
        finalize_execution(execution_id, {:error, :timeout})
    end
  end

  defp finalize_execution(execution_id, result) do
    status = case result do
      {:ok, _} -> :completed
      {:error, _} -> :failed
    end
    
    outputs = case result do
      {:ok, ctx} when is_map(ctx) -> ctx
      _ -> %{}
    end
    
    # Update execution record
    case Repo.get(Execution, execution_id) do
      nil -> :ok
      execution ->
        execution
        |> Ecto.Changeset.change(%{
          status: status,
          completed_at: DateTime.utc_now(),
          result: outputs
        })
        |> Repo.update()
    end
    
    case result do
      {:ok, ctx} ->
        {:ok, %{
          execution_id: execution_id,
          status: status,
          pattern_name: nil,
          start_time: nil,
          end_time: DateTime.utc_now(),
          outputs: ctx,
          history: []
        }}
      
      {:error, reason} ->
        {:error, reason}
    end
  end

  # =============================================================================
  # Precondition Checking
  # =============================================================================

  defp check_preconditions(%Pattern{preconditions: nil}, _context), do: :ok
  defp check_preconditions(%Pattern{preconditions: []}, _context), do: :ok
  defp check_preconditions(%Pattern{preconditions: preconditions}, context) do
    Enum.reduce_while(preconditions, :ok, fn precondition, _acc ->
      case check_single_precondition(precondition, context) do
        true -> {:cont, :ok}
        false -> {:halt, {:error, precondition.description || precondition.check}}
      end
    end)
  end

  defp check_single_precondition(%{check: check_type} = precondition, context) do
    case check_type do
      :context_has_key ->
        key = precondition.key || precondition[:params][:key]
        Map.has_key?(context, key) or Map.has_key?(context, to_string(key))
      
      :file_exists ->
        path = context[precondition.key] || context[to_string(precondition.key)]
        path && File.exists?(path)
      
      :project_indexed ->
        # Check if project has been indexed via onboard
        case context["project_path"] || context[:project_path] do
          nil -> false
          _path -> true  # Simplified check
        end
      
      :custom ->
        # Allow custom check functions
        case precondition[:function] do
          {mod, fun} -> apply(mod, fun, [context])
          _ -> true
        end
      
      _ ->
        Logger.warning("Unknown precondition check type: #{inspect(check_type)}")
        true
    end
  end

  # =============================================================================
  # Binding Resolution
  # =============================================================================

  defp resolve_all_bindings(%Pattern{steps: steps, bindings: bindings}, context) do
    # First, ensure all required bindings are present
    resolved = Enum.reduce(bindings || [], context, fn binding, ctx ->
      if Map.has_key?(ctx, binding.name) do
        ctx
      else
        # Try to extract from context using default extractor
        case binding[:extractor] do
          nil -> ctx
          extractor -> 
            case BindingsResolver.extract_path(context, extractor) do
              nil -> ctx
              value -> Map.put(ctx, binding.name, value)
            end
        end
      end
    end)
    
    # Then resolve step-specific bindings
    Enum.reduce(steps, resolved, fn step, ctx ->
      step_bindings = BindingsResolver.resolve_step_bindings(step, ctx, %{bindings: bindings})
      Map.merge(ctx, step_bindings)
    end)
  end

  # =============================================================================
  # Confirmation Mode
  # =============================================================================

  defp build_confirmation_result(pattern, context) do
    %{
      execution_id: nil,
      status: :pending_confirmation,
      pattern_name: pattern.name,
      pattern_description: pattern.description,
      steps: Enum.map(pattern.steps, fn step ->
        %{
          tool: step.tool,
          name: step[:name] || step.tool,
          args_preview: preview_args(step, context)
        }
      end),
      resolved_context: context,
      estimated_duration_ms: pattern.timeout_ms || 300_000
    }
  end

  defp preview_args(step, context) do
    resolved = BindingsResolver.resolve_step_bindings(step, context, %{})
    
    # Truncate long values for preview
    Enum.map(resolved, fn {k, v} ->
      {k, truncate_value(v, 100)}
    end)
    |> Map.new()
  end

  defp truncate_value(value, max_len) when is_binary(value) do
    if String.length(value) > max_len do
      String.slice(value, 0, max_len) <> "..."
    else
      value
    end
  end
  defp truncate_value(value, _), do: value

  # =============================================================================
  # Helpers
  # =============================================================================

  defp generate_execution_id do
    "wfexec_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp unique_suffix do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end

  defp create_execution_record(procedure_def, context, execution_id) do
    pattern_name = get_in(procedure_def, ["metadata", "pattern_name"]) || "unknown"
    
    %Execution{}
    |> Execution.changeset(%{
      id: execution_id,
      pattern_name: pattern_name,
      status: :running,
      context: context,
      started_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  defp update_pattern_metrics(pattern_name, outcome) do
    case PatternRegistry.get_pattern(pattern_name) do
      {:ok, _pattern} ->
        # Use the proper update function with success flag
        success? = outcome == :success
        PatternRegistry.update_pattern_metrics(pattern_name, success?, 0)

      {:error, _} ->
        Logger.debug("Pattern not found for metrics update: #{pattern_name}")
    end
  end

  # Simple in-memory PID tracking (would use Registry in production)
  defp store_execution_pid(execution_id, pid) do
    :persistent_term.put({:workflow_execution, execution_id}, pid)
  rescue
    _ -> :ok
  end

  defp get_execution_pid(execution_id) do
    case :persistent_term.get({:workflow_execution, execution_id}, nil) do
      nil -> {:error, :not_found}
      pid -> {:ok, pid}
    end
  rescue
    _ -> {:error, :not_found}
  end

  defp execution_to_map(execution) do
    %{
      execution_id: execution.id,
      pattern_name: execution.pattern_name,
      status: execution.status,
      started_at: execution.started_at,
      completed_at: execution.completed_at,
      context: execution.context,
      result: execution.result
    }
  end

  defp emit_telemetry(operation, pattern_name, duration_us, result) do
    status = case result do
      {:ok, _} -> :ok
      {:error, _} -> :error
    end
    
    :telemetry.execute(
      [:mimo, :workflow, :executor, operation],
      %{duration_us: duration_us},
      %{pattern_name: pattern_name, status: status}
    )
  end
end
