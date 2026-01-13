defmodule Mimo.Brain.Emergence.PredictionFeedbackTest do
  @moduledoc """
  Tests for the prediction feedback loop (Track 4.2 P2).
  """
  use Mimo.DataCase, async: false

  alias Mimo.Brain.Emergence.{Pattern, Prediction, PredictionFeedback}

  describe "record_prediction/2" do
    test "records a prediction for a pattern" do
      pattern = insert_pattern()

      prediction_data = %{
        predicted_outcome: :will_promote,
        confidence: 0.75,
        eta_days: 10.5,
        factors: %{velocity: :accelerating}
      }

      assert {:ok, pred} = PredictionFeedback.record_prediction(pattern, prediction_data)
      assert pred.pattern_id == pattern.id
      assert pred.predicted_outcome == :will_promote
      assert pred.confidence == 0.75
      assert pred.eta_days == 10.5
      assert pred.pattern_snapshot.strength == pattern.strength
    end

    test "sets deadline based on eta_days" do
      pattern = insert_pattern()

      {:ok, pred} =
        PredictionFeedback.record_prediction(pattern, %{
          predicted_outcome: :will_promote,
          confidence: 0.8,
          eta_days: 7.0
        })

      # Deadline should be ~7 days from now
      diff_seconds = DateTime.diff(pred.deadline_at, pred.predicted_at)
      diff_days = diff_seconds / (24 * 60 * 60)
      assert_in_delta diff_days, 7.0, 0.1
    end

    test "defaults deadline to 30 days if no eta" do
      pattern = insert_pattern()

      {:ok, pred} =
        PredictionFeedback.record_prediction(pattern, %{
          predicted_outcome: :stable,
          confidence: 0.5
        })

      diff_seconds = DateTime.diff(pred.deadline_at, pred.predicted_at)
      diff_days = diff_seconds / (24 * 60 * 60)
      assert_in_delta diff_days, 30.0, 0.1
    end
  end

  describe "process_pending/0" do
    test "processes expired predictions" do
      pattern = insert_pattern()

      # Create a prediction with past deadline
      past_deadline = DateTime.add(DateTime.utc_now(), -1, :day)

      {:ok, pred} =
        %Prediction{}
        |> Prediction.changeset(%{
          pattern_id: pattern.id,
          predicted_outcome: :will_promote,
          confidence: 0.7,
          predicted_at: DateTime.add(DateTime.utc_now(), -10, :day),
          deadline_at: past_deadline
        })
        |> Mimo.Repo.insert()

      assert is_nil(pred.outcome)

      {:ok, result} = PredictionFeedback.process_pending()

      assert result.processed == 1
      assert result.success == 1

      # Verify outcome was recorded
      updated = Mimo.Repo.get(Prediction, pred.id)
      refute is_nil(updated.outcome)
    end

    test "records promoted outcome for promoted patterns" do
      pattern = insert_pattern(%{status: :promoted})

      # Create prediction from when pattern was active
      past = DateTime.add(DateTime.utc_now(), -5, :day)

      {:ok, pred} =
        %Prediction{}
        |> Prediction.changeset(%{
          pattern_id: pattern.id,
          predicted_outcome: :will_promote,
          confidence: 0.9,
          pattern_snapshot: %{status: :active, strength: 0.5},
          predicted_at: past,
          deadline_at: DateTime.add(DateTime.utc_now(), -1, :day)
        })
        |> Mimo.Repo.insert()

      PredictionFeedback.process_pending()

      updated = Mimo.Repo.get(Prediction, pred.id)
      assert updated.outcome == :promoted
      # Perfect prediction
      assert updated.accuracy_score == 1.0
    end
  end

  describe "calibration_adjustment/0" do
    test "returns calibration data structure" do
      result = PredictionFeedback.calibration_adjustment()

      assert is_map(result.adjustments)
      assert is_boolean(result.is_calibrated)
      assert Map.has_key?(result, :sample_size)
    end

    test "is_calibrated is false with no data" do
      result = PredictionFeedback.calibration_adjustment()

      assert result.is_calibrated == false
    end
  end

  describe "apply_calibration/1" do
    test "returns raw confidence when not calibrated" do
      result = PredictionFeedback.apply_calibration(0.75)
      assert result == 0.75
    end

    test "clamps result to valid range" do
      # Even if not calibrated, should handle edge cases
      assert PredictionFeedback.apply_calibration(0.0) >= 0.0
      assert PredictionFeedback.apply_calibration(1.0) <= 1.0
    end
  end

  describe "stats/0" do
    test "returns comprehensive statistics" do
      stats = PredictionFeedback.stats()

      assert is_map(stats.accuracy)
      assert is_map(stats.by_outcome)
      assert is_map(stats.calibration)
      assert Map.has_key?(stats, :pending_count)
      assert Map.has_key?(stats, :total_predictions)
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Helpers
  # ─────────────────────────────────────────────────────────────────

  defp insert_pattern(attrs \\ %{}) do
    now = DateTime.utc_now()

    default_attrs = %{
      type: :workflow,
      description: "Test pattern for prediction",
      components: [%{type: "action", name: "test"}],
      trigger_conditions: ["test"],
      success_rate: 0.75,
      occurrences: 5,
      strength: 0.6,
      status: :active,
      first_seen: now,
      last_seen: now,
      evolution: [],
      signature: "test_signature_#{System.unique_integer()}"
    }

    merged = Map.merge(default_attrs, attrs)

    {:ok, pattern} =
      %Pattern{}
      |> Pattern.changeset(merged)
      |> Mimo.Repo.insert()

    pattern
  end
end
