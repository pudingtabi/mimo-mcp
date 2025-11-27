defmodule Mimo.ErrorHandling.CircuitBreaker do
  @moduledoc """
  Circuit breaker pattern to prevent cascade failures.

  States:
  - :closed - Normal operation, requests flow through
  - :open - Failure threshold reached, requests fail fast
  - :half_open - Testing if service recovered
  """
  use GenServer
  require Logger

  @default_failure_threshold 5
  @default_reset_timeout_ms 60_000
  @default_half_open_max_calls 3

  defstruct [
    :name,
    :state,
    :failure_count,
    :success_count,
    :last_failure_time,
    :failure_threshold,
    :reset_timeout_ms,
    :half_open_max_calls
  ]

  # ==========================================================================
  # Client API
  # ==========================================================================

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(name))
  end

  @doc """
  Executes operation through circuit breaker.
  """
  @spec call(atom(), (-> {:ok, any()} | {:error, any()})) :: {:ok, any()} | {:error, any()}
  def call(name, operation) when is_function(operation, 0) do
    case get_state(name) do
      :open ->
        {:error, :circuit_breaker_open}

      state when state in [:closed, :half_open] ->
        try do
          case operation.() do
            {:ok, result} ->
              record_success(name)
              {:ok, result}

            :ok ->
              record_success(name)
              :ok

            {:error, _reason} = error ->
              record_failure(name)
              error
          end
        rescue
          e ->
            record_failure(name)
            {:error, {:exception, Exception.message(e)}}
        end
    end
  end

  @doc """
  Gets current circuit state.
  """
  @spec get_state(atom()) :: :closed | :open | :half_open
  def get_state(name) do
    GenServer.call(via_tuple(name), :get_state)
  catch
    # If circuit doesn't exist, assume closed
    :exit, _ -> :closed
  end

  @doc """
  Alias for get_state/1 - gets current circuit status.
  """
  @spec status(atom()) :: :closed | :open | :half_open
  def status(name), do: get_state(name)

  @doc """
  Records a successful operation.
  """
  def record_success(name) do
    GenServer.cast(via_tuple(name), :success)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Records a failed operation.
  """
  def record_failure(name) do
    GenServer.cast(via_tuple(name), :failure)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Manually resets the circuit breaker.
  """
  def reset(name) do
    GenServer.cast(via_tuple(name), :reset)
  catch
    :exit, _ -> :ok
  end

  # ==========================================================================
  # Server Callbacks
  # ==========================================================================

  @impl true
  def init(opts) do
    state = %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      state: :closed,
      failure_count: 0,
      success_count: 0,
      last_failure_time: nil,
      failure_threshold: Keyword.get(opts, :failure_threshold, @default_failure_threshold),
      reset_timeout_ms: Keyword.get(opts, :reset_timeout_ms, @default_reset_timeout_ms),
      half_open_max_calls: Keyword.get(opts, :half_open_max_calls, @default_half_open_max_calls)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    current_state = determine_current_state(state)
    {:reply, current_state, %{state | state: current_state}}
  end

  @impl true
  def handle_cast(:success, state) do
    new_state =
      case state.state do
        :half_open ->
          if state.success_count + 1 >= state.half_open_max_calls do
            Logger.info("Circuit breaker #{state.name} closing after recovery")
            %{state | state: :closed, failure_count: 0, success_count: 0}
          else
            %{state | success_count: state.success_count + 1}
          end

        :closed ->
          %{state | failure_count: max(0, state.failure_count - 1)}

        _ ->
          state
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:failure, state) do
    new_failure_count = state.failure_count + 1

    new_state =
      if new_failure_count >= state.failure_threshold do
        Logger.warning("Circuit breaker #{state.name} opening after #{new_failure_count} failures")

        %{
          state
          | state: :open,
            failure_count: new_failure_count,
            last_failure_time: System.monotonic_time(:millisecond)
        }
      else
        %{state | failure_count: new_failure_count}
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:reset, state) do
    Logger.info("Circuit breaker #{state.name} manually reset")
    {:noreply, %{state | state: :closed, failure_count: 0, success_count: 0}}
  end

  # ==========================================================================
  # Private Functions
  # ==========================================================================

  defp determine_current_state(
         %{state: :open, last_failure_time: last_failure, reset_timeout_ms: timeout} = state
       ) do
    now = System.monotonic_time(:millisecond)

    if now - last_failure >= timeout do
      Logger.info("Circuit breaker #{state.name} entering half-open state")
      :half_open
    else
      :open
    end
  end

  defp determine_current_state(%{state: state}), do: state

  defp via_tuple(name) do
    {:via, Registry, {Mimo.CircuitBreaker.Registry, name}}
  end
end
