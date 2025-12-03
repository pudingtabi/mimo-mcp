defmodule Mimo.Brain.HealthMonitor do
  @moduledoc """
  Periodic health monitoring for Mimo's brain systems.

  Monitors:
  - Orphaned memories (missing embeddings)
  - Memory protection coverage
  - Duplicate content accumulation
  - Embedding generation health

  ## Usage

      # Get current health report
      Mimo.Brain.HealthMonitor.health_report()

      # Force immediate health check
      Mimo.Brain.HealthMonitor.check_now()

      # Get just the issues
      Mimo.Brain.HealthMonitor.issues()

  ## Configuration

      config :mimo_mcp, :health_monitor,
        enabled: true,
        interval_ms: 3_600_000,  # 1 hour
        alert_threshold: 3       # issues before warning
  """

  use GenServer
  require Logger
  import Ecto.Query

  alias Mimo.{Repo, Brain.Engram}

  @default_interval :timer.hours(1)

  # ==========================================================================
  # Client API
  # ==========================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get the current health report.
  """
  @spec health_report() :: map()
  def health_report do
    GenServer.call(__MODULE__, :report)
  end

  @doc """
  Force an immediate health check.
  """
  @spec check_now() :: {:ok, list()}
  def check_now do
    GenServer.call(__MODULE__, :check, 30_000)
  end

  @doc """
  Get current issues list.
  """
  @spec issues() :: list()
  def issues do
    GenServer.call(__MODULE__, :issues)
  end

  # ==========================================================================
  # Server Callbacks
  # ==========================================================================

  @impl true
  def init(_opts) do
    state = %{
      last_check: nil,
      issues: [],
      metrics: %{},
      check_count: 0
    }

    # Schedule first check after startup delay
    if get_config(:enabled, true) do
      Process.send_after(self(), :scheduled_check, 5_000)
    end

    Logger.info("[HealthMonitor] Brain health monitor initialized")
    {:ok, state}
  end

  @impl true
  def handle_call(:report, _from, state) do
    report = %{
      last_check: state.last_check,
      issues: state.issues,
      metrics: state.metrics,
      check_count: state.check_count,
      healthy: state.issues == []
    }

    {:reply, report, state}
  end

  @impl true
  def handle_call(:check, _from, state) do
    new_state = run_health_check(state)
    {:reply, {:ok, new_state.issues}, new_state}
  end

  @impl true
  def handle_call(:issues, _from, state) do
    {:reply, state.issues, state}
  end

  @impl true
  def handle_info(:scheduled_check, state) do
    new_state = run_health_check(state)
    schedule_next_check()
    {:noreply, new_state}
  end

  # ==========================================================================
  # Private Implementation
  # ==========================================================================

  defp run_health_check(state) do
    Logger.debug("[HealthMonitor] Running brain health check...")

    # Wrap in try to handle sandbox errors in tests
    try do
      metrics = collect_metrics()
      issues = analyze_issues(metrics)

      # Log warnings if issues found
      if issues != [] do
        Logger.warning("[HealthMonitor] Brain health issues detected: #{inspect(issues)}")

        :telemetry.execute(
          [:mimo, :brain, :health, :issues_detected],
          %{count: length(issues)},
          %{issues: issues}
        )
      end

      # Emit regular health telemetry
      :telemetry.execute(
        [:mimo, :brain, :health, :check],
        metrics,
        %{issues_count: length(issues)}
      )

      %{
        state
        | last_check: DateTime.utc_now(),
          issues: issues,
          metrics: metrics,
          check_count: state.check_count + 1
      }
    rescue
      e in DBConnection.OwnershipError ->
        Logger.debug("[HealthMonitor] Skipping health check in test mode: #{Exception.message(e)}")
        state

      e ->
        Logger.warning("[HealthMonitor] Health check failed: #{Exception.message(e)}")
        %{state | metrics: %{error: Exception.message(e)}}
    end
  end

  defp collect_metrics do
    %{
      total: Repo.one(from(e in Engram, select: count())) || 0,
      protected: Repo.one(from(e in Engram, where: e.protected == true, select: count())) || 0,
      orphaned: count_orphaned(),
      int8_count:
        Repo.one(
          from(e in Engram,
            where: not is_nil(e.embedding_int8) and fragment("length(?) > 0", e.embedding_int8),
            select: count()
          )
        ) || 0,
      float32_only: count_float32_only(),
      duplicates: count_duplicate_groups(),
      never_accessed:
        Repo.one(from(e in Engram, where: is_nil(e.last_accessed_at), select: count())) || 0,
      at_risk:
        Repo.one(
          from(e in Engram,
            where: e.protected == false or is_nil(e.protected),
            where: e.decay_rate > 0.01,
            select: count()
          )
        ) || 0
    }
  rescue
    e in DBConnection.OwnershipError ->
      Logger.debug(
        "[HealthMonitor] Skipping metrics collection in test mode: #{Exception.message(e)}"
      )

      %{error: :test_mode}

    e ->
      Logger.error("[HealthMonitor] Failed to collect metrics: #{Exception.message(e)}")
      %{error: Exception.message(e)}
  end

  defp count_orphaned do
    Repo.one(
      from(e in Engram,
        where:
          (is_nil(e.embedding_int8) or fragment("length(?) = 0", e.embedding_int8)) and
            (is_nil(e.embedding) or fragment("length(?) = 0", e.embedding)),
        select: count()
      )
    ) || 0
  end

  defp count_float32_only do
    Repo.one(
      from(e in Engram,
        where:
          (is_nil(e.embedding_int8) or fragment("length(?) = 0", e.embedding_int8)) and
            not is_nil(e.embedding) and e.embedding != "[]",
        select: count()
      )
    ) || 0
  end

  defp count_duplicate_groups do
    # Count content values that appear more than once
    query = """
    SELECT COUNT(*) FROM (
      SELECT content FROM engrams GROUP BY content HAVING COUNT(*) > 1
    )
    """

    case Repo.query(query) do
      {:ok, %{rows: [[count]]}} -> count
      _ -> 0
    end
  end

  defp analyze_issues(metrics) when is_map(metrics) do
    issues = []

    # Critical: No protection
    issues =
      if Map.get(metrics, :protected, 0) == 0 and Map.get(metrics, :total, 0) > 0 do
        [{:no_protection, "No memories are protected from decay"} | issues]
      else
        issues
      end

    # Critical: Orphaned memories
    issues =
      if Map.get(metrics, :orphaned, 0) > 0 do
        [{:orphaned_memories, "#{metrics.orphaned} memories have no embeddings"} | issues]
      else
        issues
      end

    # Warning: Many duplicates
    issues =
      if Map.get(metrics, :duplicates, 0) > 10 do
        [{:excessive_duplicates, "#{metrics.duplicates} duplicate content groups"} | issues]
      else
        issues
      end

    # Info: Legacy float32
    issues =
      if Map.get(metrics, :float32_only, 0) > 50 do
        [{:legacy_embeddings, "#{metrics.float32_only} memories still use float32"} | issues]
      else
        issues
      end

    # Warning: Low protection ratio
    total = Map.get(metrics, :total, 0)
    protected = Map.get(metrics, :protected, 0)

    issues =
      if total > 100 and protected / total < 0.05 do
        [{:low_protection, "Only #{Float.round(protected / total * 100, 1)}% protected"} | issues]
      else
        issues
      end

    issues
  end

  defp analyze_issues(_), do: []

  defp schedule_next_check do
    interval = get_config(:interval_ms, @default_interval)
    Process.send_after(self(), :scheduled_check, interval)
  end

  defp get_config(key, default) do
    Application.get_env(:mimo_mcp, :health_monitor, [])
    |> Keyword.get(key, default)
  end
end
