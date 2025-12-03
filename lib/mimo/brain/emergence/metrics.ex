defmodule Mimo.Brain.Emergence.Metrics do
  @moduledoc """
  SPEC-044: Metrics and monitoring for the emergence framework.

  Provides comprehensive metrics for:

  - **Quantity**: Patterns detected, promoted, capabilities emerged
  - **Quality**: Success rates, pattern strength
  - **Velocity**: New patterns, promotions over time
  - **Coverage**: Domains covered, tool combinations
  - **Evolution**: Patterns strengthening or weakening

  ## Usage

  ```elixir
  # Get full dashboard
  Metrics.dashboard()

  # Get specific metrics
  Metrics.pattern_velocity(days: 7)
  Metrics.coverage_metrics()
  ```
  """

  require Logger

  alias Mimo.Brain.Emergence.{Pattern, Catalog}
  alias Mimo.Repo
  import Ecto.Query

  # ─────────────────────────────────────────────────────────────────
  # Public API
  # ─────────────────────────────────────────────────────────────────

  @doc """
  Returns comprehensive emergence dashboard.
  """
  @spec dashboard() :: map()
  def dashboard do
    %{
      timestamp: DateTime.utc_now(),

      # Quantity metrics
      quantity: %{
        patterns_detected: Pattern.count_all(),
        patterns_promoted: Pattern.count_promoted(),
        capabilities_emerged: Catalog.count()
      },

      # Quality metrics
      quality: %{
        average_success_rate: Pattern.avg_success_rate(),
        strongest_pattern: get_strongest_pattern(),
        quality_distribution: get_quality_distribution()
      },

      # Velocity metrics
      velocity: %{
        new_patterns_weekly: Pattern.count_recent(days: 7),
        promotions_monthly: Pattern.promotions_recent(days: 30),
        detection_rate: calculate_detection_rate()
      },

      # Coverage metrics
      coverage: %{
        domains_covered: Pattern.unique_domains() |> length(),
        tool_combinations: Pattern.unique_tool_combos() |> length(),
        type_distribution: get_type_distribution()
      },

      # Evolution metrics
      evolution: %{
        patterns_strengthening: Pattern.improving() |> length(),
        patterns_weakening: Pattern.declining() |> length(),
        maturity_index: calculate_maturity_index()
      }
    }
  end

  @doc """
  Gets pattern detection velocity over time.
  """
  @spec pattern_velocity(keyword()) :: map()
  def pattern_velocity(opts \\ []) do
    days = Keyword.get(opts, :days, 30)

    # Get daily pattern counts
    daily_counts = get_daily_pattern_counts(days)

    %{
      period_days: days,
      total_new: Enum.sum(Map.values(daily_counts)),
      daily_average: calculate_daily_average(daily_counts),
      trend: calculate_velocity_trend(daily_counts),
      daily_breakdown: daily_counts
    }
  end

  @doc """
  Gets coverage metrics across domains and tools.
  """
  @spec coverage_metrics() :: map()
  def coverage_metrics do
    domains = Pattern.unique_domains()
    tool_combos = Pattern.unique_tool_combos()

    %{
      domains: %{
        covered: domains,
        count: length(domains)
      },
      tool_combinations: %{
        unique: tool_combos,
        count: length(tool_combos)
      },
      type_coverage: get_type_distribution(),
      depth_analysis: analyze_pattern_depth()
    }
  end

  @doc """
  Gets quality metrics for patterns.
  """
  @spec quality_metrics() :: map()
  def quality_metrics do
    patterns = Pattern.list(status: :active, limit: 100)

    %{
      success_rate: %{
        average: Pattern.avg_success_rate(),
        distribution: calculate_success_distribution(patterns)
      },
      strength: %{
        average: calculate_average_strength(patterns),
        distribution: calculate_strength_distribution(patterns)
      },
      reliability: %{
        high_reliability: count_by_threshold(patterns, :success_rate, 0.8),
        medium_reliability: count_by_threshold(patterns, :success_rate, 0.5, 0.8),
        low_reliability: count_by_threshold(patterns, :success_rate, 0.0, 0.5)
      }
    }
  end

  @doc """
  Gets evolution metrics showing how patterns change.
  """
  @spec evolution_metrics(keyword()) :: map()
  def evolution_metrics(opts \\ []) do
    days = Keyword.get(opts, :days, 30)

    improving = Pattern.improving(limit: 20)
    declining = Pattern.declining(limit: 20)

    %{
      period_days: days,
      improving: %{
        count: length(improving),
        patterns: Enum.map(improving, &summarize_pattern/1)
      },
      declining: %{
        count: length(declining),
        patterns: Enum.map(declining, &summarize_pattern/1)
      },
      stability: calculate_stability_index(days),
      maturity: calculate_maturity_index()
    }
  end

  @doc """
  Gets promotion funnel metrics.
  """
  @spec promotion_funnel() :: map()
  def promotion_funnel do
    active = Pattern.list(status: :active)
    candidates = Pattern.promotion_candidates()
    promoted = Pattern.list(status: :promoted)

    %{
      stages: %{
        detected: Pattern.count_all(),
        active: length(active),
        candidates: length(candidates),
        promoted: length(promoted)
      },
      conversion_rates: %{
        detection_to_active: calculate_rate(Pattern.count_all(), length(active)),
        active_to_candidate: calculate_rate(length(active), length(candidates)),
        candidate_to_promoted: calculate_rate(length(candidates), length(promoted))
      },
      bottlenecks: identify_bottlenecks(active, candidates)
    }
  end

  @doc """
  Gets time series data for emergence metrics.
  """
  @spec time_series(keyword()) :: [map()]
  def time_series(opts \\ []) do
    days = Keyword.get(opts, :days, 30)
    metric = Keyword.get(opts, :metric, :patterns)

    case metric do
      :patterns -> get_pattern_time_series(days)
      :promotions -> get_promotion_time_series(days)
      :strength -> get_strength_time_series(days)
      _ -> []
    end
  end

  @doc """
  Exports metrics in a format suitable for external monitoring.
  """
  @spec export_metrics() :: map()
  def export_metrics do
    dashboard = dashboard()

    %{
      # Prometheus-style metrics
      emergence_patterns_total: dashboard.quantity.patterns_detected,
      emergence_patterns_promoted_total: dashboard.quantity.patterns_promoted,
      emergence_capabilities_total: dashboard.quantity.capabilities_emerged,
      emergence_success_rate: dashboard.quality.average_success_rate,
      emergence_new_patterns_weekly: dashboard.velocity.new_patterns_weekly,
      emergence_domains_covered: dashboard.coverage.domains_covered,
      emergence_patterns_improving: dashboard.evolution.patterns_strengthening,
      emergence_patterns_declining: dashboard.evolution.patterns_weakening,
      emergence_maturity_index: dashboard.evolution.maturity_index
    }
  end

  # ─────────────────────────────────────────────────────────────────
  # Private Helpers
  # ─────────────────────────────────────────────────────────────────

  defp get_strongest_pattern do
    strongest = Pattern.strongest_by_type()

    strongest
    |> Enum.map(fn {type, pattern} ->
      if pattern do
        {type,
         %{
           id: pattern.id,
           description: String.slice(pattern.description, 0, 50),
           strength: pattern.strength
         }}
      else
        {type, nil}
      end
    end)
    |> Map.new()
  end

  defp get_quality_distribution do
    patterns = Pattern.list(status: :active, limit: 200)

    %{
      excellent: Enum.count(patterns, &(&1.success_rate >= 0.9)),
      good: Enum.count(patterns, &(&1.success_rate >= 0.7 and &1.success_rate < 0.9)),
      fair: Enum.count(patterns, &(&1.success_rate >= 0.5 and &1.success_rate < 0.7)),
      poor: Enum.count(patterns, &(&1.success_rate < 0.5))
    }
  end

  defp get_type_distribution do
    Pattern.count_by_status()
  end

  defp calculate_detection_rate do
    # Patterns detected per active day
    total = Pattern.count_all()
    # Would need to track active days
    Float.round(total / max(1, 30), 2)
  end

  defp calculate_maturity_index do
    # Ratio of promoted to total patterns
    total = max(1, Pattern.count_all())
    promoted = Pattern.count_promoted()

    Float.round(promoted / total, 3)
  end

  defp get_daily_pattern_counts(days) do
    since = DateTime.utc_now() |> DateTime.add(-days * 24 * 60 * 60, :second)

    from(p in Pattern,
      where: p.first_seen >= ^since,
      select: fragment("date(?)", p.first_seen)
    )
    |> Repo.all()
    |> Enum.frequencies()
  rescue
    # SQLite might not support date() function the same way
    _ -> %{}
  end

  defp calculate_daily_average(daily_counts) when map_size(daily_counts) == 0, do: 0.0

  defp calculate_daily_average(daily_counts) do
    total = Enum.sum(Map.values(daily_counts))
    Float.round(total / map_size(daily_counts), 2)
  end

  defp calculate_velocity_trend(daily_counts) when map_size(daily_counts) < 7,
    do: :insufficient_data

  defp calculate_velocity_trend(daily_counts) do
    values = Map.values(daily_counts) |> Enum.sort()
    mid = div(length(values), 2)
    {first_half, second_half} = Enum.split(values, mid)

    first_avg = if first_half == [], do: 0, else: Enum.sum(first_half) / length(first_half)
    second_avg = if second_half == [], do: 0, else: Enum.sum(second_half) / length(second_half)

    cond do
      second_avg > first_avg * 1.2 -> :accelerating
      second_avg < first_avg * 0.8 -> :decelerating
      true -> :stable
    end
  end

  defp analyze_pattern_depth do
    patterns = Pattern.list(status: :active, limit: 100)

    component_counts = Enum.map(patterns, fn p -> length(p.components) end)

    if component_counts == [] do
      %{average: 0, max: 0, min: 0}
    else
      %{
        average: Float.round(Enum.sum(component_counts) / length(component_counts), 2),
        max: Enum.max(component_counts),
        min: Enum.min(component_counts)
      }
    end
  end

  defp calculate_success_distribution(patterns) do
    %{
      "0.9-1.0" => Enum.count(patterns, &(&1.success_rate >= 0.9)),
      "0.7-0.9" => Enum.count(patterns, &(&1.success_rate >= 0.7 and &1.success_rate < 0.9)),
      "0.5-0.7" => Enum.count(patterns, &(&1.success_rate >= 0.5 and &1.success_rate < 0.7)),
      "0.0-0.5" => Enum.count(patterns, &(&1.success_rate < 0.5))
    }
  end

  defp calculate_average_strength(patterns) when patterns == [], do: 0.0

  defp calculate_average_strength(patterns) do
    total = Enum.sum(Enum.map(patterns, & &1.strength))
    Float.round(total / length(patterns), 3)
  end

  defp calculate_strength_distribution(patterns) do
    %{
      strong: Enum.count(patterns, &(&1.strength >= 0.7)),
      medium: Enum.count(patterns, &(&1.strength >= 0.4 and &1.strength < 0.7)),
      weak: Enum.count(patterns, &(&1.strength < 0.4))
    }
  end

  defp count_by_threshold(patterns, field, min, max \\ 1.0) do
    Enum.count(patterns, fn p ->
      value = Map.get(p, field, 0)
      value >= min and value < max
    end)
  end

  defp summarize_pattern(pattern) do
    %{
      id: pattern.id,
      type: pattern.type,
      description: String.slice(pattern.description, 0, 40),
      strength: pattern.strength,
      trend: calculate_pattern_trend(pattern)
    }
  end

  defp calculate_pattern_trend(pattern) do
    case pattern.evolution do
      [] ->
        :new

      [_] ->
        :new

      entries ->
        recent = Enum.take(entries, -2)
        [prev, curr] = Enum.map(recent, &(&1[:strength] || &1["strength"] || 0))

        cond do
          curr > prev -> :rising
          curr < prev -> :falling
          true -> :stable
        end
    end
  end

  defp calculate_stability_index(_days) do
    # Ratio of stable patterns to total
    all_patterns = Pattern.list(status: :active)
    improving = Pattern.improving() |> length()
    declining = Pattern.declining() |> length()
    changing = improving + declining

    if Enum.empty?(all_patterns) do
      1.0
    else
      stable = length(all_patterns) - changing
      Float.round(stable / length(all_patterns), 3)
    end
  end

  defp calculate_rate(total, _subset) when total == 0, do: 0.0

  defp calculate_rate(total, subset) do
    Float.round(subset / total * 100, 1)
  end

  defp identify_bottlenecks(active, candidates) do
    bottlenecks = []

    bottlenecks =
      if Enum.any?(active) and Enum.empty?(candidates) do
        bottlenecks ++ ["No patterns meeting promotion thresholds"]
      else
        bottlenecks
      end

    # Check for patterns stuck with low occurrences
    low_occurrence = Enum.count(active, &(&1.occurrences < 5))

    if low_occurrence > length(active) * 0.5 do
      bottlenecks ++ ["Many patterns with low occurrence count"]
    else
      bottlenecks
    end
  end

  defp get_pattern_time_series(days) do
    since = DateTime.utc_now() |> DateTime.add(-days * 24 * 60 * 60, :second)

    from(p in Pattern,
      where: p.first_seen >= ^since,
      order_by: [asc: p.first_seen]
    )
    |> Repo.all()
    |> Enum.map(fn p ->
      %{
        timestamp: p.first_seen,
        type: p.type,
        strength: p.strength
      }
    end)
  end

  defp get_promotion_time_series(days) do
    since = DateTime.utc_now() |> DateTime.add(-days * 24 * 60 * 60, :second)

    from(p in Pattern,
      where: p.status == :promoted and p.updated_at >= ^since,
      order_by: [asc: p.updated_at]
    )
    |> Repo.all()
    |> Enum.map(fn p ->
      %{
        timestamp: p.updated_at,
        type: p.type,
        strength: p.strength
      }
    end)
  end

  defp get_strength_time_series(days) do
    # Would need to aggregate from evolution data
    since = DateTime.utc_now() |> DateTime.add(-days * 24 * 60 * 60, :second)

    Pattern.list(status: :active, limit: 50)
    |> Enum.flat_map(fn pattern ->
      pattern.evolution
      |> Enum.filter(fn entry ->
        case DateTime.from_iso8601(entry["timestamp"] || entry[:timestamp] || "") do
          {:ok, dt, _} -> DateTime.compare(dt, since) == :gt
          _ -> false
        end
      end)
      |> Enum.map(fn entry ->
        %{
          timestamp: entry["timestamp"] || entry[:timestamp],
          pattern_id: pattern.id,
          strength: entry["strength"] || entry[:strength]
        }
      end)
    end)
  end
end
