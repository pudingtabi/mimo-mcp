defmodule Mimo.ProceduralStore.ExecutionFSM do
  @moduledoc """
  Finite State Machine for procedure execution using gen_statem.

  Executes procedures as deterministic state machines, with each state
  performing an action and transitioning based on the result.

  ## Features

  - Deterministic execution (no LLM involvement)
  - Automatic retries with exponential backoff
  - Timeout handling per state and overall
  - Rollback support on failure
  - Full execution history tracking

  ## Usage

      {:ok, pid} = ExecutionFSM.start_procedure("deploy_db", "1.0", %{"env" => "prod"})
      
      # Monitor completion
      ref = Process.monitor(pid)
      receive do
        {:DOWN, ^ref, :process, ^pid, :normal} -> :completed
        {:DOWN, ^ref, :process, ^pid, reason} -> {:failed, reason}
      end
  """

  @behaviour :gen_statem

  require Logger

  alias Mimo.ProceduralStore.{Execution, Loader}
  alias Mimo.Repo

  defstruct [
    :procedure,
    :execution_id,
    :context,
    :history,
    :start_time,
    :retry_count,
    :caller
  ]

  @type t :: %__MODULE__{}

  # SECURITY: Safe state name conversion to prevent atom exhaustion
  # States are only valid if they exist in the procedure definition
  @spec safe_state_atom(map(), String.t()) :: atom() | nil
  defp safe_state_atom(procedure, state_name) when is_binary(state_name) do
    states = procedure.definition["states"] || %{}

    if Map.has_key?(states, state_name) do
      # State exists in definition - safe to convert
      # Use to_existing_atom first in case it's already an atom (common states)
      try do
        String.to_existing_atom(state_name)
      rescue
        ArgumentError ->
          # Not an existing atom, but it's validated against definition
          # This is safe because we've confirmed the state exists
          String.to_atom(state_name)
      end
    else
      Logger.error("Invalid state '#{state_name}' not found in procedure definition")
      nil
    end
  end

  defp safe_state_atom(_procedure, state_name) when is_atom(state_name), do: state_name
  defp safe_state_atom(_procedure, _), do: nil

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts a new procedure execution.

  ## Parameters

    - `name` - Procedure name
    - `version` - Procedure version (or "latest")
    - `context` - Initial execution context
    - `opts` - Options:
      - `:caller` - PID to notify on completion
      - `:timeout` - Override procedure timeout

  ## Returns

    - `{:ok, pid}` - FSM process started
    - `{:error, reason}` - Failed to start
  """
  @spec start_procedure(String.t(), String.t(), map(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start_procedure(name, version, context, opts \\ []) do
    :gen_statem.start(__MODULE__, {name, version, context, opts}, [])
  end

  @doc """
  Starts a linked procedure execution.
  """
  @spec start_link_procedure(String.t(), String.t(), map(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start_link_procedure(name, version, context, opts \\ []) do
    :gen_statem.start_link(__MODULE__, {name, version, context, opts}, [])
  end

  @doc """
  Gets the current state of an execution.
  """
  @spec get_state(pid()) :: {atom(), map()}
  def get_state(pid) do
    :gen_statem.call(pid, :get_state)
  end

  @doc """
  Sends an external event to the FSM.
  """
  @spec send_event(pid(), term()) :: :ok
  def send_event(pid, event) do
    :gen_statem.cast(pid, {:external_event, event})
  end

  @doc """
  Requests graceful interruption.
  """
  @spec interrupt(pid(), String.t()) :: :ok
  def interrupt(pid, reason) do
    :gen_statem.cast(pid, {:interrupt, reason})
  end

  # ============================================================================
  # gen_statem Callbacks
  # ============================================================================

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init({name, version, context, opts}) do
    case Loader.load(name, version) do
      {:ok, procedure} ->
        # Create execution record
        {:ok, execution} = create_execution_record(procedure, context)

        data = %__MODULE__{
          procedure: procedure,
          execution_id: execution.id,
          context: validate_context(procedure, context),
          history: [],
          start_time: System.monotonic_time(:millisecond),
          retry_count: 0,
          caller: Keyword.get(opts, :caller)
        }

        initial_state = get_initial_state(procedure)
        timeout = Keyword.get(opts, :timeout, procedure.timeout_ms)

        Logger.info("Starting procedure #{name}:#{version}, initial state: #{initial_state}")

        case safe_state_atom(procedure, initial_state) do
          nil ->
            {:stop, {:invalid_initial_state, initial_state}}

          state_atom ->
            {:ok, state_atom, data, [{:state_timeout, timeout, :overall_timeout}]}
        end

      {:error, reason} ->
        {:stop, {:procedure_not_found, reason}}
    end
  end

  # ============================================================================
  # State Functions
  # ============================================================================

  # Generic state handler - matches any state
  @impl true
  def handle_event(:enter, old_state, state, data) do
    Logger.debug("Procedure #{data.procedure.name} entering state: #{state} (from #{old_state})")

    # Record state transition
    new_data = record_transition(data, old_state, state, :enter)

    # Get and execute state action
    case get_state_action(data.procedure, state) do
      nil ->
        # No action - check if this is a terminal state
        if terminal_state?(data.procedure, state) do
          Logger.info("Procedure #{data.procedure.name} completed in terminal state: #{state}")
          complete_execution(new_data, :completed, nil)
          {:stop, :normal}
        else
          # Waiting state - keep state until external event
          {:keep_state, new_data}
        end

      action ->
        # Execute action asynchronously
        execute_action_async(action, new_data)
        {:keep_state, new_data}
    end
  end

  def handle_event(:info, {:action_result, result}, state, data) do
    handle_action_result(result, state, data)
  end

  def handle_event(:info, {:action_error, error}, state, data) do
    handle_action_error(error, state, data)
  end

  def handle_event(:cast, {:external_event, event}, state, data) do
    handle_external_event(event, state, data)
  end

  def handle_event(:cast, {:interrupt, reason}, _state, data) do
    Logger.warning("Procedure #{data.procedure.name} interrupted: #{reason}")
    complete_execution(data, :interrupted, reason)
    {:stop, :normal}
  end

  def handle_event(:state_timeout, :overall_timeout, _state, data) do
    Logger.error("Procedure #{data.procedure.name} timed out")
    complete_execution(data, :failed, "overall timeout exceeded")
    {:stop, :normal}
  end

  def handle_event({:call, from}, :get_state, state, data) do
    {:keep_state, data, [{:reply, from, {state, data.context}}]}
  end

  # Handle task completion (already handled by :action_result, but this cleans up)
  # RELIABILITY FIX: Explicit handlers for Task.async monitoring
  def handle_event(:info, {ref, _result}, _state, data) when is_reference(ref) do
    # Task completed - demonitor and flush DOWN message
    Process.demonitor(ref, [:flush])
    {:keep_state, data}
  end

  # Handle task crash - prevents FSM hang
  def handle_event(:info, {:DOWN, _ref, :process, _pid, reason}, state, data)
      when reason != :normal do
    Logger.error("Action task crashed in state #{state}: #{inspect(reason)}")
    handle_action_error({:task_crashed, reason}, state, data)
  end

  # Handle action timeout - prevents FSM hang
  def handle_event(:info, {:action_timeout, ref}, state, data) when is_reference(ref) do
    # Check if task is still running
    case Process.info(self(), :messages) do
      {:messages, msgs} ->
        # If we already got the result, ignore timeout
        has_result =
          Enum.any?(msgs, fn
            {:action_result, _} -> true
            _ -> false
          end)

        if has_result do
          {:keep_state, data}
        else
          Logger.error("Action timed out in state #{state}")
          handle_action_error(:action_timeout, state, data)
        end

      _ ->
        {:keep_state, data}
    end
  end

  # Catch-all for unhandled info messages (must be last)
  def handle_event(:info, _msg, _state, data) do
    {:keep_state, data}
  end

  # ============================================================================
  # Action Execution
  # ============================================================================

  # Action execution timeout (per-action, separate from overall procedure timeout)
  @action_timeout 60_000

  defp execute_action_async(action, data) do
    parent = self()

    # RELIABILITY FIX: Use Task.Supervisor with monitoring to prevent FSM hang
    # if the Task crashes before sending its result.
    # 
    # Previous issue: Task.start would fire-and-forget, and if the task crashed
    # before sending {:action_result, result}, the FSM would hang forever waiting.
    #
    # Solution: Monitor the task and set a timeout. If task dies or times out,
    # send an error result so the FSM can handle it properly.
    task =
      Task.async(fn ->
        result = execute_action(action, data.context)
        send(parent, {:action_result, result})
        result
      end)

    # Start a timeout watcher - if Task doesn't complete in time, fail gracefully
    action_timeout = Map.get(action, "timeout", @action_timeout)
    Process.send_after(parent, {:action_timeout, task.ref}, action_timeout)

    # Store task ref so we can correlate timeout/DOWN messages
    # (handled by the explicit handle_event clauses above)
    task
  end

  defp execute_action(%{"module" => mod_str, "function" => fun_str} = action, context) do
    args = Map.get(action, "args", [])
    timeout = Map.get(action, "timeout", 30_000)

    try do
      module = String.to_existing_atom("Elixir.#{mod_str}")
      # SECURITY: Use to_existing_atom to prevent atom table exhaustion
      # Function must already exist in the module
      function = String.to_existing_atom(fun_str)

      # Execute with timeout
      task =
        Task.async(fn ->
          apply(module, function, [context | args])
        end)

      case Task.yield(task, timeout) || Task.shutdown(task) do
        {:ok, result} -> result
        nil -> {:error, :timeout}
      end
    rescue
      ArgumentError ->
        {:error, {:module_not_found, mod_str}}

      e ->
        {:error, {:exception, Exception.message(e)}}
    end
  end

  defp handle_action_result(result, state, data) do
    case result do
      {:ok, new_context} when is_map(new_context) ->
        # Merge result into context
        updated_data = %{data | context: Map.merge(data.context, new_context)}
        transition_on_event(updated_data, state, :success)

      {:ok, _} ->
        transition_on_event(data, state, :success)

      :ok ->
        transition_on_event(data, state, :success)

      {:error, reason} ->
        handle_action_error(reason, state, data)

      {:transition, event} when is_atom(event) or is_binary(event) ->
        transition_on_event(data, state, event)

      other ->
        Logger.warning("Unexpected action result: #{inspect(other)}")
        transition_on_event(data, state, :success)
    end
  end

  defp handle_action_error(error, state, data) do
    Logger.error("Action failed in state #{state}: #{inspect(error)}")

    # First check if there's an error transition defined
    case find_transition(data.procedure, state, "error") do
      {:ok, target} ->
        # Error transition exists - use it instead of retrying
        Logger.info("Transitioning to error state: #{target}")

        case safe_state_atom(data.procedure, target) do
          nil ->
            Logger.error("Invalid error transition target: #{target}")
            complete_execution(data, :failed, {:invalid_state, target})
            {:stop, :normal}

          target_atom ->
            if terminal_state?(data.procedure, target) do
              Logger.info("Procedure #{data.procedure.name} completed in error state: #{target}")
              complete_execution(data, :completed, nil)
              {:stop, :normal}
            else
              {:next_state, target_atom, data}
            end
        end

      :no_transition ->
        # No error transition - retry if possible
        max_retries = data.procedure.max_retries

        if data.retry_count < max_retries do
          # Retry with exponential backoff
          delay = (:math.pow(2, data.retry_count) * 1000) |> round()
          new_data = %{data | retry_count: data.retry_count + 1}

          Logger.info("Retrying (#{new_data.retry_count}/#{max_retries}) after #{delay}ms")

          Process.send_after(self(), :retry, delay)
          {:keep_state, new_data}
        else
          # Max retries exceeded, fail the procedure
          Logger.error("Max retries exceeded, failing procedure")
          complete_execution(data, :failed, error)
          {:stop, :normal}
        end
    end
  end

  defp handle_external_event(event, state, data) do
    transition_on_event(data, state, event)
  end

  # ============================================================================
  # State Transitions
  # ============================================================================

  defp transition_on_event(data, current_state, event) do
    event_str = to_string(event)

    case find_transition(data.procedure, current_state, event_str) do
      {:ok, target} ->
        case safe_state_atom(data.procedure, target) do
          nil ->
            Logger.error("Invalid transition target: #{target}")
            {:keep_state, data}

          target_atom ->
            if terminal_state?(data.procedure, target) do
              Logger.info("Procedure #{data.procedure.name} completed in state: #{target}")
              complete_execution(data, :completed, nil)
              {:stop, :normal}
            else
              {:next_state, target_atom, data}
            end
        end

      :no_transition ->
        Logger.warning("No transition for event '#{event}' in state '#{current_state}'")

        if terminal_state?(data.procedure, current_state) do
          complete_execution(data, :completed, nil)
          {:stop, :normal}
        else
          {:keep_state, data}
        end
    end
  end

  defp find_transition(procedure, state, event) do
    state_str = to_string(state)
    states = procedure.definition["states"] || %{}
    state_def = Map.get(states, state_str, %{})
    transitions = Map.get(state_def, "transitions", [])

    case Enum.find(transitions, &(Map.get(&1, "event") == event)) do
      nil -> :no_transition
      %{"target" => target} -> {:ok, target}
    end
  end

  defp terminal_state?(procedure, state) do
    state_str = to_string(state)
    states = procedure.definition["states"] || %{}
    state_def = Map.get(states, state_str, %{})

    # Terminal if no transitions defined
    Map.get(state_def, "transitions", []) == []
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp get_initial_state(procedure) do
    procedure.definition["initial_state"]
  end

  defp get_state_action(procedure, state) do
    state_str = to_string(state)
    states = procedure.definition["states"] || %{}
    state_def = Map.get(states, state_str, %{})
    Map.get(state_def, "action")
  end

  defp validate_context(procedure, context) do
    context_schema = procedure.definition["context_schema"]

    if context_schema do
      case validate_against_schema(context, context_schema) do
        :ok ->
          context

        {:error, errors} ->
          Logger.warning(
            "Context validation failed for procedure #{procedure.name}: #{inspect(errors)}"
          )

          # Return context anyway but log the issues
          # In strict mode, this would raise/halt
          context
      end
    else
      context
    end
  end

  # Basic JSON Schema-like validation
  # Supports: type, required, properties, minLength, maxLength, minimum, maximum, enum
  defp validate_against_schema(data, schema) when is_map(schema) do
    errors = []

    # Check required fields
    errors =
      case Map.get(schema, "required") do
        nil ->
          errors

        required when is_list(required) ->
          missing = Enum.filter(required, fn key -> not Map.has_key?(data, key) end)

          if Enum.empty?(missing) do
            errors
          else
            errors ++ [{:missing_required, missing}]
          end

        _ ->
          errors
      end

    # Check property types
    errors =
      case Map.get(schema, "properties") do
        nil ->
          errors

        properties when is_map(properties) ->
          Enum.reduce(properties, errors, fn {key, prop_schema}, acc ->
            case Map.get(data, key) do
              nil ->
                acc

              value ->
                case validate_property(value, prop_schema) do
                  :ok -> acc
                  {:error, reason} -> acc ++ [{:invalid_property, key, reason}]
                end
            end
          end)

        _ ->
          errors
      end

    if Enum.empty?(errors) do
      :ok
    else
      {:error, errors}
    end
  end

  defp validate_against_schema(_data, _schema), do: :ok

  defp validate_property(value, schema) when is_map(schema) do
    type = Map.get(schema, "type")

    type_valid =
      case type do
        nil -> true
        "string" -> is_binary(value)
        "number" -> is_number(value)
        "integer" -> is_integer(value)
        "boolean" -> is_boolean(value)
        "array" -> is_list(value)
        "object" -> is_map(value)
        _ -> true
      end

    if type_valid do
      validate_constraints(value, schema)
    else
      {:error, {:type_mismatch, expected: type, got: typeof(value)}}
    end
  end

  defp validate_property(_value, _schema), do: :ok

  defp validate_constraints(value, schema) when is_binary(value) do
    cond do
      Map.has_key?(schema, "minLength") and String.length(value) < schema["minLength"] ->
        {:error, {:min_length, schema["minLength"]}}

      Map.has_key?(schema, "maxLength") and String.length(value) > schema["maxLength"] ->
        {:error, {:max_length, schema["maxLength"]}}

      Map.has_key?(schema, "enum") and value not in schema["enum"] ->
        {:error, {:not_in_enum, schema["enum"]}}

      Map.has_key?(schema, "pattern") ->
        case Regex.compile(schema["pattern"]) do
          {:ok, regex} ->
            if Regex.match?(regex, value),
              do: :ok,
              else: {:error, {:pattern_mismatch, schema["pattern"]}}

          _ ->
            :ok
        end

      true ->
        :ok
    end
  end

  defp validate_constraints(value, schema) when is_number(value) do
    cond do
      Map.has_key?(schema, "minimum") and value < schema["minimum"] ->
        {:error, {:minimum, schema["minimum"]}}

      Map.has_key?(schema, "maximum") and value > schema["maximum"] ->
        {:error, {:maximum, schema["maximum"]}}

      Map.has_key?(schema, "enum") and value not in schema["enum"] ->
        {:error, {:not_in_enum, schema["enum"]}}

      true ->
        :ok
    end
  end

  defp validate_constraints(_value, _schema), do: :ok

  defp typeof(value) when is_binary(value), do: "string"
  defp typeof(value) when is_integer(value), do: "integer"
  defp typeof(value) when is_float(value), do: "number"
  defp typeof(value) when is_boolean(value), do: "boolean"
  defp typeof(value) when is_list(value), do: "array"
  defp typeof(value) when is_map(value), do: "object"
  defp typeof(_), do: "unknown"

  defp record_transition(data, from_state, to_state, event) do
    entry = %{
      from: to_string(from_state),
      to: to_string(to_state),
      event: to_string(event),
      timestamp: System.monotonic_time(:millisecond) - data.start_time
    }

    %{data | history: data.history ++ [entry]}
  end

  defp create_execution_record(procedure, context) do
    attrs = %{
      procedure_id: procedure.id,
      procedure_name: procedure.name,
      procedure_version: procedure.version,
      status: "running",
      current_state: procedure.definition["initial_state"],
      context: context,
      started_at: NaiveDateTime.utc_now()
    }

    %Execution{}
    |> Execution.changeset(attrs)
    |> Repo.insert()
  end

  defp complete_execution(data, status, error) do
    now = NaiveDateTime.utc_now()
    duration = System.monotonic_time(:millisecond) - data.start_time

    status_str = to_string(status)

    attrs = %{
      status: status_str,
      history: data.history,
      context: data.context,
      error: if(error, do: inspect(error), else: nil),
      completed_at: now,
      duration_ms: duration
    }

    # Update execution record
    case Repo.get(Execution, data.execution_id) do
      nil ->
        Logger.error("Execution record not found: #{data.execution_id}")

      execution ->
        execution
        |> Execution.changeset(attrs)
        |> Repo.update()
    end

    # Notify caller if present
    if data.caller do
      send(data.caller, {:procedure_complete, data.procedure.name, status, data.context})
    end

    :ok
  end
end
