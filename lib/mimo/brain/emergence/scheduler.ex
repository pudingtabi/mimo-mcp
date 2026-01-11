defmodule Mimo.Brain.Emergence.Scheduler do
  @moduledoc """
  SPEC-044: Scheduled emergence cycle runner.

  Runs the emergence detection/amplification/promotion cycle periodically.
  Default schedule: every 6 hours during active usage.

  ## Configuration

      config :mimo, Mimo.Brain.Emergence.Scheduler,
        enabled: true,
        interval_ms: 6 * 60 * 60 * 1000,  # 6 hours
        run_on_startup: false
  """
  use GenServer
  require Logger

  alias Mimo.Brain.Emergence

  # 6 hours
  @default_interval_ms 6 * 60 * 60 * 1000
  # 1 minute delay on startup
  @startup_delay_ms 60 * 1000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Manually trigger an emergence cycle.
  """
  def run_now do
    GenServer.cast(__MODULE__, :run_cycle)
  end

  @doc """
  Get the scheduler status.
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Enable or disable the scheduler.
  """
  def set_enabled(enabled) when is_boolean(enabled) do
    GenServer.call(__MODULE__, {:set_enabled, enabled})
  end

  @impl true
  def init(_opts) do
    config = get_config()

    state = %{
      enabled: config.enabled,
      interval_ms: config.interval_ms,
      last_run: nil,
      last_result: nil,
      run_count: 0,
      error_count: 0
    }

    # Initialize emergence framework (skip in test mode to avoid DB pool exhaustion)
    if config.enabled do
      try do
        Emergence.init()
      rescue
        e -> Logger.warning("[Emergence.Scheduler] Init failed: #{Exception.message(e)}")
      end

      # Schedule first run if enabled and run_on_startup
      if config.run_on_startup do
        Process.send_after(self(), :run_cycle, @startup_delay_ms)
        Logger.info("[Emergence.Scheduler] Started, first run in #{div(@startup_delay_ms, 1000)}s")
      else
        schedule_next_cycle(state)
        Logger.info("[Emergence.Scheduler] Started, next run in #{div(state.interval_ms, 1000)}s")
      end
    else
      Logger.debug("[Emergence.Scheduler] Disabled - skipping init")
    end

    {:ok, state}
  end

  @impl true
  def handle_cast(:run_cycle, state) do
    new_state = execute_cycle(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      enabled: state.enabled,
      interval_ms: state.interval_ms,
      interval_human: format_duration(state.interval_ms),
      last_run: state.last_run,
      last_result: summarize_result(state.last_result),
      run_count: state.run_count,
      error_count: state.error_count,
      next_run_in_ms: time_to_next_run(state)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call({:set_enabled, enabled}, _from, state) do
    new_state = %{state | enabled: enabled}

    if enabled do
      schedule_next_cycle(new_state)
      Logger.info("[Emergence.Scheduler] Enabled, next run in #{div(new_state.interval_ms, 1000)}s")
    else
      Logger.info("[Emergence.Scheduler] Disabled")
    end

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:run_cycle, state) do
    new_state =
      if state.enabled do
        execute_cycle(state)
      else
        state
      end

    # Schedule next cycle
    schedule_next_cycle(new_state)

    {:noreply, new_state}
  end

  defp execute_cycle(state) do
    Logger.info("[Emergence.Scheduler] Running emergence cycle...")
    start_time = System.monotonic_time(:millisecond)

    result =
      try do
        Emergence.run_cycle()
      rescue
        e in DBConnection.OwnershipError ->
          Logger.debug(
            "[Emergence.Scheduler] Cycle skipped (sandbox mode): #{Exception.message(e)}"
          )

          {:error, :sandbox_mode}

        e in DBConnection.ConnectionError ->
          Logger.debug("[Emergence.Scheduler] Cycle skipped (connection): #{Exception.message(e)}")
          {:error, :sandbox_mode}

        e ->
          Logger.error("[Emergence.Scheduler] Cycle failed: #{Exception.message(e)}")
          {:error, Exception.message(e)}
      end

    duration_ms = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, cycle_result} ->
        Logger.info(
          "[Emergence.Scheduler] Cycle completed in #{duration_ms}ms: " <>
            "#{cycle_result.promotions.promoted} promotions, #{length(cycle_result.alerts)} alerts"
        )

        %{
          state
          | last_run: DateTime.utc_now(),
            last_result: cycle_result,
            run_count: state.run_count + 1
        }

      {:error, :sandbox_mode} ->
        # Don't count sandbox errors against the error count
        %{state | last_run: DateTime.utc_now(), last_result: result}

      {:error, _reason} ->
        %{
          state
          | last_run: DateTime.utc_now(),
            last_result: result,
            run_count: state.run_count + 1,
            error_count: state.error_count + 1
        }
    end
  end

  defp schedule_next_cycle(state) do
    if state.enabled do
      Process.send_after(self(), :run_cycle, state.interval_ms)
    end
  end

  defp get_config do
    app_config = Application.get_env(:mimo, __MODULE__, [])

    # Disable in test environment if configured
    test_disabled = Application.get_env(:mimo_mcp, :disable_emergence_scheduler, false)

    %{
      enabled: Keyword.get(app_config, :enabled, true) and not test_disabled,
      interval_ms: Keyword.get(app_config, :interval_ms, @default_interval_ms),
      run_on_startup: Keyword.get(app_config, :run_on_startup, false)
    }
  end

  defp format_duration(ms) when ms < 60_000 do
    "#{div(ms, 1000)}s"
  end

  defp format_duration(ms) when ms < 3_600_000 do
    "#{div(ms, 60_000)}m"
  end

  defp format_duration(ms) do
    "#{div(ms, 3_600_000)}h"
  end

  defp time_to_next_run(%{last_run: nil, interval_ms: interval_ms}), do: interval_ms

  defp time_to_next_run(%{last_run: last_run, interval_ms: interval_ms}) do
    elapsed = DateTime.diff(DateTime.utc_now(), last_run, :millisecond)
    max(0, interval_ms - elapsed)
  end

  defp summarize_result(nil), do: nil
  defp summarize_result({:error, reason}), do: %{status: :error, reason: reason}

  defp summarize_result(result) when is_map(result) do
    %{
      status: :ok,
      patterns_detected: map_size(result[:detection] || %{}),
      promotions: result[:promotions][:promoted] || 0,
      alerts: length(result[:alerts] || [])
    }
  end
end
