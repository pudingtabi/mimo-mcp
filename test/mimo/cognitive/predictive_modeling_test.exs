defmodule Mimo.Cognitive.PredictiveModelingTest do
  @moduledoc """
  Tests for Level 3 Predictive Self-Modeling.

  The PredictiveModeling GenServer is already started by the application
  supervisor, so we just use it directly.
  """
  use ExUnit.Case, async: false

  alias Mimo.Cognitive.PredictiveModeling

  describe "predict/1" do
    test "returns prediction with required fields" do
      context = %{tool: "reason", operation: "guided", problem: "Test problem"}

      assert {:ok, prediction} = PredictiveModeling.predict(context)

      assert is_binary(prediction.id)
      assert String.starts_with?(prediction.id, "pred_")
      assert is_integer(prediction.estimated_duration_ms)
      assert is_float(prediction.success_probability)
      assert prediction.success_probability >= 0.0 and prediction.success_probability <= 1.0
      assert is_integer(prediction.estimated_steps)
      assert is_float(prediction.confidence)
      assert prediction.confidence >= 0.0 and prediction.confidence <= 1.0
    end

    test "uses defaults for unknown operations" do
      context = %{tool: "unknown_tool", operation: "unknown_op"}

      assert {:ok, prediction} = PredictiveModeling.predict(context)

      # Should use fallback defaults
      assert prediction.estimated_duration_ms == 1_000
      assert prediction.success_probability == 0.80
      # Low confidence without history
      assert prediction.confidence == 0.3
    end

    test "sets higher step estimate for reasoning operations" do
      context = %{tool: "reason", operation: "guided"}

      assert {:ok, prediction} = PredictiveModeling.predict(context)

      # Reasoning should predict multiple steps
      assert prediction.estimated_steps >= 1
    end
  end

  describe "calibrate/2" do
    test "calibrates a prediction" do
      # First make a prediction
      {:ok, prediction} = PredictiveModeling.predict(%{tool: "file", operation: "edit"})

      # Then calibrate it
      actual = %{actual_duration_ms: 150, success: true}

      assert :ok = PredictiveModeling.calibrate(prediction.id, actual)
    end
  end

  describe "calibration_score/1" do
    test "returns score or insufficient data" do
      assert {:ok, score} = PredictiveModeling.calibration_score()

      # Either has samples or reports insufficient
      assert is_integer(score.sample_count)
      assert score.trend in [:improving, :stable, :declining, :insufficient_data]
    end

    test "score values are in valid ranges" do
      # Make and calibrate a prediction to ensure some data
      {:ok, pred} = PredictiveModeling.predict(%{tool: "test_score", operation: "test"})
      :ok = PredictiveModeling.calibrate(pred.id, %{actual_duration_ms: 1000, success: true})

      Process.sleep(10)

      assert {:ok, score} = PredictiveModeling.calibration_score()

      # Validate score structure
      assert is_float(score.score) or score.score == 0.0
      assert is_float(score.duration_calibration) or score.duration_calibration == 0.0
      assert is_float(score.success_calibration) or score.success_calibration == 0.0
    end
  end

  describe "stats/0" do
    test "returns statistics" do
      # Make a prediction to ensure at least one exists
      {:ok, _pred} = PredictiveModeling.predict(%{tool: "test_stats", operation: "test"})

      assert {:ok, stats} = PredictiveModeling.stats()

      assert is_integer(stats.total_predictions)
      assert stats.total_predictions >= 1
      assert is_integer(stats.total_calibrated)
      assert is_float(stats.calibration_rate)
      assert is_float(stats.uptime_hours)
    end
  end

  describe "list_predictions/1" do
    test "lists predictions" do
      # Make several predictions
      for _ <- 1..3 do
        {:ok, _} = PredictiveModeling.predict(%{tool: "test_list", operation: "test"})
      end

      assert {:ok, predictions} = PredictiveModeling.list_predictions(limit: 10)

      assert is_list(predictions)
      assert length(predictions) >= 3
    end
  end
end
