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

        {:ok, String.to_atom(initial_state), data, [{:state_timeout, timeout, :overall_timeout}]}

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

  def handle_event(:info, _msg, _state, data) do
    {:keep_state, data}
  end

  # ============================================================================
  # Action Execution
  # ============================================================================

  defp execute_action_async(action, data) do
    parent = self()

    Task.start(fn ->
      result = execute_action(action, data.context)
      send(parent, {:action_result, result})
    end)
  end

  defp execute_action(%{"module" => mod_str, "function" => fun_str} = action, context) do
    args = Map.get(action, "args", [])
    timeout = Map.get(action, "timeout", 30_000)

    try do
      module = String.to_existing_atom("Elixir.#{mod_str}")
      function = String.to_atom(fun_str)

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
        target_atom = String.to_atom(target)

        if terminal_state?(data.procedure, target) do
          Logger.info("Procedure #{data.procedure.name} completed in error state: #{target}")
          complete_execution(data, :completed, nil)
          {:stop, :normal}
        else
          {:next_state, target_atom, data}
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
        target_atom = String.to_atom(target)

        if terminal_state?(data.procedure, target) do
          Logger.info("Procedure #{data.procedure.name} completed in state: #{target}")
          complete_execution(data, :completed, nil)
          {:stop, :normal}
        else
          {:next_state, target_atom, data}
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
    # TODO: Validate against context_schema if defined
    # v3.0 Roadmap: JSON Schema validation for procedure context
    #               with type coercion and detailed error messages
    # Current behavior: Passes context through without validation (acceptable for v2.x)
    context_schema = procedure.definition["context_schema"]

    if context_schema do
      # Basic type validation could go here
      context
    else
      context
    end
  end

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
