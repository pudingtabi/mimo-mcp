defmodule Mimo.Cognitive.PredictiveModeling do
  @moduledoc """
  SPEC-SELF Level 3: Predictive Self-Modeling

  Enables Mimo to PREDICT its own behavior before execution, building
  the foundation for genuine self-understanding. This module:

  1. PREDICTS outcomes before actions (duration, success probability, steps)
  2. CALIBRATES predictions against actual outcomes over time
  3. LEARNS patterns from FeedbackLoop history
  4. REPORTS calibration scores for self-awareness metrics

  ## Architecture

  ```
  Before Action ──► predict(context) ──► %{duration_ms, success_prob, steps}
                                              │
  After Action ──► calibrate(pred_id, actual) ──► Update calibration
                                              │
  Query ──► calibration_score() ──► How accurate are predictions?
  ```

  ## Integration

  Predictions flow through FeedbackBridge which wraps tool execution.
  Calibration data is stored in ETS for fast access.

  ## Example

      # Before executing a reasoning task
      {:ok, prediction} = PredictiveModeling.predict(%{
        tool: "reason",
        operation: "guided",
        problem: "Design auth system"
      })
      # => %{
      #   id: "pred_abc123",
      #   estimated_duration_ms: 5000,
      #   success_probability: 0.75,
      #   estimated_steps: 4,
      #   confidence: 0.6
      # }

      # After execution completes
      :ok = PredictiveModeling.calibrate(prediction.id, %{
        actual_duration_ms: 4800,
        success: true,
        actual_steps: 5
      })
  """

  use GenServer
  require Logger

  alias Mimo.Cognitive.FeedbackLoop

  # ETS tables
  @predictions_table :mimo_predictions
  @calibration_table :mimo_prediction_calibration

  # Configuration
  @max_predictions 5_000
  @calibration_window_days 7
  @min_samples_for_score 10

  # Default estimates (before we have history)
  @default_duration_ms %{
    "reason.guided" => 5_000,
    "reason.step" => 500,
    "terminal.execute" => 3_000,
    "file.edit" => 200,
    "memory.search" => 150,
    "code.diagnose" => 2_000
  }

  @default_success_prob %{
    "reason.guided" => 0.75,
    "terminal.execute" => 0.70,
    "file.edit" => 0.85,
    "memory.search" => 0.90,
    "code.diagnose" => 0.80
  }

  ## Public API

  @doc """
  Makes a prediction before executing an action.

  Returns a prediction with estimated duration, success probability,
  and a unique ID for later calibration.

  ## Parameters
    - context: Map with :tool, :operation, and optional :problem or :command

  ## Returns
    {:ok, prediction} with fields:
    - id: Unique prediction ID
    - estimated_duration_ms: Predicted execution time
    - success_probability: Predicted success rate (0.0-1.0)
    - estimated_steps: For reasoning, predicted step count
    - confidence: How confident this prediction is (0.0-1.0)
  """
  @spec predict(map()) :: {:ok, map()} | {:error, term()}
  def predict(context) do
    GenServer.call(__MODULE__, {:predict, context})
  end

  @doc """
  Calibrates a prediction against actual outcome.

  Call this after the action completes to update the calibration model.

  ## Parameters
    - prediction_id: The ID from predict/1
    - actual: Map with :actual_duration_ms, :success, and optional :actual_steps
  """
  @spec calibrate(String.t(), map()) :: :ok | {:error, term()}
  def calibrate(prediction_id, actual) do
    GenServer.cast(__MODULE__, {:calibrate, prediction_id, actual})
  end

  @doc """
  Returns the overall calibration score.

  Higher scores mean predictions are more accurate.
  Score of 0.6+ means predictions are within ~40% of actual.

  ## Options
    - days: Number of days to analyze (default: 7)
    - category: Filter by tool category

  ## Returns
    Map with:
    - score: Overall calibration score (0.0-1.0)
    - duration_calibration: How accurate duration predictions are
    - success_calibration: How accurate success predictions are
    - sample_count: Number of calibrated predictions
    - trend: :improving | :stable | :declining
  """
  @spec calibration_score(keyword()) :: {:ok, map()}
  def calibration_score(opts \\ []) do
    GenServer.call(__MODULE__, {:calibration_score, opts})
  end

  @doc """
  Returns prediction history for analysis.

  ## Options
    - limit: Max predictions to return (default: 50)
    - tool: Filter by tool name
    - include_uncalibrated: Include predictions not yet calibrated
  """
  @spec list_predictions(keyword()) :: {:ok, list(map())}
  def list_predictions(opts \\ []) do
    GenServer.call(__MODULE__, {:list_predictions, opts})
  end

  @doc """
  Returns statistics about prediction performance.
  """
  @spec stats() :: {:ok, map()}
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  ## GenServer Implementation

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Create ETS tables
    :ets.new(@predictions_table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@calibration_table, [:named_table, :set, :public, read_concurrency: true])

    Logger.info("[PredictiveModeling] Level 3 Self-Understanding initialized")

    {:ok,
     %{
       total_predictions: 0,
       total_calibrated: 0,
       started_at: System.system_time(:millisecond)
     }}
  end

  @impl true
  def handle_call({:predict, context}, _from, state) do
    prediction = make_prediction(context, state)

    # Store prediction for later calibration
    :ets.insert(@predictions_table, {prediction.id, prediction})

    # Evict old predictions if needed
    maybe_evict_old_predictions()

    new_state = %{state | total_predictions: state.total_predictions + 1}

    {:reply, {:ok, prediction}, new_state}
  end

  @impl true
  def handle_call({:calibration_score, opts}, _from, state) do
    score = compute_calibration_score(opts)
    {:reply, {:ok, score}, state}
  end

  @impl true
  def handle_call({:list_predictions, opts}, _from, state) do
    predictions = list_predictions_impl(opts)
    {:reply, {:ok, predictions}, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = compute_stats(state)
    {:reply, {:ok, stats}, state}
  end

  @impl true
  def handle_cast({:calibrate, prediction_id, actual}, state) do
    new_state = do_calibrate(prediction_id, actual, state)
    {:noreply, new_state}
  end

  ## Private Functions

  defp make_prediction(context, _state) do
    tool = Map.get(context, :tool, "unknown")
    operation = Map.get(context, :operation, "unknown")
    key = "#{tool}.#{operation}"

    # Get historical data for this operation type
    history = get_operation_history(tool, operation)

    # Estimate duration
    estimated_duration_ms =
      if Enum.empty?(history) do
        Map.get(@default_duration_ms, key, 1_000)
      else
        history
        |> Enum.map(& &1.duration_ms)
        |> Enum.filter(&(&1 > 0))
        |> median()
        |> round()
      end

    # Estimate success probability
    success_probability =
      if Enum.empty?(history) do
        Map.get(@default_success_prob, key, 0.80)
      else
        success_count = Enum.count(history, & &1.success)
        success_count / max(length(history), 1)
      end

    # Estimate steps (for reasoning)
    estimated_steps =
      if tool in ["reason", "cognitive"] do
        if Enum.empty?(history) do
          4
        else
          history
          |> Enum.map(&Map.get(&1, :steps, 4))
          |> median()
          |> round()
        end
      else
        1
      end

    # Confidence based on sample size
    sample_count = length(history)

    confidence =
      cond do
        sample_count == 0 -> 0.3
        sample_count < 5 -> 0.4
        sample_count < 20 -> 0.6
        sample_count < 50 -> 0.75
        true -> 0.85
      end

    %{
      id: generate_prediction_id(),
      tool: tool,
      operation: operation,
      context: context,
      estimated_duration_ms: estimated_duration_ms,
      success_probability: Float.round(success_probability, 3),
      estimated_steps: estimated_steps,
      confidence: confidence,
      created_at: System.system_time(:millisecond),
      calibrated: false
    }
  end

  defp get_operation_history(tool, operation) do
    # Query FeedbackLoop for historical outcomes
    case FeedbackLoop.query_patterns(:tool_execution) do
      %{by_tool: by_tool} when is_map(by_tool) ->
        Map.get(by_tool, tool, %{})
        |> Map.get(:operations, %{})
        |> Map.get(operation, [])

      _ ->
        # Fallback: read from our calibration table
        :ets.match_object(@calibration_table, {:_, %{tool: tool, operation: operation}})
        |> Enum.map(fn {_id, entry} -> entry end)
        |> Enum.take(50)
    end
  end

  defp do_calibrate(prediction_id, actual, state) do
    case :ets.lookup(@predictions_table, prediction_id) do
      [{^prediction_id, prediction}] ->
        # Compute calibration metrics
        calibration_entry = %{
          prediction_id: prediction_id,
          tool: prediction.tool,
          operation: prediction.operation,
          predicted_duration_ms: prediction.estimated_duration_ms,
          actual_duration_ms: Map.get(actual, :actual_duration_ms, 0),
          predicted_success_prob: prediction.success_probability,
          actual_success: Map.get(actual, :success, true),
          predicted_steps: prediction.estimated_steps,
          actual_steps: Map.get(actual, :actual_steps, 1),
          duration_error: compute_duration_error(prediction, actual),
          success: Map.get(actual, :success, true),
          duration_ms: Map.get(actual, :actual_duration_ms, 0),
          steps: Map.get(actual, :actual_steps, 1),
          calibrated_at: System.system_time(:millisecond)
        }

        # Store calibration
        :ets.insert(@calibration_table, {prediction_id, calibration_entry})

        # Update prediction as calibrated
        updated_prediction = Map.put(prediction, :calibrated, true)
        :ets.insert(@predictions_table, {prediction_id, updated_prediction})

        # Emit telemetry
        :telemetry.execute(
          [:mimo, :predictive_modeling, :calibrated],
          %{
            duration_error: calibration_entry.duration_error,
            success_match: prediction.success_probability > 0.5 == actual.success
          },
          %{tool: prediction.tool, operation: prediction.operation}
        )

        %{state | total_calibrated: state.total_calibrated + 1}

      [] ->
        Logger.warning("[PredictiveModeling] Prediction #{prediction_id} not found for calibration")
        state
    end
  end

  defp compute_duration_error(prediction, actual) do
    predicted = prediction.estimated_duration_ms
    actual_ms = Map.get(actual, :actual_duration_ms, predicted)

    if actual_ms > 0 do
      abs(predicted - actual_ms) / max(actual_ms, 1)
    else
      0.0
    end
  end

  defp compute_calibration_score(opts) do
    days = Keyword.get(opts, :days, @calibration_window_days)
    cutoff = System.system_time(:millisecond) - days * 24 * 60 * 60 * 1000

    # Get recent calibrations
    calibrations =
      :ets.tab2list(@calibration_table)
      |> Enum.map(fn {_id, entry} -> entry end)
      |> Enum.filter(fn entry ->
        Map.get(entry, :calibrated_at, 0) > cutoff
      end)

    sample_count = length(calibrations)

    if sample_count < @min_samples_for_score do
      %{
        score: 0.0,
        duration_calibration: 0.0,
        success_calibration: 0.0,
        sample_count: sample_count,
        trend: :insufficient_data,
        message: "Need at least #{@min_samples_for_score} samples, have #{sample_count}"
      }
    else
      # Duration calibration: 1 - Mean Absolute Percentage Error
      duration_errors =
        calibrations
        |> Enum.map(& &1.duration_error)
        |> Enum.filter(&(&1 >= 0))

      duration_mape = mean(duration_errors)
      duration_calibration = max(0.0, 1.0 - duration_mape)

      # Success calibration: 1 - Brier Score
      success_briers =
        calibrations
        |> Enum.map(fn entry ->
          actual = if entry.actual_success, do: 1.0, else: 0.0
          predicted = entry.predicted_success_prob
          (predicted - actual) ** 2
        end)

      success_brier = mean(success_briers)
      success_calibration = max(0.0, 1.0 - success_brier)

      # Combined score
      score = 0.6 * duration_calibration + 0.4 * success_calibration

      # Compute trend
      trend = compute_trend(calibrations)

      %{
        score: Float.round(score, 3),
        duration_calibration: Float.round(duration_calibration, 3),
        success_calibration: Float.round(success_calibration, 3),
        sample_count: sample_count,
        trend: trend
      }
    end
  end

  defp compute_trend(calibrations) when length(calibrations) < 10, do: :insufficient_data

  defp compute_trend(calibrations) do
    sorted = Enum.sort_by(calibrations, & &1.calibrated_at)
    midpoint = div(length(sorted), 2)
    {early, late} = Enum.split(sorted, midpoint)

    early_avg = mean(Enum.map(early, & &1.duration_error))
    late_avg = mean(Enum.map(late, & &1.duration_error))

    cond do
      late_avg < early_avg * 0.9 -> :improving
      late_avg > early_avg * 1.1 -> :declining
      true -> :stable
    end
  end

  defp list_predictions_impl(opts) do
    limit = Keyword.get(opts, :limit, 50)
    tool_filter = Keyword.get(opts, :tool)
    include_uncalibrated = Keyword.get(opts, :include_uncalibrated, true)

    :ets.tab2list(@predictions_table)
    |> Enum.map(fn {_id, pred} -> pred end)
    |> Enum.filter(fn pred ->
      tool_match = is_nil(tool_filter) or pred.tool == tool_filter
      calibrated_match = include_uncalibrated or pred.calibrated
      tool_match and calibrated_match
    end)
    |> Enum.sort_by(& &1.created_at, :desc)
    |> Enum.take(limit)
  end

  defp compute_stats(state) do
    prediction_count = :ets.info(@predictions_table, :size)
    calibration_count = :ets.info(@calibration_table, :size)

    calibration_rate =
      if prediction_count > 0 do
        Float.round(calibration_count / prediction_count, 3)
      else
        0.0
      end

    uptime_ms = System.system_time(:millisecond) - state.started_at
    uptime_hours = Float.round(uptime_ms / 3_600_000, 2)

    %{
      total_predictions: prediction_count,
      total_calibrated: calibration_count,
      calibration_rate: calibration_rate,
      uptime_hours: uptime_hours
    }
  end

  defp maybe_evict_old_predictions do
    size = :ets.info(@predictions_table, :size)

    if size > @max_predictions do
      # Remove oldest uncalibrated predictions
      to_remove = size - @max_predictions + 100

      :ets.tab2list(@predictions_table)
      |> Enum.filter(fn {_id, pred} -> not pred.calibrated end)
      |> Enum.sort_by(fn {_id, pred} -> pred.created_at end)
      |> Enum.take(to_remove)
      |> Enum.each(fn {id, _} -> :ets.delete(@predictions_table, id) end)
    end
  end

  defp generate_prediction_id do
    "pred_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp median([]), do: 0.0

  defp median(list) when is_list(list) do
    sorted = Enum.sort(list)
    len = length(sorted)
    mid = div(len, 2)

    if rem(len, 2) == 0 do
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
    else
      Enum.at(sorted, mid)
    end
  end

  defp mean([]), do: 0.0
  defp mean(list), do: Enum.sum(list) / length(list)
end
