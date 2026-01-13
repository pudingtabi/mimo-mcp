defmodule Mimo.Brain.Emergence.PredictionFeedback do
  @moduledoc """
  SPEC-044 Track 4.2 P2: Prediction feedback loop for emergence patterns.

  This module:
  - Records predictions when `predict_emergence/1` is called
  - Periodically checks pending predictions for outcomes
  - Updates model accuracy based on results
  - Provides calibration data for confidence adjustment

  ## Usage

  ```elixir
  # Record a prediction (called automatically by predict_emergence)
  PredictionFeedback.record_prediction(pattern, prediction_data)

  # Process pending predictions and record outcomes
  PredictionFeedback.process_pending()

  # Get feedback for confidence calibration
  PredictionFeedback.calibration_adjustment()
  ```
  """

  require Logger
  alias Mimo.Brain.Emergence.{Pattern, Prediction}

  @doc """
  Records a prediction for later outcome tracking.

  Called when a prediction is made via `Metrics.predict_emergence/1`.
  """
  @spec record_prediction(Pattern.t(), map()) :: {:ok, Prediction.t()} | {:error, term()}
  def record_prediction(pattern, prediction_data) do
    case Prediction.record(pattern, prediction_data) do
      {:ok, pred} ->
        Logger.debug("Recorded prediction #{pred.id} for pattern #{pattern.id}")
        {:ok, pred}

      {:error, changeset} ->
        Logger.warning("Failed to record prediction: #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  end

  @doc """
  Processes pending predictions and records their outcomes.

  Checks predictions whose deadline has passed and determines
  the actual outcome by examining the pattern's current state.
  """
  @spec process_pending(keyword()) :: {:ok, map()}
  def process_pending(opts \\ []) do
    pending = Prediction.pending_outcomes(opts)

    results =
      pending
      |> Enum.map(&check_and_record_outcome/1)
      |> Enum.group_by(fn {status, _} -> status end)

    summary = %{
      processed: length(pending),
      success: length(results[:ok] || []),
      errors: length(results[:error] || []),
      timestamp: DateTime.utc_now()
    }

    if summary.processed > 0 do
      Logger.info(
        "Processed #{summary.processed} pending predictions: " <>
          "#{summary.success} succeeded, #{summary.errors} failed"
      )
    end

    {:ok, summary}
  end

  @doc """
  Gets calibration adjustment factors based on historical accuracy.

  Returns adjustment multipliers for different confidence levels
  based on how accurate predictions have been historically.
  """
  @spec calibration_adjustment() :: map()
  def calibration_adjustment do
    buckets = Prediction.calibration_buckets(days: 90)

    adjustments =
      buckets
      |> Enum.map(fn bucket ->
        # If predicted confidence differs from actual accuracy, calculate adjustment
        if bucket.count >= 3 and bucket.avg_accuracy do
          adjustment = bucket.avg_accuracy / max(0.1, bucket.avg_confidence)
          {bucket.bucket, Float.round(adjustment, 3)}
        else
          # No adjustment if insufficient data
          {bucket.bucket, 1.0}
        end
      end)
      |> Map.new()

    stats = Prediction.accuracy_stats()

    %{
      adjustments: adjustments,
      overall_accuracy: stats.avg_accuracy,
      calibration_error: stats.calibration_error,
      is_calibrated: stats.is_calibrated,
      sample_size: stats.total
    }
  end

  @doc """
  Applies calibration to a raw confidence score.

  Uses historical accuracy data to adjust confidence predictions.
  """
  @spec apply_calibration(float()) :: float()
  def apply_calibration(raw_confidence) do
    adjustment = calibration_adjustment()

    unless adjustment.is_calibrated do
      # Not enough data for calibration
      raw_confidence
    else
      # Find the appropriate bucket
      bucket = round(raw_confidence * 10) * 10
      multiplier = Map.get(adjustment.adjustments, bucket, 1.0)

      # Apply adjustment and clamp to valid range
      adjusted = raw_confidence * multiplier
      min(1.0, max(0.0, Float.round(adjusted, 3)))
    end
  end

  @doc """
  Gets comprehensive feedback statistics.
  """
  @spec stats() :: map()
  def stats do
    accuracy = Prediction.accuracy_stats()
    by_outcome = Prediction.count_by_outcome()
    calibration = calibration_adjustment()

    %{
      accuracy: accuracy,
      by_outcome: by_outcome,
      calibration: calibration,
      pending_count: Map.get(by_outcome, :pending, 0),
      total_predictions: Enum.sum(Map.values(by_outcome))
    }
  end

  # ─────────────────────────────────────────────────────────────────
  # Private Helpers
  # ─────────────────────────────────────────────────────────────────

  defp check_and_record_outcome(prediction) do
    # Get the current pattern state
    case Pattern.get(prediction.pattern_id) do
      {:error, :not_found} ->
        # Pattern was deleted - mark as expired
        Prediction.record_outcome(prediction, :expired)

      {:ok, pattern} ->
        outcome = determine_outcome(prediction, pattern)
        Prediction.record_outcome(prediction, outcome)
    end
  end

  defp determine_outcome(prediction, pattern) do
    snapshot = prediction.pattern_snapshot || %{}
    original_status = Map.get(snapshot, "status") || Map.get(snapshot, :status)
    original_strength = Map.get(snapshot, "strength") || Map.get(snapshot, :strength, 0.0)

    cond do
      # Pattern was promoted
      pattern.status == :promoted and original_status != :promoted ->
        :promoted

      # Pattern was archived or became dormant (declined)
      pattern.status in [:archived, :dormant] ->
        :declined

      # Pattern strength significantly decreased
      pattern.strength < original_strength * 0.5 ->
        :declined

      # Pattern is still active - check if deadline matters
      pattern.status == :active ->
        if DateTime.compare(DateTime.utc_now(), prediction.deadline_at) == :gt do
          # Past deadline, still active = prediction didn't come true yet
          :still_active
        else
          # Not past deadline, keep waiting
          :still_active
        end

      # Default
      true ->
        :still_active
    end
  end
end
