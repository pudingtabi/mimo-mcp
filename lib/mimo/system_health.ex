defmodule Mimo.SystemHealth do
  @moduledoc """
  System health monitoring for Mimo infrastructure.

  Tracks memory corpus size, query latency, ETS table usage.
  Provides visibility into system health before performance degradation.

  Part of IMPLEMENTATION_PLAN_Q1_2026 Phase 1: Foundation Hardening.

  ## Alert Thresholds

  Thresholds are set at ~70% of estimated capacity to give early warning:
  - memory_count: 50,000 (70% of ~70K estimated before degradation)
  - relationship_count: 100,000 (70% of ~140K estimated)
  - ets_table_mb: 500 MB total across all Mimo ETS tables
  - query_latency_ms: 1,000 ms for semantic search

  ## Usage

      # Get current metrics
      Mimo.SystemHealth.get_metrics()

      # Check health status
      Mimo.SystemHealth.healthy?()
  """

  use GenServer
  require Logger

  @check_interval :timer.minutes(5)
  @alert_thresholds %{
    memory_count: 50_000,
    relationship_count: 100_000,
    ets_table_mb: 500,
    query_latency_ms: 1000
  }

  # Known Mimo ETS tables to monitor
  @mimo_ets_tables [
    :adoption_metrics,
    :working_memory,
    :uncertainty_tracker,
    :classifier_cache,
    :embedding_cache,
    :file_read_cache,
    :emergence_patterns,
    :reasoning_sessions,
    :awakening_sessions,
    :cognitive_lifecycle,
    :reflector_optimizer,
    :knowledge_syncer,
    :onboard_tracker,
    :verification_tracker
  ]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get current health metrics and any active alerts.

  Returns a map with:
  - `timestamp` - When metrics were last collected
  - `metrics` - Current metric values
  - `alerts` - List of threshold violations (empty if healthy)
  - `thresholds` - Current alert threshold values
  """
  def get_metrics do
    GenServer.call(__MODULE__, :get_metrics)
  end

  @doc """
  Returns true if no alerts are active.
  """
  def healthy? do
    case get_metrics() do
      %{alerts: []} -> true
      %{alerts: alerts} when is_list(alerts) -> alerts == []
      _ -> false
    end
  end

  @doc """
  Force a health check immediately (useful for testing).
  """
  def check_now do
    GenServer.call(__MODULE__, :check_now)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Schedule first check after a short delay to let system stabilize
    Process.send_after(self(), :check_health, :timer.seconds(30))

    Logger.info("[SystemHealth] Started health monitoring (check interval: 5 min)")

    {:ok,
     %{
       last_check: nil,
       alerts: [],
       metrics: %{},
       check_count: 0
     }}
  end

  @impl true
  def handle_info(:check_health, state) do
    metrics = collect_metrics()
    alerts = check_thresholds(metrics)

    # Log alerts if any
    if alerts != [] do
      Logger.warning("""
      [SystemHealth] ⚠️ Health alerts detected:
      #{format_alerts(alerts)}
      """)
    end

    schedule_check()

    {:noreply,
     %{
       state
       | last_check: DateTime.utc_now(),
         alerts: alerts,
         metrics: metrics,
         check_count: state.check_count + 1
     }}
  end

  @impl true
  def handle_call(:get_metrics, _from, state) do
    result = %{
      timestamp: state.last_check,
      metrics: state.metrics,
      alerts: state.alerts,
      thresholds: @alert_thresholds,
      check_count: state.check_count
    }

    {:reply, result, state}
  end

  @impl true
  def handle_call(:check_now, _from, state) do
    metrics = collect_metrics()
    alerts = check_thresholds(metrics)

    new_state = %{
      state
      | last_check: DateTime.utc_now(),
        alerts: alerts,
        metrics: metrics,
        check_count: state.check_count + 1
    }

    result = %{
      timestamp: new_state.last_check,
      metrics: new_state.metrics,
      alerts: new_state.alerts,
      thresholds: @alert_thresholds,
      check_count: new_state.check_count
    }

    {:reply, result, new_state}
  end

  # Private Functions

  defp collect_metrics do
    %{
      memory_count: count_memories(),
      relationship_count: count_relationships(),
      ets_tables: ets_table_stats(),
      ets_total_mb: calculate_total_ets_mb(),
      query_latency_ms: measure_query_latency()
    }
  end

  defp count_memories do
    # Query episodic store for engram count
    try do
      Mimo.Repo.aggregate(Mimo.Brain.Engram, :count, :id)
    rescue
      e ->
        Logger.debug("[SystemHealth] Failed to count memories: #{Exception.message(e)}")
        0
    end
  end

  defp count_relationships do
    # Query semantic store for triple count
    try do
      Mimo.Repo.aggregate(Mimo.SemanticStore.Triple, :count, :id)
    rescue
      e ->
        Logger.debug("[SystemHealth] Failed to count relationships: #{Exception.message(e)}")
        0
    end
  end

  defp ets_table_stats do
    # Get info for all known Mimo ETS tables
    @mimo_ets_tables
    |> Enum.map(fn table ->
      stats =
        try do
          case :ets.info(table) do
            :undefined ->
              %{size: 0, memory_bytes: 0, status: :not_found}

            info when is_list(info) ->
              %{
                size: Keyword.get(info, :size, 0),
                memory_bytes: Keyword.get(info, :memory, 0) * :erlang.system_info(:wordsize)
              }

            _ ->
              %{size: 0, memory_bytes: 0, status: :not_found}
          end
        rescue
          ArgumentError ->
            %{size: 0, memory_bytes: 0, status: :not_found}
        end

      {table, stats}
    end)
    |> Enum.into(%{})
  end

  defp calculate_total_ets_mb do
    # Sum all ETS table memory in MB
    @mimo_ets_tables
    |> Enum.map(fn table ->
      try do
        info = :ets.info(table)

        if info do
          Keyword.get(info, :memory, 0) * :erlang.system_info(:wordsize)
        else
          0
        end
      rescue
        _ -> 0
      end
    end)
    |> Enum.sum()
    # Convert to MB
    |> Kernel./(1024 * 1024)
    |> Float.round(2)
  end

  defp measure_query_latency do
    # Simple semantic search benchmark
    # Uses a common query pattern to measure real-world latency
    start = System.monotonic_time(:millisecond)

    try do
      # Use Brain.Memory.search with a simple query
      Mimo.Brain.Memory.search("system health benchmark query", limit: 5)
      System.monotonic_time(:millisecond) - start
    rescue
      e ->
        Logger.debug("[SystemHealth] Failed to measure query latency: #{Exception.message(e)}")
        0
    end
  end

  defp check_thresholds(metrics) do
    alerts = []

    # Check memory count
    alerts =
      if metrics.memory_count > @alert_thresholds.memory_count do
        [{:memory_count, metrics.memory_count, @alert_thresholds.memory_count} | alerts]
      else
        alerts
      end

    # Check relationship count
    alerts =
      if metrics.relationship_count > @alert_thresholds.relationship_count do
        [
          {:relationship_count, metrics.relationship_count, @alert_thresholds.relationship_count}
          | alerts
        ]
      else
        alerts
      end

    # Check ETS memory
    alerts =
      if metrics.ets_total_mb > @alert_thresholds.ets_table_mb do
        [{:ets_table_mb, metrics.ets_total_mb, @alert_thresholds.ets_table_mb} | alerts]
      else
        alerts
      end

    # Check query latency
    alerts =
      if metrics.query_latency_ms > @alert_thresholds.query_latency_ms do
        [{:query_latency_ms, metrics.query_latency_ms, @alert_thresholds.query_latency_ms} | alerts]
      else
        alerts
      end

    alerts
  end

  defp format_alerts(alerts) do
    Enum.map_join(alerts, "\n", fn {metric, value, threshold} ->
      "  - #{metric}: #{value} (threshold: #{threshold})"
    end)
  end

  defp schedule_check do
    Process.send_after(self(), :check_health, @check_interval)
  end
end
