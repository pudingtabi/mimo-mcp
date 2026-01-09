defmodule Mimo.SystemHealth do
  @moduledoc """
  Aggregates health metrics from all robustness subsystems.

  Provides a single function to check overall system health, combining:
  - HNSW Index status
  - Backup verification status
  - Instance lock status
  - Database metrics
  - Memory usage

  ## Usage

      # Get full health report
      health = Mimo.SystemHealth.check()
      #=> %{status: :healthy, checks: %{...}, timestamp: ~U[...]}

      # Quick health check (just status)
      :healthy = Mimo.SystemHealth.status()

  ## Integration

  Called by:
  - HealthController for HTTP /health endpoint
  - MCP tools for monitoring
  - SleepCycle for periodic health logging
  """

  require Logger

  alias Mimo.Brain.{BackupVerifier, Engram, HnswIndex}
  alias Mimo.Cognitive.FeedbackLoop
  alias Mimo.InstanceLock
  alias Mimo.Repo

  import Ecto.Query

  @doc """
  Performs a comprehensive health check of all subsystems.

  Returns a map with:
  - `:status` - Overall status (:healthy, :degraded, :critical)
  - `:checks` - Individual check results
  - `:timestamp` - When the check was performed
  """
  @spec check() :: map()
  def check do
    checks = %{
      hnsw: check_hnsw(),
      backup: check_backup(),
      instance_lock: check_lock(),
      database: check_database(),
      system: check_system()
    }

    overall_status = determine_overall_status(checks)

    %{
      status: overall_status,
      checks: checks,
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Returns just the overall health status.
  """
  @spec status() :: :healthy | :degraded | :critical
  def status do
    check().status
  end

  @doc """
  Returns a summary suitable for logging.
  """
  @spec summary() :: String.t()
  def summary do
    health = check()

    status_emoji =
      case health.status do
        :healthy -> "✓"
        :degraded -> "⚠"
        :critical -> "✗"
      end

    checks_summary =
      health.checks
      |> Enum.map(fn {name, result} ->
        check_status = Map.get(result, :status, :unknown)
        "#{name}=#{check_status}"
      end)
      |> Enum.join(", ")

    "#{status_emoji} System #{health.status}: #{checks_summary}"
  end

  # Individual check functions

  defp check_hnsw do
    case HnswIndex.health_check() do
      {:healthy, db_count, index_count} ->
        %{status: :healthy, db_count: db_count, index_count: index_count}

      {:desync, db_count, index_count} ->
        %{status: :degraded, db_count: db_count, index_count: index_count, issue: :desync}

      {:empty_index, db_count, index_count} ->
        %{status: :degraded, db_count: db_count, index_count: index_count, issue: :empty}

      {:not_running, _, _} ->
        %{status: :unknown, issue: :not_running}

      {:not_initialized, _, _} ->
        %{status: :unknown, issue: :not_initialized}
    end
  end

  defp check_backup do
    case BackupVerifier.latest_status() do
      nil ->
        %{status: :unknown, issue: :no_backups}

      status ->
        if status.verified do
          %{
            status: :healthy,
            latest: status.name,
            verified_at: status.verified_at,
            engram_count: status.engram_count
          }
        else
          %{
            status: :degraded,
            latest: status.name,
            issue: :unverified
          }
        end
    end
  end

  defp check_lock do
    lock_status = InstanceLock.status()

    %{
      status: if(lock_status.locked, do: :healthy, else: :unknown),
      locked: lock_status.locked,
      holder_pid: lock_status.holder_pid,
      started_at: lock_status.started_at
    }
  end

  defp check_database do
    try do
      engram_count = Repo.one(from(e in Engram, select: count(e.id))) || 0

      # Quick integrity check (just verify we can query)
      _test_query = Repo.one(from(e in Engram, limit: 1, select: e.id))

      %{
        status: :healthy,
        engram_count: engram_count,
        connection: :ok
      }
    rescue
      e ->
        %{
          status: :critical,
          error: Exception.message(e),
          connection: :error
        }
    end
  end

  defp check_system do
    # Get BEAM uptime
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    uptime_formatted = format_uptime(uptime_ms)

    # Memory info
    memory = :erlang.memory()
    total_mb = Float.round(memory[:total] / 1024 / 1024, 1)
    processes_mb = Float.round(memory[:processes] / 1024 / 1024, 1)

    %{
      status: :healthy,
      uptime: uptime_formatted,
      uptime_ms: uptime_ms,
      memory_total_mb: total_mb,
      memory_processes_mb: processes_mb,
      scheduler_count: :erlang.system_info(:schedulers_online)
    }
  end

  # Status determination

  defp determine_overall_status(checks) do
    statuses = Enum.map(checks, fn {_name, result} -> Map.get(result, :status, :unknown) end)

    cond do
      :critical in statuses -> :critical
      :degraded in statuses -> :degraded
      Enum.all?(statuses, &(&1 == :healthy)) -> :healthy
      true -> :degraded
    end
  end

  @doc """
  Returns metrics suitable for tool dispatchers.
  Alias for check() for backward compatibility.
  """
  @spec get_metrics() :: map()
  def get_metrics, do: check()

  @doc """
  Returns memory quality metrics for data quality monitoring.

  Part of Phase 2: Data Quality Excellence (Q6).

  Returns:
  - Category distribution (counts per memory type)
  - Average content length by category
  - Quality thresholds and current values
  - Alerts for any metrics below threshold
  """
  @spec quality_metrics() :: map()
  def quality_metrics do
    try do
      # Get category distribution
      category_stats =
        Repo.all(
          from(e in Engram,
            group_by: e.category,
            select: {e.category, count(e.id), avg(fragment("LENGTH(content)"))}
          )
        )

      categories =
        Enum.into(category_stats, %{}, fn {cat, count, avg_len} ->
          {cat, %{count: count, avg_length: round_or_nil(avg_len)}}
        end)

      # Check synthesized insights specifically
      synthesis_stats =
        Repo.one(
          from(e in Engram,
            where: like(e.content, "%[Synthesized Insight]%"),
            select: {count(e.id), avg(fragment("LENGTH(content)")), avg(e.importance)}
          )
        )

      {synth_count, synth_avg_len, synth_avg_imp} = synthesis_stats || {0, 0, 0}

      # Quality thresholds (from Phase 2 implementation)
      thresholds = %{
        entity_anchor_min_length: 50,
        synthesis_min_length: 100,
        synthesis_min_importance: 0.6
      }

      # Calculate alerts
      alerts = calculate_quality_alerts(categories, synth_avg_len, synth_avg_imp, thresholds)

      # L5: Get confidence calibration warnings
      calibration_warnings = get_calibration_warnings()
      all_alerts = alerts ++ calibration_warnings

      %{
        status: if(all_alerts == [], do: :healthy, else: :warning),
        categories: categories,
        synthesis: %{
          count: synth_count,
          avg_length: round_or_nil(synth_avg_len),
          avg_importance: round_or_nil(synth_avg_imp)
        },
        thresholds: thresholds,
        alerts: all_alerts,
        calibration: get_calibration_summary(),
        timestamp: DateTime.utc_now()
      }
    rescue
      e ->
        %{
          status: :error,
          error: Exception.message(e),
          timestamp: DateTime.utc_now()
        }
    end
  end

  defp calculate_quality_alerts(categories, synth_avg_len, synth_avg_imp, thresholds) do
    alerts = []

    # Check entity anchor quality
    entity_stats = Map.get(categories, "entity_anchor", %{avg_length: 0})

    alerts =
      if entity_stats[:avg_length] &&
           entity_stats[:avg_length] < thresholds.entity_anchor_min_length do
        [
          "Entity anchors below length threshold (#{entity_stats[:avg_length]} < #{thresholds.entity_anchor_min_length})"
          | alerts
        ]
      else
        alerts
      end

    # Check synthesis quality
    alerts =
      if synth_avg_len && synth_avg_len < thresholds.synthesis_min_length do
        [
          "Synthesized insights below length threshold (#{round_or_nil(synth_avg_len)} < #{thresholds.synthesis_min_length})"
          | alerts
        ]
      else
        alerts
      end

    alerts =
      if synth_avg_imp && synth_avg_imp < thresholds.synthesis_min_importance do
        [
          "Synthesized insights below importance threshold (#{round_or_nil(synth_avg_imp)} < #{thresholds.synthesis_min_importance})"
          | alerts
        ]
      else
        alerts
      end

    alerts
  end

  defp round_or_nil(nil), do: nil
  defp round_or_nil(value) when is_float(value), do: Float.round(value, 1)
  defp round_or_nil(value), do: value

  # Helpers

  defp format_uptime(ms) do
    seconds = div(ms, 1000)
    minutes = div(seconds, 60)
    hours = div(minutes, 60)
    days = div(hours, 24)

    cond do
      days > 0 -> "#{days}d #{rem(hours, 24)}h"
      hours > 0 -> "#{hours}h #{rem(minutes, 60)}m"
      minutes > 0 -> "#{minutes}m #{rem(seconds, 60)}s"
      true -> "#{seconds}s"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # L5: Confidence Calibration Integration
  # ─────────────────────────────────────────────────────────────────

  defp get_calibration_warnings do
    try do
      FeedbackLoop.calibration_warnings()
      |> Enum.map(fn warning ->
        warning.message
      end)
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  defp get_calibration_summary do
    try do
      [:prediction, :classification, :retrieval, :tool_execution]
      |> Enum.map(fn category ->
        cal = FeedbackLoop.get_calibration(category)

        {category,
         %{
           factor: cal.calibration_factor,
           samples: cal.sample_count,
           reliability: cal.reliability
         }}
      end)
      |> Map.new()
    rescue
      _ -> %{}
    catch
      :exit, _ -> %{}
    end
  end
end
