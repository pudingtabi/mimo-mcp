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

  alias Mimo.Brain.Emergence.{Catalog, Pattern}
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
  # Phase 4.2: Prediction Layer (SPEC-044 v1.4)
  # ─────────────────────────────────────────────────────────────────

  @doc """
  Predicts which patterns are likely to emerge as capabilities.

  Analyzes active patterns using velocity, strength trajectory, and
  historical promotion data to predict emergence likelihood.

  Returns predictions with:
  - ETA (estimated time to promotion)
  - Confidence score (0.0-1.0)
  - Factors contributing to the prediction

  ## Options
    - `:limit` - Maximum predictions to return (default: 10)
    - `:min_confidence` - Minimum confidence threshold (default: 0.3)

  ## Example

      iex> Metrics.predict_emergence(limit: 5)
      %{
        predictions: [
          %{
            pattern_id: "abc123",
            description: "workflow pattern: read → edit → test",
            eta_days: 7.5,
            confidence: 0.82,
            factors: %{velocity: :accelerating, ...}
          }
        ],
        model_accuracy: 0.75,
        timestamp: ~U[...]
      }
  """
  @spec predict_emergence(keyword()) :: map()
  def predict_emergence(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    min_confidence = Keyword.get(opts, :min_confidence, 0.3)

    # Get active patterns with enough data for prediction
    active_patterns = Pattern.list(status: :active, limit: 100)

    # Calculate prediction for each pattern
    predictions =
      active_patterns
      |> Enum.map(&calculate_pattern_prediction/1)
      |> Enum.filter(&(&1.confidence >= min_confidence))
      |> Enum.sort_by(& &1.confidence, :desc)
      |> Enum.take(limit)

    # Calculate historical model accuracy
    model_accuracy = calculate_model_accuracy()

    %{
      predictions: predictions,
      model_accuracy: model_accuracy,
      total_active_patterns: length(active_patterns),
      prediction_count: length(predictions),
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Calculates the estimated time (in days) for a pattern to be promoted.

  Uses velocity, current strength, and promotion thresholds to estimate
  when a pattern will reach promotion criteria.

  ## Example

      iex> Metrics.calculate_eta(pattern)
      {:ok, %{days: 12.5, confidence: 0.7, limiting_factor: :occurrences}}
  """
  @spec calculate_eta(Pattern.t()) :: {:ok, map()} | {:error, term()}
  def calculate_eta(pattern) do
    # Promotion thresholds (from Pattern.promotion_candidates/1)
    min_occurrences = 10
    min_success_rate = 0.8
    min_strength = 0.75

    # Calculate gaps to promotion thresholds
    occurrence_gap = max(0, min_occurrences - pattern.occurrences)
    success_gap = max(0.0, min_success_rate - pattern.success_rate)
    strength_gap = max(0.0, min_strength - pattern.strength)

    # Calculate velocity (patterns per day)
    velocity = calculate_pattern_velocity_rate(pattern)

    # Estimate days to close each gap
    eta_occurrence = if velocity > 0, do: occurrence_gap / velocity, else: :infinity
    eta_strength = estimate_strength_eta(pattern, strength_gap)
    eta_success = estimate_success_eta(pattern, success_gap)

    # The limiting factor determines overall ETA
    etas = [
      {:occurrences, eta_occurrence},
      {:strength, eta_strength},
      {:success_rate, eta_success}
    ]

    # Find the maximum (slowest) ETA
    {limiting_factor, max_eta} =
      etas
      |> Enum.reject(fn {_, v} -> v == :infinity end)
      |> case do
        [] -> {:unknown, :infinity}
        valid -> Enum.max_by(valid, fn {_, v} -> v end)
      end

    # Calculate confidence based on data quality
    confidence = calculate_eta_confidence(pattern, velocity)

    case max_eta do
      :infinity ->
        {:ok,
         %{
           days: nil,
           confidence: 0.1,
           limiting_factor: limiting_factor,
           reason: "insufficient velocity data"
         }}

      days when is_number(days) ->
        {:ok,
         %{days: Float.round(days, 1), confidence: confidence, limiting_factor: limiting_factor}}
    end
  end

  @doc """
  Calculates a confidence score for a prediction.

  Confidence factors:
  - Data quality (evolution history length)
  - Velocity consistency (stable vs erratic)
  - Pattern age (older = more reliable trajectory)
  - Similar pattern historical accuracy

  Returns a float between 0.0 and 1.0.
  """
  @spec calculate_prediction_confidence(Pattern.t()) :: float()
  def calculate_prediction_confidence(pattern) do
    factors = [
      # Data quality: more evolution history = higher confidence
      data_quality_score(pattern),
      # Velocity consistency: stable trajectory = higher confidence
      velocity_consistency_score(pattern),
      # Pattern maturity: older patterns have more reliable trajectories
      pattern_maturity_score(pattern),
      # Success rate reliability: high success with many occurrences
      success_reliability_score(pattern)
    ]

    # Weighted average
    weights = [0.3, 0.25, 0.25, 0.2]

    Enum.zip(factors, weights)
    |> Enum.map(fn {score, weight} -> score * weight end)
    |> Enum.sum()
    |> Float.round(3)
  end

  @doc """
  Gets prediction accuracy based on historical predictions.

  Compares past predictions to actual promotion outcomes to
  provide a calibrated accuracy score.
  """
  @spec prediction_accuracy() :: map()
  def prediction_accuracy do
    # Get patterns that were promoted in the last 30 days
    recently_promoted =
      Pattern.list(status: :promoted, limit: 50)
      |> Enum.filter(fn p ->
        DateTime.diff(DateTime.utc_now(), p.updated_at, :day) <= 30
      end)

    # For now, return basic stats (will be enhanced with actual tracking)
    %{
      recently_promoted: length(recently_promoted),
      # These would come from a prediction history table in production
      predictions_made: 0,
      predictions_correct: 0,
      accuracy: calculate_model_accuracy(),
      calibration: :not_yet_calibrated
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
    # Patterns detected per active day (uses 30-day window).
    total = Pattern.count_all()
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
    # Aggregates pattern strength from evolution data.
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

  # ─────────────────────────────────────────────────────────────────
  # Prediction Layer Helpers (Phase 4.2)
  # ─────────────────────────────────────────────────────────────────

  # Calculates full prediction for a single pattern
  defp calculate_pattern_prediction(pattern) do
    # Get ETA calculation
    {:ok, eta_result} = calculate_eta(pattern)

    # Calculate confidence
    confidence = calculate_prediction_confidence(pattern)

    # Determine trajectory
    trajectory = calculate_pattern_trend(pattern)

    # Calculate factors contributing to prediction
    factors = %{
      velocity: pattern_velocity_trend(pattern),
      strength_trend: trajectory,
      occurrences: pattern.occurrences,
      success_rate: pattern.success_rate,
      data_points: length(pattern.evolution)
    }

    %{
      pattern_id: pattern.id,
      type: pattern.type,
      description: String.slice(pattern.description || "", 0, 80),
      current_strength: pattern.strength,
      eta_days: eta_result.days,
      limiting_factor: eta_result.limiting_factor,
      confidence: confidence,
      trajectory: trajectory,
      factors: factors,
      promotion_ready: promotion_ready?(pattern)
    }
  end

  # Calculate velocity rate (occurrences per day) for a pattern
  defp calculate_pattern_velocity_rate(pattern) do
    case pattern.evolution do
      [] ->
        0.0

      [_single] ->
        # Single data point, estimate based on age
        days_old = max(1, DateTime.diff(DateTime.utc_now(), pattern.first_seen, :day))
        pattern.occurrences / days_old

      entries when length(entries) >= 2 ->
        # Calculate from evolution history
        first_entry = List.first(entries)
        last_entry = List.last(entries)

        first_time = parse_timestamp(first_entry["timestamp"] || first_entry[:timestamp])
        last_time = parse_timestamp(last_entry["timestamp"] || last_entry[:timestamp])

        case {first_time, last_time} do
          {{:ok, t1}, {:ok, t2}} ->
            days = max(1, DateTime.diff(t2, t1, :day))
            first_occ = first_entry["occurrences"] || first_entry[:occurrences] || 1
            last_occ = last_entry["occurrences"] || last_entry[:occurrences] || pattern.occurrences
            (last_occ - first_occ) / days

          _ ->
            days_old = max(1, DateTime.diff(DateTime.utc_now(), pattern.first_seen, :day))
            pattern.occurrences / days_old
        end
    end
  end

  defp parse_timestamp(nil), do: {:error, nil}

  defp parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> {:error, :invalid}
    end
  end

  defp parse_timestamp(%DateTime{} = dt), do: {:ok, dt}
  defp parse_timestamp(_), do: {:error, :unknown}

  # Estimate days to reach strength threshold
  defp estimate_strength_eta(pattern, strength_gap) do
    if strength_gap <= 0 do
      0.0
    else
      # Estimate strength growth rate from evolution
      case pattern.evolution do
        entries when length(entries) >= 2 ->
          recent = Enum.take(entries, -5)
          strengths = Enum.map(recent, &(&1["strength"] || &1[:strength] || 0))

          if length(strengths) >= 2 do
            first_s = List.first(strengths)
            last_s = List.last(strengths)
            growth = (last_s - first_s) / length(recent)

            if growth > 0, do: strength_gap / growth, else: :infinity
          else
            :infinity
          end

        _ ->
          :infinity
      end
    end
  end

  # Estimate days to reach success rate threshold
  defp estimate_success_eta(_pattern, success_gap) do
    if success_gap <= 0 do
      0.0
    else
      # Success rate typically improves slowly - estimate 0.02 per day
      success_gap / 0.02
    end
  end

  # Calculate confidence in ETA estimate based on data quality
  defp calculate_eta_confidence(pattern, velocity) do
    base_confidence = 0.3

    # Boost for more evolution data points
    data_boost = min(0.3, length(pattern.evolution) * 0.03)

    # Boost for positive velocity
    velocity_boost = if velocity > 0, do: 0.2, else: 0.0

    # Boost for pattern age (more history = more reliable)
    age_days = DateTime.diff(DateTime.utc_now(), pattern.first_seen, :day)
    age_boost = min(0.2, age_days * 0.01)

    Float.round(min(0.95, base_confidence + data_boost + velocity_boost + age_boost), 3)
  end

  # Calculate velocity trend for a pattern
  defp pattern_velocity_trend(pattern) do
    case pattern.evolution do
      entries when length(entries) >= 4 ->
        occurrences = Enum.map(entries, &(&1["occurrences"] || &1[:occurrences] || 0))
        mid = div(length(occurrences), 2)
        {first_half, second_half} = Enum.split(occurrences, mid)

        first_growth = growth_rate(first_half)
        second_growth = growth_rate(second_half)

        cond do
          second_growth > first_growth * 1.2 -> :accelerating
          second_growth < first_growth * 0.8 -> :decelerating
          true -> :stable
        end

      _ ->
        :insufficient_data
    end
  end

  defp growth_rate([]), do: 0.0
  defp growth_rate([_]), do: 0.0

  defp growth_rate(values) do
    first = List.first(values)
    last = List.last(values)
    (last - first) / max(1, length(values) - 1)
  end

  # Data quality score based on evolution history
  defp data_quality_score(pattern) do
    history_length = length(pattern.evolution)
    min(1.0, history_length / 10.0)
  end

  # Velocity consistency - stable is better
  defp velocity_consistency_score(pattern) do
    case pattern.evolution do
      entries when length(entries) >= 3 ->
        occurrences = Enum.map(entries, &(&1["occurrences"] || &1[:occurrences] || 0))

        deltas =
          Enum.chunk_every(occurrences, 2, 1, :discard)
          |> Enum.map(fn [a, b] -> b - a end)

        if Enum.empty?(deltas) do
          0.5
        else
          avg = Enum.sum(deltas) / length(deltas)
          variance = Enum.sum(Enum.map(deltas, fn d -> :math.pow(d - avg, 2) end)) / length(deltas)
          std_dev = :math.sqrt(variance)

          # Lower variance = higher score
          max(0.1, min(1.0, 1.0 - std_dev / max(1.0, avg)))
        end

      _ ->
        0.5
    end
  end

  # Pattern maturity score based on age
  defp pattern_maturity_score(pattern) do
    age_days = DateTime.diff(DateTime.utc_now(), pattern.first_seen, :day)
    min(1.0, age_days / 30.0)
  end

  # Success rate reliability - high success with many occurrences
  defp success_reliability_score(pattern) do
    occurrence_factor = min(1.0, pattern.occurrences / 20.0)
    pattern.success_rate * occurrence_factor
  end

  # Check if pattern already meets promotion criteria
  defp promotion_ready?(pattern) do
    pattern.occurrences >= 10 and
      pattern.success_rate >= 0.8 and
      pattern.strength >= 0.75
  end

  # Calculate model accuracy from historical prediction data
  defp calculate_model_accuracy do
    alias Mimo.Brain.Emergence.Prediction

    stats = Prediction.accuracy_stats(days: 90)

    case stats.avg_accuracy do
      # Default baseline when no data
      nil -> 0.70
      accuracy when is_float(accuracy) -> Float.round(accuracy, 3)
      _ -> 0.70
    end
  end
end
