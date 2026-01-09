defmodule Mimo.Cognitive.MetaLearner do
  @moduledoc """
  SPEC-074 L6: Meta-Learning - Learning how to learn better.

  This module provides meta-cognitive capabilities that analyze the effectiveness
  of Mimo's various learning strategies and provide recommendations for improvement.

  ## Philosophy

  While L1-L5 implement specific learning mechanisms, L6 takes a step back and asks:
  - Which learning strategies are actually working?
  - Which parameters could be adjusted for better results?
  - What patterns are emerging in how patterns emerge?

  This is "learning about learning" - the meta-cognitive layer that enables
  continuous self-improvement.

  ## Key Functions

  - `analyze_strategy_effectiveness/0` - Compare all learning strategies
  - `recommend_parameter_adjustments/0` - Suggest parameter changes based on data
  - `detect_meta_patterns/0` - Find patterns in pattern emergence itself
  - `meta_insights/0` - Synthesize high-level learning insights

  ## Integration Points

  - FeedbackLoop: learning_effectiveness(), get_calibration()
  - HebbianLearner: stats()
  - ErrorPredictor: stats()
  - Emergence: Pattern detection statistics

  ## Safety

  This module RECOMMENDS but does not automatically adjust parameters.
  Auto-adjustment can be dangerous (runaway feedback loops).
  Human review of recommendations is encouraged.
  """

  require Logger

  alias Mimo.Brain.{ErrorPredictor, HebbianLearner}
  alias Mimo.Brain.Emergence.{Detector, Pattern, Promoter}
  alias Mimo.Cognitive.FeedbackLoop

  # Weight thresholds for strategy effectiveness
  @excellent_threshold 0.8
  @good_threshold 0.6
  @warning_threshold 0.4

  # ─────────────────────────────────────────────────────────────────
  # Public API
  # ─────────────────────────────────────────────────────────────────

  @doc """
  Analyzes the effectiveness of all learning strategies.

  Returns a comprehensive report comparing:
  - FeedbackLoop-based learning (L1-L2)
  - Hebbian learning (L3)
  - Error prediction learning (L3)
  - Tool selection from patterns (L4)
  - Confidence calibration (L5)

  ## Returns
    Map with strategy effectiveness scores and rankings

  ## Example
      MetaLearner.analyze_strategy_effectiveness()
      # => %{
      #   strategies: %{
      #     feedback_loop: %{effectiveness: 0.78, status: :good, trend: :improving},
      #     hebbian: %{effectiveness: 0.65, status: :good, trend: :stable},
      #     ...
      #   },
      #   rankings: [:feedback_loop, :calibration, :hebbian, ...],
      #   overall_learning_health: :healthy,
      #   timestamp: ~U[...]
      # }
  """
  @spec analyze_strategy_effectiveness() :: map()
  def analyze_strategy_effectiveness do
    # Gather data from all learning subsystems
    feedback_data = safe_call(fn -> FeedbackLoop.learning_effectiveness() end, %{})
    calibration_data = gather_calibration_data()
    hebbian_data = safe_call(fn -> HebbianLearner.stats() end, %{})
    error_data = safe_call(fn -> ErrorPredictor.stats() end, %{})
    emergence_data = gather_emergence_data()

    # Compute effectiveness scores for each strategy
    strategies = %{
      feedback_loop: compute_feedback_loop_effectiveness(feedback_data),
      hebbian_learning: compute_hebbian_effectiveness(hebbian_data),
      error_prediction: compute_error_prediction_effectiveness(error_data),
      emergence_patterns: compute_emergence_effectiveness(emergence_data),
      confidence_calibration: compute_calibration_effectiveness(calibration_data)
    }

    # Rank strategies by effectiveness
    rankings =
      strategies
      |> Enum.sort_by(fn {_k, v} -> Map.get(v, :effectiveness, 0) end, :desc)
      |> Enum.map(fn {k, _v} -> k end)

    # Compute overall health
    avg_effectiveness =
      strategies
      |> Enum.map(fn {_k, v} -> Map.get(v, :effectiveness, 0) end)
      |> average()

    overall_health = effectiveness_to_health(avg_effectiveness)

    %{
      strategies: strategies,
      rankings: rankings,
      average_effectiveness: Float.round(avg_effectiveness, 3),
      overall_learning_health: overall_health,
      data_sources: %{
        feedback_loop: feedback_data != %{},
        hebbian: hebbian_data != %{},
        error_predictor: error_data != %{},
        emergence: emergence_data.pattern_stats != %{} or emergence_data.promoter_stats != %{}
      },
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Recommends parameter adjustments based on learning effectiveness.

  Analyzes current performance and suggests changes to tunable parameters.
  Does NOT automatically apply changes - returns recommendations only.

  ## Returns
    List of parameter adjustment recommendations

  ## Example
      MetaLearner.recommend_parameter_adjustments()
      # => [
      #   %{
      #     parameter: :feedback_boost_weight,
      #     module: MetaCognitiveRouter,
      #     current: 0.2,
      #     recommended: 0.3,
      #     reason: "Feedback-based learning showing strong results (+15% accuracy)",
      #     confidence: :high
      #   },
      #   ...
      # ]
  """
  @spec recommend_parameter_adjustments() :: [map()]
  def recommend_parameter_adjustments do
    analysis = analyze_strategy_effectiveness()
    recommendations = []

    # Feedback boost weight recommendation
    recommendations =
      case get_in(analysis, [:strategies, :feedback_loop]) do
        %{effectiveness: eff, trend: _trend} when eff > @excellent_threshold ->
          # Very effective - suggest increasing weight
          [
            %{
              parameter: :feedback_boost_weight,
              module: Mimo.MetaCognitiveRouter,
              current: "@feedback_boost_weight (0.2)",
              recommended: "0.3 (increase)",
              reason:
                "Feedback learning is highly effective (#{round(eff * 100)}%). Consider increasing weight.",
              confidence: :high,
              priority: :medium
            }
            | recommendations
          ]

        %{effectiveness: eff, trend: :declining} when eff < @warning_threshold ->
          # Not effective and declining - suggest decreasing or investigating
          [
            %{
              parameter: :feedback_boost_weight,
              module: Mimo.MetaCognitiveRouter,
              current: "@feedback_boost_weight (0.2)",
              recommended: "0.1 (decrease) or investigate",
              reason: "Feedback learning is underperforming (#{round(eff * 100)}%) and declining.",
              confidence: :medium,
              priority: :high
            }
            | recommendations
          ]

        _ ->
          recommendations
      end

    # Hebbian learning rate recommendation
    recommendations =
      case get_in(analysis, [:strategies, :hebbian_learning]) do
        %{effectiveness: eff} when eff > @excellent_threshold ->
          [
            %{
              parameter: :ltp_increment,
              module: Mimo.Brain.HebbianLearner,
              current: "@ltp_increment (0.05)",
              recommended: "0.07 (increase)",
              reason:
                "Hebbian learning is working well (#{round(eff * 100)}%). Faster strengthening could help.",
              confidence: :medium,
              priority: :low
            }
            | recommendations
          ]

        %{effectiveness: eff} when eff < @warning_threshold ->
          [
            %{
              parameter: :ltp_increment,
              module: Mimo.Brain.HebbianLearner,
              current: "@ltp_increment (0.05)",
              recommended: "0.03 (decrease)",
              reason:
                "Hebbian learning is weak (#{round(eff * 100)}%). Slower learning may help quality.",
              confidence: :low,
              priority: :low
            }
            | recommendations
          ]

        _ ->
          recommendations
      end

    # Calibration-based recommendations
    recommendations =
      case get_in(analysis, [:strategies, :confidence_calibration]) do
        %{reliability: :unreliable, details: details} ->
          [
            %{
              parameter: :min_calibration_samples,
              module: Mimo.Cognitive.FeedbackLoop,
              current: "@min_calibration_samples (20)",
              recommended: "10 (decrease)",
              reason: "Calibration marked unreliable. #{inspect(details)}",
              confidence: :low,
              priority: :low
            }
            | recommendations
          ]

        %{effectiveness: eff} when eff < @warning_threshold ->
          [
            %{
              parameter: :calibration_bucket_count,
              module: Mimo.Cognitive.FeedbackLoop,
              current: "@calibration_bucket_count (10)",
              recommended: "5 (decrease for more samples per bucket)",
              reason:
                "Calibration effectiveness low (#{round(eff * 100)}%). Fewer buckets may help.",
              confidence: :low,
              priority: :low
            }
            | recommendations
          ]

        _ ->
          recommendations
      end

    # Sort by priority
    recommendations
    |> Enum.sort_by(fn r ->
      case r.priority do
        :high -> 0
        :medium -> 1
        :low -> 2
        _ -> 3
      end
    end)
  end

  @doc """
  Detects meta-patterns: patterns in how patterns emerge.

  This analyzes the emergence system's output to find higher-order patterns:
  - Which types of patterns emerge most frequently?
  - When do patterns get promoted vs ignored?
  - What contexts produce the most useful patterns?

  ## Returns
    Map with meta-pattern analysis

  ## Example
      MetaLearner.detect_meta_patterns()
      # => %{
      #   pattern_type_distribution: %{workflow: 45, tool_sequence: 30, preference: 25},
      #   promotion_rate: 0.12,
      #   high_value_contexts: ["test-driven workflow", "debugging sessions"],
      #   meta_insights: [...]
      # }
  """
  @spec detect_meta_patterns() :: map()
  def detect_meta_patterns do
    # Get pattern statistics from emergence system
    pattern_stats = safe_call(fn -> Pattern.stats() end, %{})
    promoter_stats = safe_call(fn -> Promoter.stats() end, %{})
    detector_modes = get_detector_modes()

    # Analyze pattern type distribution
    type_distribution = analyze_pattern_types(pattern_stats)

    # Calculate promotion rate
    total_patterns = Map.get(pattern_stats, :total, 0)
    promoted = Map.get(promoter_stats, :promoted_count, 0)
    promotion_rate = if total_patterns > 0, do: promoted / total_patterns, else: 0.0

    # Identify high-value detection modes
    high_value_modes = identify_high_value_modes(detector_modes, pattern_stats)

    # Generate meta-insights
    meta_insights = generate_meta_insights(type_distribution, promotion_rate, high_value_modes)

    %{
      pattern_type_distribution: type_distribution,
      total_patterns: total_patterns,
      promoted_patterns: promoted,
      promotion_rate: Float.round(promotion_rate, 3),
      detection_modes_used: detector_modes,
      high_value_modes: high_value_modes,
      meta_insights: meta_insights,
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Synthesizes high-level meta-learning insights.

  Combines strategy effectiveness, parameter recommendations, and meta-patterns
  into actionable insights about the learning system as a whole.

  ## Returns
    Map with synthesized insights and recommendations
  """
  @spec meta_insights() :: map()
  def meta_insights do
    strategy_analysis = analyze_strategy_effectiveness()
    parameter_recommendations = recommend_parameter_adjustments()
    meta_patterns = detect_meta_patterns()

    # Synthesize top insights
    insights = []

    # Insight: Best performing strategy
    insights =
      case strategy_analysis.rankings do
        [top | _] ->
          top_data = strategy_analysis.strategies[top]

          [
            %{
              type: :top_performer,
              message:
                "#{humanize(top)} is your best learning strategy (#{round(top_data.effectiveness * 100)}% effective)",
              action: "Consider increasing reliance on this strategy"
            }
            | insights
          ]

        _ ->
          insights
      end

    # Insight: Underperforming strategies
    underperforming =
      strategy_analysis.strategies
      |> Enum.filter(fn {_k, v} -> Map.get(v, :effectiveness, 0) < @warning_threshold end)
      |> Enum.map(fn {k, _v} -> k end)

    insights =
      if underperforming != [] do
        [
          %{
            type: :underperformers,
            message:
              "These strategies need attention: #{Enum.join(Enum.map(underperforming, &humanize/1), ", ")}",
            action: "Review parameter recommendations or investigate data quality"
          }
          | insights
        ]
      else
        insights
      end

    # Insight: Promotion rate
    insights =
      if meta_patterns.promotion_rate < 0.05 do
        [
          %{
            type: :low_promotion,
            message:
              "Pattern promotion rate is very low (#{round(meta_patterns.promotion_rate * 100)}%)",
            action:
              "Consider lowering promotion thresholds or increasing pattern detection sensitivity"
          }
          | insights
        ]
      else
        insights
      end

    # Insight: Data sufficiency
    data_issues =
      strategy_analysis.data_sources
      |> Enum.filter(fn {_k, v} -> v == false end)
      |> Enum.map(fn {k, _v} -> k end)

    insights =
      if data_issues != [] do
        [
          %{
            type: :data_gap,
            message: "Missing data from: #{Enum.join(Enum.map(data_issues, &to_string/1), ", ")}",
            action: "Ensure these systems are running and collecting data"
          }
          | insights
        ]
      else
        insights
      end

    %{
      strategy_summary: %{
        overall_health: strategy_analysis.overall_learning_health,
        average_effectiveness: strategy_analysis.average_effectiveness,
        top_strategy: List.first(strategy_analysis.rankings)
      },
      key_insights: Enum.reverse(insights),
      recommendations_count: length(parameter_recommendations),
      high_priority_recommendations:
        Enum.filter(parameter_recommendations, fn r -> r.priority == :high end),
      meta_pattern_summary: %{
        promotion_rate: meta_patterns.promotion_rate,
        total_patterns: meta_patterns.total_patterns
      },
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

  defp gather_calibration_data do
    [:prediction, :classification, :retrieval, :tool_execution]
    |> Enum.map(fn cat ->
      data = safe_call(fn -> FeedbackLoop.get_calibration(cat) end, %{})
      {cat, data}
    end)
    |> Map.new()
  end

  defp gather_emergence_data do
    %{
      pattern_stats: safe_call(fn -> Pattern.stats() end, %{}),
      promoter_stats: safe_call(fn -> Promoter.stats() end, %{})
    }
  end

  defp compute_feedback_loop_effectiveness(data) when data == %{},
    do: %{effectiveness: 0.0, status: :no_data, trend: :unknown}

  defp compute_feedback_loop_effectiveness(data) do
    pred_eff = Map.get(data, :prediction_effectiveness, 0.0)
    class_eff = Map.get(data, :classification_effectiveness, 0.0)
    tool_eff = Map.get(data, :tool_learning_effectiveness, 0.0)

    effectiveness = (pred_eff + class_eff + tool_eff) / 3

    trend =
      case get_in(data, [:trends, :prediction]) do
        :improving -> :improving
        :declining -> :declining
        _ -> :stable
      end

    %{
      effectiveness: effectiveness,
      status: effectiveness_to_status(effectiveness),
      trend: trend,
      details: %{
        prediction: pred_eff,
        classification: class_eff,
        tool_execution: tool_eff
      }
    }
  end

  defp compute_hebbian_effectiveness(data) when data == %{},
    do: %{effectiveness: 0.0, status: :no_data, trend: :unknown}

  defp compute_hebbian_effectiveness(data) do
    edges_created = Map.get(data, :edges_created, 0)
    outcome_edges = Map.get(data, :outcome_edges_created, 0)
    strengthened = Map.get(data, :outcome_edges_strengthened, 0)

    # Effectiveness based on edge creation and strengthening activity
    activity_score = min(1.0, (edges_created + outcome_edges + strengthened) / 100)

    %{
      effectiveness: activity_score,
      status: effectiveness_to_status(activity_score),
      trend: :unknown,
      details: data
    }
  end

  defp compute_error_prediction_effectiveness(data) when data == %{},
    do: %{effectiveness: 0.0, status: :no_data, trend: :unknown}

  defp compute_error_prediction_effectiveness(data) do
    failures_recorded = Map.get(data, :failures_recorded, 0)
    warnings_issued = Map.get(data, :warnings_issued, 0)
    warnings_heeded = Map.get(data, :warnings_heeded, 0)

    # Effectiveness: ratio of heeded warnings to issued warnings
    heed_rate = if warnings_issued > 0, do: warnings_heeded / warnings_issued, else: 0.5

    # Bonus for having data
    data_bonus = if failures_recorded > 10, do: 0.2, else: 0.0

    effectiveness = min(1.0, heed_rate + data_bonus)

    %{
      effectiveness: effectiveness,
      status: effectiveness_to_status(effectiveness),
      trend: :unknown,
      details: data
    }
  end

  defp compute_emergence_effectiveness(data) when data == %{},
    do: %{effectiveness: 0.0, status: :no_data, trend: :unknown}

  defp compute_emergence_effectiveness(data) do
    pattern_stats = Map.get(data, :pattern_stats, %{})
    promoter_stats = Map.get(data, :promoter_stats, %{})

    total_patterns = Map.get(pattern_stats, :total, 0)
    promoted = Map.get(promoter_stats, :promoted_count, 0)

    # Effectiveness based on pattern generation and promotion
    generation_score = min(1.0, total_patterns / 50)

    promotion_score =
      if total_patterns > 0, do: min(1.0, promoted / (total_patterns * 0.1)), else: 0.0

    effectiveness = (generation_score + promotion_score) / 2

    %{
      effectiveness: effectiveness,
      status: effectiveness_to_status(effectiveness),
      trend: :unknown,
      details: %{
        total_patterns: total_patterns,
        promoted: promoted
      }
    }
  end

  defp compute_calibration_effectiveness(data) when data == %{},
    do: %{effectiveness: 0.0, status: :no_data, reliability: :unknown}

  defp compute_calibration_effectiveness(data) do
    # Check if any category has reliable calibration
    reliabilities =
      data
      |> Enum.map(fn {_cat, cal} ->
        case cal do
          %{reliability: rel, calibration_factor: factor} ->
            # Good calibration is close to 1.0
            deviation = abs(1.0 - factor)
            quality = max(0, 1.0 - deviation)
            {rel, quality}

          _ ->
            {:unknown, 0.0}
        end
      end)

    reliable_count = Enum.count(reliabilities, fn {rel, _} -> rel == :reliable end)

    avg_quality =
      reliabilities
      |> Enum.map(fn {_, q} -> q end)
      |> average()

    effectiveness = (reliable_count / 4 + avg_quality) / 2

    %{
      effectiveness: effectiveness,
      status: effectiveness_to_status(effectiveness),
      reliability: if(reliable_count >= 2, do: :reliable, else: :building),
      details: data
    }
  end

  defp effectiveness_to_status(eff) when eff >= @excellent_threshold, do: :excellent
  defp effectiveness_to_status(eff) when eff >= @good_threshold, do: :good
  defp effectiveness_to_status(eff) when eff >= @warning_threshold, do: :fair
  defp effectiveness_to_status(eff) when eff > 0, do: :poor
  defp effectiveness_to_status(_), do: :no_data

  defp effectiveness_to_health(eff) when eff >= @excellent_threshold, do: :excellent
  defp effectiveness_to_health(eff) when eff >= @good_threshold, do: :healthy
  defp effectiveness_to_health(eff) when eff >= @warning_threshold, do: :needs_attention
  defp effectiveness_to_health(_), do: :struggling

  defp average([]), do: 0.0
  defp average(list), do: Enum.sum(list) / length(list)

  defp get_detector_modes do
    # Get available detection modes from Detector
    try do
      Detector.available_modes()
    rescue
      _ -> [:temporal, :tool_sequences, :workflow, :preference]
    catch
      :exit, _ -> [:temporal, :tool_sequences, :workflow, :preference]
    end
  end

  defp analyze_pattern_types(stats) when stats == %{}, do: %{}

  defp analyze_pattern_types(stats) do
    Map.get(stats, :by_type, %{})
  end

  defp identify_high_value_modes(modes, _pattern_stats) do
    # For now, return modes that are likely to produce high-value patterns
    # In the future, this would analyze which modes produce the most promoted patterns
    modes
    |> Enum.filter(fn mode -> mode in [:semantic_clustering, :cross_session, :workflow] end)
  end

  defp generate_meta_insights(type_distribution, promotion_rate, high_value_modes) do
    insights = []

    # Insight about pattern diversity
    insights =
      if map_size(type_distribution) >= 3 do
        ["Pattern detection is diverse across #{map_size(type_distribution)} types" | insights]
      else
        [
          "Pattern detection could be more diverse (currently #{map_size(type_distribution)} types)"
          | insights
        ]
      end

    # Insight about promotion
    insights =
      cond do
        promotion_rate > 0.2 ->
          [
            "High promotion rate (#{round(promotion_rate * 100)}%) - many patterns becoming capabilities"
            | insights
          ]

        promotion_rate > 0.05 ->
          ["Healthy promotion rate (#{round(promotion_rate * 100)}%)" | insights]

        promotion_rate > 0 ->
          [
            "Low promotion rate (#{round(promotion_rate * 100)}%) - patterns not reaching capability status"
            | insights
          ]

        true ->
          ["No patterns promoted yet - this will improve with usage" | insights]
      end

    # Insight about high-value modes
    if high_value_modes != [] do
      [
        "High-value detection modes active: #{Enum.join(Enum.map(high_value_modes, &to_string/1), ", ")}"
        | insights
      ]
    else
      insights
    end
  end

  defp humanize(atom) when is_atom(atom) do
    atom
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
