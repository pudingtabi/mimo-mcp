defmodule Mimo.Cognitive.HealthWatcher do
  @moduledoc """
  Phase 5 C1: Autonomous Health Monitoring

  Proactively monitors Mimo's cognitive health and triggers maintenance
  when issues are detected. This moves beyond scheduled maintenance to
  event-driven self-care.

  ## Philosophy

  Rather than waiting for problems to compound, HealthWatcher:
  1. Continuously monitors health metrics
  2. Detects degradation trends early
  3. Triggers appropriate interventions
  4. Logs actions for transparency

  ## Monitored Metrics

  - Memory quality (average importance, length trends)
  - Learning effectiveness (FeedbackLoop metrics)
  - Calibration accuracy (confidence vs actual)
  - Emergence health (pattern generation rate)
  - Vector index health (HNSW integrity)

  ## Interventions

  When issues are detected, HealthWatcher can:
  - Trigger garbage collection
  - Request backup verification
  - Log warnings for human review
  - Suggest parameter adjustments (via MetaLearner)

  ## Integration

  Started as part of the supervision tree.
  Exposes status via `HealthWatcher.status/0`.
  """

  use GenServer
  require Logger

  alias Mimo.Cognitive.{EvolutionDashboard, MetaLearner}
  alias Mimo.SystemHealth

  # Configuration
  # Check every 5 minutes
  @check_interval_ms 60_000 * 5
  # 20% drop triggers alert
  @degradation_threshold 0.2
  # 40% drop triggers intervention
  @critical_threshold 0.4

  # Health history window
  # Keep last 12 checks (1 hour at 5min intervals)
  @history_size 12

  # ─────────────────────────────────────────────────────────────────
  # Public API
  # ─────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets the current health monitoring status.
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Gets the health history over the monitoring window.
  """
  @spec history() :: [map()]
  def history do
    GenServer.call(__MODULE__, :history)
  end

  @doc """
  Forces an immediate health check.
  """
  @spec check_now() :: map()
  def check_now do
    GenServer.call(__MODULE__, :check_now)
  end

  @doc """
  Gets any active alerts.
  """
  @spec alerts() :: [map()]
  def alerts do
    GenServer.call(__MODULE__, :alerts)
  end

  # ─────────────────────────────────────────────────────────────────
  # GenServer Implementation
  # ─────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # Schedule first check
    schedule_check()

    state = %{
      history: [],
      alerts: [],
      last_check: nil,
      interventions_triggered: 0,
      started_at: DateTime.utc_now()
    }

    Logger.info("[HealthWatcher] Phase 5 C1 autonomous monitoring started")
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      monitoring: true,
      last_check: state.last_check,
      checks_in_history: length(state.history),
      active_alerts: length(state.alerts),
      interventions_triggered: state.interventions_triggered,
      uptime: DateTime.diff(DateTime.utc_now(), state.started_at, :second),
      next_check_in_ms: @check_interval_ms
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call(:history, _from, state) do
    {:reply, state.history, state}
  end

  @impl true
  def handle_call(:alerts, _from, state) do
    {:reply, state.alerts, state}
  end

  @impl true
  def handle_call(:check_now, _from, state) do
    {check_result, new_state} = perform_health_check(state)
    {:reply, check_result, new_state}
  end

  @impl true
  def handle_info(:scheduled_check, state) do
    {_check_result, new_state} = perform_health_check(state)

    # Schedule next check
    schedule_check()

    {:noreply, new_state}
  end

  # ─────────────────────────────────────────────────────────────────
  # Health Check Logic
  # ─────────────────────────────────────────────────────────────────

  defp schedule_check do
    Process.send_after(self(), :scheduled_check, @check_interval_ms)
  end

  defp perform_health_check(state) do
    timestamp = DateTime.utc_now()

    # Gather current metrics
    evolution_score = safe_call(fn -> EvolutionDashboard.evolution_score() end, %{})
    system_health = safe_call(fn -> SystemHealth.check() end, %{})
    meta_insights = safe_call(fn -> MetaLearner.meta_insights() end, %{})

    current_score = Map.get(evolution_score, :overall_score, 0.5)
    component_scores = Map.get(evolution_score, :components, %{})

    check_result = %{
      timestamp: timestamp,
      overall_score: current_score,
      components: component_scores,
      system_status: Map.get(system_health, :status, :unknown),
      level: Map.get(evolution_score, :level, :unknown)
    }

    # Add to history (keep last N)
    new_history = [check_result | Enum.take(state.history, @history_size - 1)]

    # Analyze for degradation
    {alerts, interventions} = analyze_health_trends(new_history, meta_insights)

    # Execute any interventions
    new_interventions_count = state.interventions_triggered + length(interventions)

    Enum.each(interventions, fn intervention ->
      execute_intervention(intervention)
    end)

    new_state = %{
      state
      | history: new_history,
        alerts: alerts,
        last_check: timestamp,
        interventions_triggered: new_interventions_count
    }

    {check_result, new_state}
  end

  defp analyze_health_trends(history, meta_insights) do
    # Need at least 3 data points for trend analysis
    {degradation_alerts, degradation_interventions} =
      if length(history) >= 3 do
        [latest | older] = history
        latest_score = latest.overall_score

        # Calculate average of older scores
        older_avg =
          older
          |> Enum.map(& &1.overall_score)
          |> average()

        drop = older_avg - latest_score

        # Check for degradation
        alerts =
          if drop > @degradation_threshold do
            [
              %{
                type: :degradation,
                severity: if(drop > @critical_threshold, do: :critical, else: :warning),
                message:
                  "Cognitive score dropped by #{round(drop * 100)}% (#{round(older_avg * 100)}% → #{round(latest_score * 100)}%)",
                timestamp: DateTime.utc_now()
              }
            ]
          else
            []
          end

        # Check for critical drop
        interventions =
          if drop > @critical_threshold do
            [
              %{
                type: :trigger_maintenance,
                reason: "Critical cognitive degradation detected"
              }
            ]
          else
            []
          end

        # Check individual components for issues
        Enum.each([:memory, :learning, :emergence, :health], fn component ->
          component_score = Map.get(latest.components, component, 0.5)

          if component_score < 0.3 do
            Logger.warning(
              "[HealthWatcher] Component #{component} critically low: #{round(component_score * 100)}%"
            )
          end
        end)

        {alerts, interventions}
      else
        {[], []}
      end

    # Add alerts from meta-insights
    high_priority = get_in(meta_insights, [:high_priority_recommendations]) || []

    meta_alerts =
      if length(high_priority) > 0 do
        [
          %{
            type: :meta_learning,
            severity: :info,
            message: "#{length(high_priority)} high-priority parameter adjustment(s) recommended",
            timestamp: DateTime.utc_now()
          }
        ]
      else
        []
      end

    {degradation_alerts ++ meta_alerts, degradation_interventions}
  end

  defp execute_intervention(intervention) do
    # Spawn to avoid deadlock - SafeHealer.auto_heal may call back to HealthWatcher
    Task.start(fn ->
      case intervention.type do
        :trigger_maintenance ->
          Logger.warning("[HealthWatcher] Intervention: #{intervention.reason}")
          # Trigger SafeHealer auto-heal for low-risk interventions
          result = Mimo.Cognitive.SafeHealer.auto_heal()

          Logger.info(
            "[HealthWatcher] SafeHealer result: executed=#{length(result.executed)}, skipped=#{length(result.skipped_medium_risk)}"
          )

        :run_maintenance ->
          Logger.info("[HealthWatcher] Running maintenance cycle")
          Mimo.SleepCycle.run_cycle(force: true)

        other ->
          Logger.info("[HealthWatcher] Unknown intervention type: #{inspect(other)}")
      end
    end)

    :ok
  end

  defp average([]), do: 0.0
  defp average(list), do: Enum.sum(list) / length(list)

  defp safe_call(fun, default) do
    try do
      fun.()
    rescue
      _ -> default
    catch
      :exit, _ -> default
    end
  end
end
