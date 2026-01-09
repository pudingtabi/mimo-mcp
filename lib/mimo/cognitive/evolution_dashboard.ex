defmodule Mimo.Cognitive.EvolutionDashboard do
  @moduledoc """
  Phase 5 C3: Evolution Metrics Dashboard

  Provides a unified view of Mimo's cognitive evolution over time.
  Tracks growth in memory, learning effectiveness, emergence patterns,
  and overall system health.

  ## Purpose

  This dashboard answers the question: "Is Mimo getting smarter?"

  By aggregating metrics across all cognitive subsystems, it provides:
  - Current snapshot of cognitive capabilities
  - Historical trends (improving, stable, declining)
  - Growth metrics (memory accumulation, pattern emergence)
  - Health indicators (calibration, learning effectiveness)

  ## Usage

      # Get full evolution dashboard
      EvolutionDashboard.snapshot()

      # Get specific category
      EvolutionDashboard.memory_evolution()
      EvolutionDashboard.learning_evolution()
      EvolutionDashboard.emergence_evolution()

  ## Integration

  Exposed via `meta operation=evolution_dashboard` MCP tool.
  """

  require Logger

  alias Mimo.Brain.{Engram, HebbianLearner, HnswIndex}
  alias Mimo.Brain.Emergence.{Pattern, Promoter}
  alias Mimo.Cognitive.{FeedbackLoop, MetaLearner}
  alias Mimo.Repo
  alias Mimo.SystemHealth

  import Ecto.Query

  # ─────────────────────────────────────────────────────────────────
  # Public API
  # ─────────────────────────────────────────────────────────────────

  @doc """
  Gets a comprehensive snapshot of Mimo's cognitive evolution.

  Returns metrics across all dimensions: memory, learning, emergence, and health.
  """
  @spec snapshot() :: map()
  def snapshot do
    %{
      memory: memory_evolution(),
      learning: learning_evolution(),
      emergence: emergence_evolution(),
      health: health_evolution(),
      summary: compute_summary(),
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Gets memory evolution metrics.

  Tracks memory accumulation, quality, and organization.
  """
  @spec memory_evolution() :: map()
  def memory_evolution do
    memory_stats = get_memory_stats()
    quality_metrics = safe_call(fn -> SystemHealth.quality_metrics() end, %{})

    %{
      total_memories: memory_stats.total,
      by_category: memory_stats.by_category,
      growth: %{
        last_7d: memory_stats.recent_7d,
        last_30d: memory_stats.recent_30d,
        growth_rate: compute_growth_rate(memory_stats)
      },
      quality: %{
        avg_importance: memory_stats.avg_importance,
        avg_length: memory_stats.avg_length,
        quality_status: get_in(quality_metrics, [:status]) || :unknown
      },
      vector_index: get_hnsw_stats(),
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Gets learning evolution metrics.

  Tracks learning effectiveness across all learning strategies.
  """
  @spec learning_evolution() :: map()
  def learning_evolution do
    # Get learning effectiveness from FeedbackLoop
    effectiveness = safe_call(fn -> FeedbackLoop.learning_effectiveness() end, %{})

    # Get meta-learner analysis
    meta_analysis = safe_call(fn -> MetaLearner.analyze_strategy_effectiveness() end, %{})

    # Get calibration data
    calibration = get_calibration_summary()

    # Get Hebbian stats
    hebbian_stats = safe_call(fn -> HebbianLearner.stats() end, %{})

    %{
      overall_effectiveness: Map.get(effectiveness, :overall_learning_health, :unknown),
      by_strategy: Map.get(meta_analysis, :strategies, %{}),
      strategy_rankings: Map.get(meta_analysis, :rankings, []),
      calibration: calibration,
      hebbian: %{
        edges_created: Map.get(hebbian_stats, :edges_created, 0),
        outcome_edges: Map.get(hebbian_stats, :outcome_edges_created, 0),
        strengthened: Map.get(hebbian_stats, :outcome_edges_strengthened, 0)
      },
      trends: Map.get(effectiveness, :trends, %{}),
      recommendations: safe_call(fn -> MetaLearner.recommend_parameter_adjustments() end, []),
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Gets emergence evolution metrics.

  Tracks pattern detection, promotion, and capability generation.
  """
  @spec emergence_evolution() :: map()
  def emergence_evolution do
    pattern_stats = safe_call(fn -> Pattern.stats() end, %{})
    promoter_stats = safe_call(fn -> Promoter.stats() end, %{})
    meta_patterns = safe_call(fn -> MetaLearner.detect_meta_patterns() end, %{})

    %{
      patterns: %{
        total: Map.get(pattern_stats, :total, 0),
        by_status: Map.get(pattern_stats, :by_status, %{}),
        by_type: Map.get(pattern_stats, :by_type, %{}),
        recent_7d: Map.get(pattern_stats, :recent_7d, 0),
        avg_success_rate: Map.get(pattern_stats, :avg_success_rate, 0.0)
      },
      promotion: %{
        total_promoted: Map.get(promoter_stats, :promoted_count, 0),
        promotion_rate: Map.get(promoter_stats, :promotion_rate, 0.0),
        by_type: Map.get(promoter_stats, :promoted_by_type, %{})
      },
      meta_patterns: %{
        high_value_modes: Map.get(meta_patterns, :high_value_modes, []),
        insights: Map.get(meta_patterns, :meta_insights, [])
      },
      capabilities_generated: count_capabilities(),
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Gets health evolution metrics.

  Tracks system health, stability, and self-monitoring capabilities.
  """
  @spec health_evolution() :: map()
  def health_evolution do
    system_health = safe_call(fn -> SystemHealth.check() end, %{})
    quality = safe_call(fn -> SystemHealth.quality_metrics() end, %{})

    %{
      status: Map.get(system_health, :status, :unknown),
      uptime: Map.get(system_health, :uptime, "unknown"),
      checks: summarize_health_checks(system_health),
      quality_alerts: Map.get(quality, :alerts, []),
      calibration_status: get_calibration_health(),
      memory_db_health: get_db_health(),
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Computes the overall evolution summary with a single "cognitive score".
  """
  @spec evolution_score() :: map()
  def evolution_score do
    memory = memory_evolution()
    learning = learning_evolution()
    emergence = emergence_evolution()
    health = health_evolution()

    # Compute component scores (0-1)
    memory_score = compute_memory_score(memory)
    learning_score = compute_learning_score(learning)
    emergence_score = compute_emergence_score(emergence)
    health_score = compute_health_score(health)

    # Weighted average
    overall =
      memory_score * 0.25 +
        learning_score * 0.30 +
        emergence_score * 0.25 +
        health_score * 0.20

    level = score_to_level(overall)

    %{
      overall_score: Float.round(overall, 3),
      level: level,
      components: %{
        memory: Float.round(memory_score, 3),
        learning: Float.round(learning_score, 3),
        emergence: Float.round(emergence_score, 3),
        health: Float.round(health_score, 3)
      },
      interpretation: interpret_score(overall, level),
      timestamp: DateTime.utc_now()
    }
  end

  # ─────────────────────────────────────────────────────────────────
  # Private Helpers
  # ─────────────────────────────────────────────────────────────────

  defp safe_call(fun, default) do
    try do
      fun.()
    rescue
      _ -> default
    catch
      :exit, _ -> default
    end
  end

  defp get_memory_stats do
    total = Repo.aggregate(Engram, :count, :id)

    by_category =
      from(e in Engram, group_by: e.category, select: {e.category, count(e.id)})
      |> Repo.all()
      |> Map.new()

    # Recent additions
    seven_days_ago = DateTime.add(DateTime.utc_now(), -7, :day)
    thirty_days_ago = DateTime.add(DateTime.utc_now(), -30, :day)

    recent_7d =
      from(e in Engram, where: e.inserted_at >= ^seven_days_ago)
      |> Repo.aggregate(:count, :id)

    recent_30d =
      from(e in Engram, where: e.inserted_at >= ^thirty_days_ago)
      |> Repo.aggregate(:count, :id)

    avg_importance = Repo.aggregate(Engram, :avg, :importance) || 0.0

    avg_length =
      from(e in Engram, select: avg(fragment("LENGTH(content)")))
      |> Repo.one() || 0.0

    %{
      total: total,
      by_category: by_category,
      recent_7d: recent_7d,
      recent_30d: recent_30d,
      avg_importance: avg_importance |> Float.round(3),
      avg_length: avg_length |> Float.round(1)
    }
  end

  defp compute_growth_rate(%{total: total, recent_30d: recent_30d}) when total > 0 do
    # Growth rate as percentage of total in last 30 days
    rate = recent_30d / total
    Float.round(rate * 100, 1)
  end

  defp compute_growth_rate(_), do: 0.0

  defp get_hnsw_stats do
    safe_call(
      fn ->
        stats = HnswIndex.stats()

        %{
          vectors: Map.get(stats, :count, 0),
          status: Map.get(stats, :status, :unknown)
        }
      end,
      %{vectors: 0, status: :unknown}
    )
  end

  defp get_calibration_summary do
    [:prediction, :classification, :retrieval, :tool_execution]
    |> Enum.map(fn cat ->
      cal = safe_call(fn -> FeedbackLoop.get_calibration(cat) end, %{})

      {cat,
       %{
         factor: Map.get(cal, :calibration_factor, 1.0),
         reliability: Map.get(cal, :reliability, :unknown),
         samples: Map.get(cal, :sample_count, 0)
       }}
    end)
    |> Map.new()
  end

  defp get_calibration_health do
    warnings = safe_call(fn -> FeedbackLoop.calibration_warnings() end, [])

    cond do
      warnings == [] -> :healthy
      length(warnings) <= 2 -> :minor_issues
      true -> :needs_attention
    end
  end

  defp count_capabilities do
    # Count promoted patterns (they become capabilities)
    safe_call(fn -> Pattern.count_promoted() end, 0)
  end

  defp summarize_health_checks(health) do
    checks = Map.get(health, :checks, %{})

    checks
    |> Enum.map(fn {name, check} ->
      {name, Map.get(check, :status, :unknown)}
    end)
    |> Map.new()
  end

  defp get_db_health do
    # Simple check - can we query?
    case Repo.aggregate(Engram, :count, :id) do
      n when is_integer(n) -> :healthy
      _ -> :unknown
    end
  rescue
    _ -> :error
  end

  defp compute_summary do
    score_data = evolution_score()

    %{
      cognitive_level: score_data.level,
      overall_score: score_data.overall_score,
      interpretation: score_data.interpretation
    }
  end

  # Score computation helpers

  defp compute_memory_score(memory) do
    total = get_in(memory, [:total_memories]) || 0
    growth_rate = get_in(memory, [:growth, :growth_rate]) || 0
    quality = get_in(memory, [:quality, :avg_importance]) || 0

    # Normalize components
    # 5000 memories = 1.0
    size_score = min(1.0, total / 5000)
    # 20% growth = 1.0
    growth_score = min(1.0, growth_rate / 20)
    # Already 0-1
    quality_score = quality

    size_score * 0.3 + growth_score * 0.3 + quality_score * 0.4
  end

  defp compute_learning_score(learning) do
    health = get_in(learning, [:overall_effectiveness])

    case health do
      :excellent -> 1.0
      :healthy -> 0.75
      :needs_attention -> 0.5
      :struggling -> 0.25
      _ -> 0.0
    end
  end

  defp compute_emergence_score(emergence) do
    patterns = get_in(emergence, [:patterns, :total]) || 0
    promoted = get_in(emergence, [:promotion, :total_promoted]) || 0
    promotion_rate = get_in(emergence, [:promotion, :promotion_rate]) || 0

    # 100 patterns = 1.0
    pattern_score = min(1.0, patterns / 100)
    # 10 promoted = 1.0
    promoted_score = min(1.0, promoted / 10)
    # 10% rate = 1.0
    rate_score = min(1.0, promotion_rate * 10)

    pattern_score * 0.3 + promoted_score * 0.4 + rate_score * 0.3
  end

  defp compute_health_score(health) do
    status = Map.get(health, :status)
    calibration = Map.get(health, :calibration_status)
    alerts = length(Map.get(health, :quality_alerts, []))

    status_score =
      case status do
        :healthy -> 1.0
        :degraded -> 0.6
        :unhealthy -> 0.3
        _ -> 0.5
      end

    calibration_score =
      case calibration do
        :healthy -> 1.0
        :minor_issues -> 0.7
        :needs_attention -> 0.4
        _ -> 0.5
      end

    alert_penalty = min(0.3, alerts * 0.1)

    max(0, status_score * 0.5 + calibration_score * 0.5 - alert_penalty)
  end

  defp score_to_level(score) do
    cond do
      score >= 0.9 -> :transcendent
      score >= 0.75 -> :evolved
      score >= 0.6 -> :learning
      score >= 0.4 -> :developing
      score >= 0.2 -> :nascent
      true -> :initializing
    end
  end

  defp interpret_score(score, level) do
    base =
      case level do
        :transcendent -> "Mimo has achieved exceptional cognitive capabilities."
        :evolved -> "Mimo demonstrates strong learning and emergence patterns."
        :learning -> "Mimo is actively learning and improving."
        :developing -> "Mimo is developing cognitive capabilities."
        :nascent -> "Mimo is in early stages of cognitive development."
        :initializing -> "Mimo is initializing cognitive systems."
      end

    percentage = round(score * 100)
    "#{base} Overall cognitive score: #{percentage}%"
  end
end
