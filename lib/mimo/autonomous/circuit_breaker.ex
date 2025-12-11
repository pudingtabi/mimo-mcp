defmodule Mimo.Autonomous.CircuitBreaker do
  @moduledoc """
  Circuit breaker pattern for autonomous task execution.

  Part of SPEC-071: Autonomous Task Execution.

  ## Incident Reference
  This module was designed based on the SPEC-070 regex failure cascade
  (Dec 6-7, 2025) where 3 consecutive failures cascaded through the system.

  ## States

  - `:closed` - Normal operation, tasks execute freely
  - `:open` - Circuit tripped, all tasks are rejected until cooldown
  - `:half_open` - After cooldown, allow one task through to test

  ## Configuration

  - `max_consecutive_failures` - Number of failures before circuit opens (default: 3)
  - `cooldown_ms` - Time to wait before half-open state (default: 30_000)
  - `success_threshold` - Successes needed in half-open to close (default: 1)

  ## Usage

      state = CircuitBreaker.new()
      
      case CircuitBreaker.check(state) do
        {:closed, state} -> execute_task(state)
        {:half_open, state} -> execute_task_carefully(state)
        {:open, state} -> reject_task(state)
      end

      # After execution:
      state = CircuitBreaker.record_success(state)
      # or
      state = CircuitBreaker.record_failure(state)
  """

  require Logger

  @type circuit_state :: :closed | :open | :half_open

  @type t :: %__MODULE__{
          state: circuit_state(),
          consecutive_failures: non_neg_integer(),
          last_failure_at: DateTime.t() | nil,
          half_open_attempts: non_neg_integer(),
          config: map()
        }

  defstruct [
    :state,
    :consecutive_failures,
    :last_failure_at,
    :half_open_attempts,
    :config
  ]

  # Default configuration
  @default_max_failures 3
  @default_cooldown_ms 30_000
  @default_success_threshold 1

  @doc """
  Create a new circuit breaker with default or custom configuration.

  ## Options

    * `:max_failures` - Failures before circuit opens (default: 3)
    * `:cooldown_ms` - Cooldown period in milliseconds (default: 30_000)
    * `:success_threshold` - Successes needed to close in half-open (default: 1)

  ## Examples

      CircuitBreaker.new()
      CircuitBreaker.new(max_failures: 5, cooldown_ms: 60_000)
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    config = %{
      max_failures: Keyword.get(opts, :max_failures, @default_max_failures),
      cooldown_ms: Keyword.get(opts, :cooldown_ms, @default_cooldown_ms),
      success_threshold: Keyword.get(opts, :success_threshold, @default_success_threshold)
    }

    %__MODULE__{
      state: :closed,
      consecutive_failures: 0,
      last_failure_at: nil,
      half_open_attempts: 0,
      config: config
    }
  end

  @doc """
  Check the current circuit state and determine if operations should proceed.

  Returns a tuple of `{state, updated_circuit}` where:
  - `:closed` - Normal operation, proceed with task
  - `:half_open` - Testing after cooldown, proceed carefully
  - `:open` - Circuit tripped, reject the task

  ## Examples

      case CircuitBreaker.check(circuit) do
        {:closed, circuit} -> {:ok, circuit}
        {:half_open, circuit} -> {:ok, circuit}
        {:open, circuit} -> {:error, :circuit_open}
      end
  """
  @spec check(t()) :: {circuit_state(), t()}
  def check(%__MODULE__{} = circuit) do
    case circuit.state do
      :closed ->
        {:closed, circuit}

      :open ->
        # Check if cooldown has elapsed
        if cooldown_elapsed?(circuit) do
          Logger.info("[CircuitBreaker] Cooldown elapsed, entering half-open state")

          :telemetry.execute(
            [:mimo, :autonomous, :circuit_breaker],
            %{count: 1},
            %{transition: :open_to_half_open}
          )

          {:half_open, %{circuit | state: :half_open, half_open_attempts: 0}}
        else
          remaining = remaining_cooldown(circuit)
          Logger.debug("[CircuitBreaker] Circuit open, #{remaining}ms remaining in cooldown")
          {:open, circuit}
        end

      :half_open ->
        {:half_open, circuit}
    end
  end

  @doc """
  Record a successful operation.

  In closed state, this is a no-op.
  In half-open state, this may close the circuit if threshold is met.
  """
  @spec record_success(t()) :: t()
  def record_success(%__MODULE__{state: :closed} = circuit) do
    # Already closed, reset consecutive failures just in case
    %{circuit | consecutive_failures: 0}
  end

  def record_success(%__MODULE__{state: :half_open} = circuit) do
    attempts = circuit.half_open_attempts + 1

    if attempts >= circuit.config.success_threshold do
      Logger.info("[CircuitBreaker] Success threshold met, closing circuit")

      :telemetry.execute(
        [:mimo, :autonomous, :circuit_breaker],
        %{count: 1},
        %{transition: :half_open_to_closed}
      )

      %{circuit | state: :closed, consecutive_failures: 0, half_open_attempts: 0}
    else
      %{circuit | half_open_attempts: attempts}
    end
  end

  def record_success(%__MODULE__{state: :open} = circuit) do
    # Shouldn't happen, but handle gracefully
    Logger.warning("[CircuitBreaker] Success recorded while circuit open")
    circuit
  end

  @doc """
  Record a failed operation.

  In closed state, this may open the circuit if threshold is reached.
  In half-open state, this immediately reopens the circuit.
  """
  @spec record_failure(t(), term()) :: t()
  def record_failure(circuit, reason \\ :unknown)

  def record_failure(%__MODULE__{state: :closed} = circuit, reason) do
    failures = circuit.consecutive_failures + 1

    if failures >= circuit.config.max_failures do
      Logger.warning(
        "[CircuitBreaker] Max failures (#{failures}) reached, opening circuit. " <>
          "Last failure: #{inspect(reason)}"
      )

      :telemetry.execute(
        [:mimo, :autonomous, :circuit_breaker],
        %{count: 1},
        %{transition: :closed_to_open, reason: inspect(reason)}
      )

      %{circuit | state: :open, consecutive_failures: failures, last_failure_at: DateTime.utc_now()}
    else
      Logger.debug("[CircuitBreaker] Failure #{failures}/#{circuit.config.max_failures}")
      %{circuit | consecutive_failures: failures, last_failure_at: DateTime.utc_now()}
    end
  end

  def record_failure(%__MODULE__{state: :half_open} = circuit, reason) do
    Logger.warning("[CircuitBreaker] Failure in half-open state, reopening circuit")

    :telemetry.execute(
      [:mimo, :autonomous, :circuit_breaker],
      %{count: 1},
      %{transition: :half_open_to_open, reason: inspect(reason)}
    )

    %{
      circuit
      | state: :open,
        consecutive_failures: circuit.consecutive_failures + 1,
        last_failure_at: DateTime.utc_now(),
        half_open_attempts: 0
    }
  end

  def record_failure(%__MODULE__{state: :open} = circuit, _reason) do
    # Circuit already open, just update timestamp
    %{circuit | last_failure_at: DateTime.utc_now()}
  end

  @doc """
  Force reset the circuit breaker to closed state.

  Use this when manual intervention has resolved the underlying issue.
  """
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = circuit) do
    Logger.info("[CircuitBreaker] Manual reset to closed state")

    :telemetry.execute(
      [:mimo, :autonomous, :circuit_breaker],
      %{count: 1},
      %{transition: :manual_reset}
    )

    %{
      circuit
      | state: :closed,
        consecutive_failures: 0,
        last_failure_at: nil,
        half_open_attempts: 0
    }
  end

  @doc """
  Get the current state as a readable status map.
  """
  @spec status(t()) :: map()
  def status(%__MODULE__{} = circuit) do
    %{
      state: circuit.state,
      consecutive_failures: circuit.consecutive_failures,
      last_failure_at: circuit.last_failure_at,
      remaining_cooldown_ms: if(circuit.state == :open, do: remaining_cooldown(circuit), else: nil),
      config: circuit.config
    }
  end

  # =============================================================================
  # Private Functions
  # =============================================================================

  defp cooldown_elapsed?(%__MODULE__{last_failure_at: nil}), do: true

  defp cooldown_elapsed?(%__MODULE__{last_failure_at: last, config: config}) do
    elapsed = DateTime.diff(DateTime.utc_now(), last, :millisecond)
    elapsed >= config.cooldown_ms
  end

  defp remaining_cooldown(%__MODULE__{last_failure_at: nil}), do: 0

  defp remaining_cooldown(%__MODULE__{last_failure_at: last, config: config}) do
    elapsed = DateTime.diff(DateTime.utc_now(), last, :millisecond)
    max(0, config.cooldown_ms - elapsed)
  end
end
