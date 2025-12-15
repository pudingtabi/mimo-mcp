defmodule Mimo.Brain.Reflector.Optimizer do
  @moduledoc """
  Self-improving optimization layer for the Reflective Intelligence System.

  Part of the Evaluator-Optimizer pattern (Phase 2 Cognitive Enhancement).

  Implements outcome tracking and optimization to create a feedback loop where
  the system learns from the accuracy of its reflections.

  ## The Optimization Cycle

  ```
  Reflection → Predict Quality → Store Prediction
                                       ↓
  Later: Record Actual Outcome ← User Feedback/Success Metrics
                                       ↓
  Analyze Prediction vs Reality → Update Optimization Metrics
                                       ↓
  Optimize: Adjust Weights, Thresholds, Suggestions
  ```

  ## Key Concepts

  - **Prediction Accuracy**: How well did predicted scores match actual outcomes?
  - **Dimension Calibration**: Which dimensions are most predictive of quality?
  - **Suggestion Effectiveness**: Which suggestions lead to actual improvements?
  - **Threshold Optimization**: Is the quality threshold properly calibrated?

  ## Example

      # After a reflection
      {:ok, result} = Reflector.reflect_and_refine(output, context)
      Optimizer.record_prediction(result.evaluation, context_hash)

      # Later, when outcome is known
      Optimizer.record_outcome(context_hash, :success)

      # Periodically optimize
      stats = Optimizer.optimize()
      # => %{optimized: true, weight_updates: [...], threshold_change: 0.02}
  """

  use GenServer
  require Logger

  alias Mimo.Brain.Memory

  @table_name :reflector_optimizer
  @optimization_interval :timer.hours(1)
  @min_samples_for_optimization 20

  # ============================================
  # Type Definitions
  # ============================================

  @type outcome :: :success | :partial | :failure
  @type dimension ::
          :correctness | :completeness | :confidence | :clarity | :grounding | :error_risk

  @type prediction_record :: %{
          prediction_id: String.t(),
          predicted_score: float(),
          predicted_quality: String.t(),
          dimension_scores: map(),
          issues_count: non_neg_integer(),
          suggestions: [String.t()],
          iterations_needed: non_neg_integer(),
          context_hash: String.t(),
          recorded_at: DateTime.t()
        }

  @type optimization_metrics :: %{
          dimension_accuracy: %{dimension() => float()},
          threshold_performance: %{
            current: float(),
            optimal_estimated: float(),
            false_positive_rate: float(),
            false_negative_rate: float()
          },
          suggestion_effectiveness: %{String.t() => float()},
          refinement_success_rate: float(),
          total_predictions: non_neg_integer(),
          total_outcomes: non_neg_integer(),
          last_optimization: DateTime.t() | nil
        }

  # ============================================
  # Client API
  # ============================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Record a prediction from a reflection evaluation.

  Call this after `Reflector.reflect_and_refine/3` to track what was predicted.

  ## Parameters

  - `evaluation` - The evaluation result from Reflector
  - `context_hash` - A hash identifying the context (for matching with outcome)
  - `opts` - Additional metadata (iterations, suggestions applied, etc.)

  ## Returns

  - `{:ok, prediction_id}` on success
  """
  @spec record_prediction(map(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def record_prediction(evaluation, context_hash, opts \\ []) do
    GenServer.call(__MODULE__, {:record_prediction, evaluation, context_hash, opts})
  end

  @doc """
  Record the actual outcome of a reflection.

  Call this when you know whether the reflection led to a good result.

  ## Parameters

  - `context_hash` - The hash used when recording the prediction
  - `outcome` - `:success` | `:partial` | `:failure`
  - `opts` - Additional outcome details

  ## Returns

  - `{:ok, updated_count}` - Number of predictions matched and updated
  """
  @spec record_outcome(String.t(), outcome(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def record_outcome(context_hash, outcome, opts \\ []) do
    GenServer.call(__MODULE__, {:record_outcome, context_hash, outcome, opts})
  end

  @doc """
  Run an optimization cycle.

  Analyzes prediction vs outcome data to:
  1. Calculate dimension accuracy
  2. Estimate optimal threshold
  3. Compute suggestion effectiveness
  4. Generate optimization recommendations

  ## Options

  - `:force` - Run even if not enough samples (default: false)
  - `:apply` - Automatically apply optimizations (default: false)

  ## Returns

  - `{:ok, optimization_result}` with statistics and recommendations
  """
  @spec optimize(keyword()) :: {:ok, map()} | {:error, term()}
  def optimize(opts \\ []) do
    GenServer.call(__MODULE__, {:optimize, opts}, 30_000)
  end

  @doc """
  Get current optimization metrics.
  """
  @spec get_metrics() :: {:ok, optimization_metrics()}
  def get_metrics do
    GenServer.call(__MODULE__, :get_metrics)
  end

  @doc """
  Get optimization recommendations based on current metrics.
  """
  @spec get_recommendations() :: {:ok, [map()]}
  def get_recommendations do
    GenServer.call(__MODULE__, :get_recommendations)
  end

  @doc """
  Get the current optimized weights for evaluation dimensions.
  """
  @spec get_optimized_weights() :: map()
  def get_optimized_weights do
    GenServer.call(__MODULE__, :get_optimized_weights)
  end

  @doc """
  Get the current optimized quality threshold.
  """
  @spec get_optimized_threshold() :: float()
  def get_optimized_threshold do
    GenServer.call(__MODULE__, :get_optimized_threshold)
  end

  @doc """
  Get statistics about the optimizer state.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # ============================================
  # Server Implementation
  # ============================================

  @impl true
  def init(_opts) do
    # Create ETS table for fast access
    Mimo.EtsSafe.ensure_table(@table_name, [:named_table, :set, :public, read_concurrency: true])

    state = %{
      # context_hash => [prediction_records]
      predictions: %{},
      # context_hash => outcome_record
      outcomes: %{},
      metrics: initial_metrics(),
      optimized_weights: default_weights(),
      optimized_threshold: 0.70,
      last_optimization: nil
    }

    # Load persisted state from memory
    state = load_persisted_state(state)

    # Cache metrics in ETS
    cache_metrics(state.metrics)

    # Schedule periodic optimization
    schedule_optimization()

    {:ok, state}
  end

  @impl true
  def handle_call({:record_prediction, evaluation, context_hash, opts}, _from, state) do
    prediction_id = generate_prediction_id()

    record = %{
      prediction_id: prediction_id,
      predicted_score: evaluation[:aggregate_score] || evaluation["aggregate_score"] || 0.0,
      predicted_quality:
        get_in(evaluation, [:quality_level]) || get_in(evaluation, ["quality_level"]) || "unknown",
      dimension_scores: extract_dimension_scores(evaluation),
      issues_count: length(evaluation[:issues] || evaluation["issues"] || []),
      suggestions: extract_suggestion_texts(evaluation),
      iterations_needed: Keyword.get(opts, :iterations, 0),
      context_hash: context_hash,
      recorded_at: DateTime.utc_now()
    }

    predictions = Map.update(state.predictions, context_hash, [record], &[record | &1])
    new_state = %{state | predictions: predictions}

    # Update metrics
    new_metrics = update_prediction_count(state.metrics)
    new_state = %{new_state | metrics: new_metrics}
    cache_metrics(new_metrics)

    {:reply, {:ok, prediction_id}, new_state}
  end

  @impl true
  def handle_call({:record_outcome, context_hash, outcome, opts}, _from, state) do
    case Map.get(state.predictions, context_hash) do
      nil ->
        {:reply, {:ok, 0}, state}

      predictions ->
        outcome_record = %{
          outcome: outcome,
          recorded_at: DateTime.utc_now(),
          details: Keyword.get(opts, :details, %{})
        }

        outcomes = Map.put(state.outcomes, context_hash, outcome_record)
        new_state = %{state | outcomes: outcomes}

        # Update metrics
        new_metrics = update_outcome_count(state.metrics, length(predictions))
        new_state = %{new_state | metrics: new_metrics}
        cache_metrics(new_metrics)

        # Persist outcome to memory for cross-session learning
        persist_outcome(context_hash, predictions, outcome_record)

        {:reply, {:ok, length(predictions)}, new_state}
    end
  end

  @impl true
  def handle_call({:optimize, opts}, _from, state) do
    force = Keyword.get(opts, :force, false)
    apply_changes = Keyword.get(opts, :apply, false)

    # Check if we have enough data
    total_with_outcomes = count_predictions_with_outcomes(state)

    if total_with_outcomes < @min_samples_for_optimization and not force do
      {:reply,
       {:ok,
        %{
          optimized: false,
          reason: :insufficient_data,
          samples: total_with_outcomes,
          required: @min_samples_for_optimization
        }}, state}
    else
      # Run optimization
      optimization_result = run_optimization(state)

      new_state =
        if apply_changes do
          %{
            state
            | optimized_weights: optimization_result.recommended_weights,
              optimized_threshold: optimization_result.recommended_threshold,
              last_optimization: DateTime.utc_now(),
              metrics: update_after_optimization(state.metrics, optimization_result)
          }
        else
          %{
            state
            | last_optimization: DateTime.utc_now(),
              metrics: update_after_optimization(state.metrics, optimization_result)
          }
        end

      cache_metrics(new_state.metrics)

      {:reply, {:ok, optimization_result}, new_state}
    end
  end

  @impl true
  def handle_call(:get_metrics, _from, state) do
    {:reply, {:ok, state.metrics}, state}
  end

  @impl true
  def handle_call(:get_recommendations, _from, state) do
    recommendations = generate_recommendations(state)
    {:reply, {:ok, recommendations}, state}
  end

  @impl true
  def handle_call(:get_optimized_weights, _from, state) do
    {:reply, state.optimized_weights, state}
  end

  @impl true
  def handle_call(:get_optimized_threshold, _from, state) do
    {:reply, state.optimized_threshold, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      total_predictions: map_size(state.predictions),
      total_outcomes: map_size(state.outcomes),
      predictions_with_outcomes: count_predictions_with_outcomes(state),
      optimized_threshold: state.optimized_threshold,
      last_optimization: state.last_optimization,
      dimension_count: map_size(state.optimized_weights),
      metrics_summary: summarize_metrics(state.metrics)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:run_optimization, state) do
    # Background optimization
    if count_predictions_with_outcomes(state) >= @min_samples_for_optimization do
      case run_optimization(state) do
        result when is_map(result) ->
          Logger.info("[Optimizer] Background optimization complete: #{inspect(result.summary)}")

        _ ->
          :ok
      end
    end

    schedule_optimization()
    {:noreply, state}
  end

  # ============================================
  # Optimization Logic
  # ============================================

  defp run_optimization(state) do
    # Gather all prediction-outcome pairs
    pairs = gather_prediction_outcome_pairs(state)

    if pairs == [] do
      %{
        optimized: false,
        reason: :no_data,
        summary: "No prediction-outcome pairs available"
      }
    else
      # Calculate dimension accuracy
      dimension_accuracy = calculate_dimension_accuracy(pairs)

      # Calculate refinement success rate
      refinement_success = calculate_refinement_success_rate(pairs)

      # Calculate suggestion effectiveness
      suggestion_effectiveness = calculate_suggestion_effectiveness(pairs)

      # Estimate optimal threshold
      {optimal_threshold, fp_rate, fn_rate} =
        estimate_optimal_threshold(pairs, state.optimized_threshold)

      # Calculate recommended weights based on dimension accuracy
      recommended_weights =
        calculate_recommended_weights(dimension_accuracy, state.optimized_weights)

      %{
        optimized: true,
        samples_analyzed: length(pairs),
        dimension_accuracy: dimension_accuracy,
        refinement_success_rate: refinement_success,
        suggestion_effectiveness: suggestion_effectiveness,
        threshold_analysis: %{
          current: state.optimized_threshold,
          optimal_estimated: optimal_threshold,
          false_positive_rate: fp_rate,
          false_negative_rate: fn_rate
        },
        recommended_weights: recommended_weights,
        recommended_threshold: optimal_threshold,
        summary:
          "Analyzed #{length(pairs)} pairs, optimal threshold: #{Float.round(optimal_threshold, 3)}"
      }
    end
  end

  defp gather_prediction_outcome_pairs(state) do
    state.predictions
    |> Enum.flat_map(fn {context_hash, predictions} ->
      case Map.get(state.outcomes, context_hash) do
        nil ->
          []

        outcome ->
          Enum.map(predictions, fn pred ->
            %{
              prediction: pred,
              outcome: outcome
            }
          end)
      end
    end)
  end

  defp calculate_dimension_accuracy(pairs) do
    dimensions = [:correctness, :completeness, :confidence, :clarity, :grounding, :error_risk]

    Enum.into(dimensions, %{}, fn dim ->
      accuracy = calculate_single_dimension_accuracy(pairs, dim)
      {dim, accuracy}
    end)
  end

  defp calculate_single_dimension_accuracy(pairs, dimension) do
    scores_with_outcomes =
      pairs
      |> Enum.map(fn %{prediction: pred, outcome: outcome} ->
        dim_score = get_in(pred, [:dimension_scores, dimension]) || 0.5
        outcome_score = outcome_to_score(outcome.outcome)
        {dim_score, outcome_score}
      end)

    if length(scores_with_outcomes) < 3 do
      # Neutral if insufficient data
      0.5
    else
      # Calculate correlation between dimension score and outcome
      calculate_correlation(scores_with_outcomes)
    end
  end

  defp calculate_correlation(pairs) do
    n = length(pairs)
    if n < 2, do: 0.5, else: do_calculate_correlation(pairs, n)
  end

  defp do_calculate_correlation(pairs, n) do
    {sum_x, sum_y, sum_xy, sum_x2, sum_y2} =
      Enum.reduce(pairs, {0.0, 0.0, 0.0, 0.0, 0.0}, fn {x, y}, {sx, sy, sxy, sx2, sy2} ->
        {sx + x, sy + y, sxy + x * y, sx2 + x * x, sy2 + y * y}
      end)

    numerator = n * sum_xy - sum_x * sum_y
    denominator = :math.sqrt((n * sum_x2 - sum_x * sum_x) * (n * sum_y2 - sum_y * sum_y))

    if denominator == 0.0 do
      0.5
    else
      # Convert correlation to 0-1 scale (0.5 is neutral)
      correlation = numerator / denominator
      (correlation + 1.0) / 2.0
    end
  end

  defp calculate_refinement_success_rate(pairs) do
    refined_pairs =
      Enum.filter(pairs, fn %{prediction: pred} ->
        pred.iterations_needed > 0
      end)

    if refined_pairs == [] do
      0.5
    else
      successful = Enum.count(refined_pairs, fn %{outcome: o} -> o.outcome == :success end)
      successful / length(refined_pairs)
    end
  end

  defp calculate_suggestion_effectiveness(pairs) do
    # Group by suggestion types and calculate success rate for each
    pairs
    |> Enum.flat_map(fn %{prediction: pred, outcome: outcome} ->
      Enum.map(pred.suggestions, fn suggestion ->
        {normalize_suggestion(suggestion), outcome.outcome}
      end)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.into(%{}, fn {suggestion, outcomes} ->
      success_rate = Enum.count(outcomes, &(&1 == :success)) / max(length(outcomes), 1)
      {suggestion, success_rate}
    end)
  end

  defp normalize_suggestion(suggestion) when is_binary(suggestion) do
    suggestion
    |> String.downcase()
    |> String.slice(0, 50)
    |> String.replace(~r/[^a-z\s]/, "")
    |> String.trim()
  end

  defp normalize_suggestion(_), do: "unknown"

  defp estimate_optimal_threshold(pairs, current_threshold) do
    # Try different thresholds and find the one with best balance
    thresholds = [0.50, 0.55, 0.60, 0.65, 0.70, 0.75, 0.80, 0.85]

    results =
      Enum.map(thresholds, fn threshold ->
        {fp, fn_} = calculate_error_rates(pairs, threshold)
        # Balance: minimize total error with slight preference for avoiding false positives
        score = 1.0 - (fp * 1.2 + fn_)
        {threshold, fp, fn_, score}
      end)

    {best_threshold, fp_rate, fn_rate, _score} =
      Enum.max_by(results, fn {_, _, _, score} -> score end)

    # Don't change too drastically from current
    adjusted_threshold = current_threshold * 0.7 + best_threshold * 0.3

    {Float.round(adjusted_threshold, 3), Float.round(fp_rate, 3), Float.round(fn_rate, 3)}
  end

  defp calculate_error_rates(pairs, threshold) do
    total = length(pairs)

    if total == 0 do
      {0.0, 0.0}
    else
      # False positive: predicted high quality but outcome was failure
      fp =
        Enum.count(pairs, fn %{prediction: pred, outcome: outcome} ->
          pred.predicted_score >= threshold and outcome.outcome == :failure
        end)

      # False negative: predicted low quality but outcome was success
      fn_ =
        Enum.count(pairs, fn %{prediction: pred, outcome: outcome} ->
          pred.predicted_score < threshold and outcome.outcome == :success
        end)

      {fp / total, fn_ / total}
    end
  end

  defp calculate_recommended_weights(dimension_accuracy, current_weights) do
    # Adjust weights based on how predictive each dimension is
    total_accuracy = Enum.reduce(dimension_accuracy, 0.0, fn {_, acc}, sum -> sum + acc end)

    if total_accuracy == 0.0 do
      current_weights
    else
      # Blend current weights with accuracy-based weights
      Enum.into(dimension_accuracy, %{}, fn {dim, accuracy} ->
        current = Map.get(current_weights, dim, 0.15)
        # 70% current, 30% accuracy-based
        new_weight = current * 0.7 + accuracy / total_accuracy * 0.3
        {dim, Float.round(new_weight, 3)}
      end)
      |> normalize_weights()
    end
  end

  defp normalize_weights(weights) do
    total = Enum.reduce(weights, 0.0, fn {_, w}, sum -> sum + w end)

    if total == 0.0 do
      weights
    else
      Enum.into(weights, %{}, fn {k, v} -> {k, Float.round(v / total, 3)} end)
    end
  end

  # ============================================
  # Recommendations
  # ============================================

  defp generate_recommendations(state) do
    recommendations = []

    # Check if we have enough data
    total_outcomes = map_size(state.outcomes)

    recommendations =
      if total_outcomes < @min_samples_for_optimization do
        [
          %{
            type: :data_collection,
            priority: :high,
            message: "Collect more outcome data for optimization",
            current: total_outcomes,
            target: @min_samples_for_optimization
          }
          | recommendations
        ]
      else
        recommendations
      end

    # Check dimension accuracy
    recommendations =
      state.metrics.dimension_accuracy
      |> Enum.filter(fn {_, acc} -> acc < 0.4 end)
      |> Enum.reduce(recommendations, fn {dim, acc}, recs ->
        [
          %{
            type: :dimension_calibration,
            priority: :medium,
            message: "Dimension '#{dim}' has low predictive accuracy (#{Float.round(acc, 2)})",
            dimension: dim,
            accuracy: acc
          }
          | recs
        ]
      end)

    # Check threshold calibration
    recommendations =
      if state.metrics.threshold_performance.false_positive_rate > 0.20 do
        [
          %{
            type: :threshold_adjustment,
            priority: :high,
            message: "High false positive rate - consider raising threshold",
            current_rate: state.metrics.threshold_performance.false_positive_rate,
            suggested: state.metrics.threshold_performance.optimal_estimated
          }
          | recommendations
        ]
      else
        recommendations
      end

    Enum.reverse(recommendations)
  end

  # ============================================
  # Helper Functions
  # ============================================

  defp generate_prediction_id do
    "pred_#{:erlang.unique_integer([:positive]) |> Integer.to_string(36)}"
  end

  defp extract_dimension_scores(evaluation) do
    scores = evaluation[:scores] || evaluation["scores"] || %{}

    %{
      correctness: scores[:correctness] || scores["correctness"] || 0.0,
      completeness: scores[:completeness] || scores["completeness"] || 0.0,
      confidence: scores[:confidence] || scores["confidence"] || 0.0,
      clarity: scores[:clarity] || scores["clarity"] || 0.0,
      grounding: scores[:grounding] || scores["grounding"] || 0.0,
      error_risk: scores[:error_risk] || scores["error_risk"] || 0.0
    }
  end

  defp extract_suggestion_texts(evaluation) do
    suggestions = evaluation[:suggestions] || evaluation["suggestions"] || []

    Enum.map(suggestions, fn
      %{action: action} -> action
      %{"action" => action} -> action
      s when is_binary(s) -> s
      _ -> "unknown"
    end)
  end

  defp outcome_to_score(:success), do: 1.0
  defp outcome_to_score(:partial), do: 0.5
  defp outcome_to_score(:failure), do: 0.0
  defp outcome_to_score(_), do: 0.5

  defp count_predictions_with_outcomes(state) do
    state.predictions
    |> Map.keys()
    |> Enum.count(&Map.has_key?(state.outcomes, &1))
  end

  defp initial_metrics do
    %{
      dimension_accuracy: %{
        correctness: 0.5,
        completeness: 0.5,
        confidence: 0.5,
        clarity: 0.5,
        grounding: 0.5,
        error_risk: 0.5
      },
      threshold_performance: %{
        current: 0.70,
        optimal_estimated: 0.70,
        false_positive_rate: 0.0,
        false_negative_rate: 0.0
      },
      suggestion_effectiveness: %{},
      refinement_success_rate: 0.5,
      total_predictions: 0,
      total_outcomes: 0,
      last_optimization: nil
    }
  end

  defp default_weights do
    %{
      correctness: 0.25,
      completeness: 0.20,
      confidence: 0.15,
      clarity: 0.15,
      grounding: 0.15,
      error_risk: 0.10
    }
  end

  defp update_prediction_count(metrics) do
    %{metrics | total_predictions: metrics.total_predictions + 1}
  end

  defp update_outcome_count(metrics, count) do
    %{metrics | total_outcomes: metrics.total_outcomes + count}
  end

  defp update_after_optimization(metrics, result) do
    %{
      metrics
      | dimension_accuracy: result[:dimension_accuracy] || metrics.dimension_accuracy,
        threshold_performance: result[:threshold_analysis] || metrics.threshold_performance,
        suggestion_effectiveness:
          result[:suggestion_effectiveness] || metrics.suggestion_effectiveness,
        refinement_success_rate:
          result[:refinement_success_rate] || metrics.refinement_success_rate,
        last_optimization: DateTime.utc_now()
    }
  end

  defp summarize_metrics(metrics) do
    %{
      avg_dimension_accuracy: average(Map.values(metrics.dimension_accuracy)),
      threshold: metrics.threshold_performance.current,
      refinement_success: metrics.refinement_success_rate,
      total_predictions: metrics.total_predictions,
      total_outcomes: metrics.total_outcomes
    }
  end

  defp average([]), do: 0.0
  defp average(list), do: Enum.sum(list) / length(list)

  defp cache_metrics(metrics) do
    :ets.insert(@table_name, {:metrics, metrics})
  end

  defp load_persisted_state(state) do
    # Try to load from memory
    case Memory.search("optimizer metrics", limit: 1, category: "optimizer_state") do
      {:ok, [%{content: content} | _]} ->
        try do
          case Jason.decode(content) do
            {:ok, persisted} ->
              %{
                state
                | optimized_weights: Map.get(persisted, "weights", state.optimized_weights),
                  optimized_threshold: Map.get(persisted, "threshold", state.optimized_threshold)
              }

            _ ->
              state
          end
        rescue
          _ -> state
        end

      _ ->
        state
    end
  end

  defp persist_outcome(context_hash, predictions, outcome) do
    content =
      Jason.encode!(%{
        context_hash: context_hash,
        prediction_count: length(predictions),
        outcome: outcome.outcome,
        recorded_at: DateTime.to_iso8601(outcome.recorded_at)
      })

    Task.start(fn ->
      Memory.store(%{
        content: content,
        category: "reflection_outcome",
        importance: 0.6
      })
    end)
  end

  defp schedule_optimization do
    Process.send_after(self(), :run_optimization, @optimization_interval)
  end
end
