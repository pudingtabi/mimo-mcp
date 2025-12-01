defmodule Mimo.Telemetry.ResourceMonitor do
  @moduledoc """
  Real-time resource monitoring for operational visibility.

  Monitors:
  - BEAM memory usage
  - ETS table sizes
  - Process counts
  - Port counts

  Emits telemetry events and logs warnings on threshold breaches.
  """
  use GenServer
  require Logger

  @memory_threshold_mb 1000
  @ets_threshold_entries 10_000
  @process_threshold 500
  @port_threshold 100
  @check_interval_ms 30_000

  # ==========================================================================
  # Client API
  # ==========================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns current resource statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Forces an immediate resource check.
  """
  @spec check_now() :: :ok
  def check_now do
    GenServer.cast(__MODULE__, :check_now)
  end

  # ==========================================================================
  # Server Callbacks
  # ==========================================================================

  @impl true
  def init(_opts) do
    schedule_check()

    state = %{
      checks: 0,
      last_check: nil,
      alerts: [],
      thresholds: %{
        memory_mb: @memory_threshold_mb,
        ets_entries: @ets_threshold_entries,
        processes: @process_threshold,
        ports: @port_threshold
      }
    }

    Logger.info("ResourceMonitor started (interval: #{@check_interval_ms}ms)")
    {:ok, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = collect_stats()
    {:reply, Map.merge(stats, %{checks: state.checks, last_check: state.last_check}), state}
  end

  @impl true
  def handle_cast(:check_now, state) do
    new_state = do_check(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:check_resources, state) do
    new_state = do_check(state)
    schedule_check()
    {:noreply, new_state}
  end

  # ==========================================================================
  # Private Functions
  # ==========================================================================

  defp schedule_check do
    Process.send_after(self(), :check_resources, @check_interval_ms)
  end

  defp do_check(state) do
    stats = collect_stats()
    alerts = check_thresholds(stats, state.thresholds)

    # Emit telemetry
    emit_telemetry(stats)

    # Log alerts
    Enum.each(alerts, fn alert ->
      Logger.warning("[ResourceMonitor] #{alert}")
    end)

    %{state | checks: state.checks + 1, last_check: DateTime.utc_now(), alerts: alerts}
  end

  defp collect_stats do
    memory = :erlang.memory()

    %{
      memory: %{
        total_mb: memory[:total] / 1_048_576,
        processes_mb: memory[:processes] / 1_048_576,
        binary_mb: memory[:binary] / 1_048_576,
        ets_mb: memory[:ets] / 1_048_576,
        atom_mb: memory[:atom] / 1_048_576
      },
      processes: %{
        count: length(Process.list()),
        schedulers: :erlang.system_info(:schedulers_online),
        run_queue: :erlang.statistics(:total_run_queue_lengths_all)
      },
      ports: %{
        count: length(Port.list())
      },
      ets: collect_ets_stats()
    }
  end

  defp collect_ets_stats do
    :ets.all()
    |> Enum.map(fn table ->
      info = :ets.info(table)

      %{
        name: info[:name],
        size: info[:size],
        memory_words: info[:memory]
      }
    end)
    |> Enum.sort_by(& &1.size, :desc)
    |> Enum.take(10)
  end

  defp check_thresholds(stats, thresholds) do
    alerts = []

    # Memory check
    alerts =
      if stats.memory.total_mb > thresholds.memory_mb do
        [
          "High memory: #{round(stats.memory.total_mb)}MB (threshold: #{thresholds.memory_mb}MB)"
          | alerts
        ]
      else
        alerts
      end

    # Process check
    alerts =
      if stats.processes.count > thresholds.processes do
        [
          "High process count: #{stats.processes.count} (threshold: #{thresholds.processes})"
          | alerts
        ]
      else
        alerts
      end

    # Port check
    alerts =
      if stats.ports.count > thresholds.ports do
        ["High port count: #{stats.ports.count} (threshold: #{thresholds.ports})" | alerts]
      else
        alerts
      end

    # ETS check
    large_tables = Enum.filter(stats.ets, fn t -> t.size > thresholds.ets_entries end)

    alerts =
      if large_tables != [] do
        table_names = Enum.map_join(large_tables, ", ", & &1.name)
        ["Large ETS tables: #{table_names}" | alerts]
      else
        alerts
      end

    alerts
  end

  defp emit_telemetry(stats) do
    # Memory telemetry
    :telemetry.execute(
      [:mimo, :system, :memory],
      %{
        total_mb: stats.memory.total_mb,
        processes_mb: stats.memory.processes_mb,
        binary_mb: stats.memory.binary_mb,
        ets_mb: stats.memory.ets_mb
      },
      %{}
    )

    # Process telemetry
    :telemetry.execute(
      [:mimo, :system, :processes],
      %{
        count: stats.processes.count,
        run_queue: stats.processes.run_queue,
        utilization: stats.processes.run_queue / stats.processes.schedulers
      },
      %{}
    )

    # Port telemetry
    :telemetry.execute(
      [:mimo, :system, :ports],
      %{count: stats.ports.count},
      %{}
    )
  end
end
