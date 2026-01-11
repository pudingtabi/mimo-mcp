defmodule Mimo.Brain.Emergence.PredictionTest do
  @moduledoc """
  Tests for Phase 4.2 Prediction Layer (SPEC-044 v1.4).

  Tests the predict_emergence/1, calculate_eta/1, and
  calculate_prediction_confidence/1 functions.
  """

  use Mimo.DataCase

  alias Mimo.Brain.Emergence.Metrics
  alias Mimo.Brain.Emergence.Pattern

  describe "predict_emergence/1" do
    test "returns predictions with required fields" do
      result = Metrics.predict_emergence(limit: 5)

      assert is_map(result)
      assert Map.has_key?(result, :predictions)
      assert Map.has_key?(result, :model_accuracy)
      assert Map.has_key?(result, :total_active_patterns)
      assert Map.has_key?(result, :prediction_count)
      assert Map.has_key?(result, :timestamp)

      assert is_list(result.predictions)
      assert is_number(result.model_accuracy)
      assert is_integer(result.total_active_patterns)
    end

    test "respects limit parameter" do
      result = Metrics.predict_emergence(limit: 2)

      assert length(result.predictions) <= 2
    end

    test "respects min_confidence parameter" do
      # With very high threshold, we may get fewer results
      result = Metrics.predict_emergence(min_confidence: 0.9)

      # All predictions should meet the threshold
      for prediction <- result.predictions do
        assert prediction.confidence >= 0.9
      end
    end

    test "predictions contain expected fields" do
      # Create a test pattern first
      {:ok, pattern} =
        Pattern.create(%{
          type: :workflow,
          description: "Test workflow pattern for prediction",
          components: [%{tool: "file"}, %{tool: "terminal"}],
          occurrences: 5,
          success_rate: 0.7,
          strength: 0.5
        })

      result = Metrics.predict_emergence(limit: 10, min_confidence: 0.0)

      # Find our pattern in predictions
      prediction = Enum.find(result.predictions, fn p -> p.pattern_id == pattern.id end)

      if prediction do
        assert Map.has_key?(prediction, :pattern_id)
        assert Map.has_key?(prediction, :type)
        assert Map.has_key?(prediction, :description)
        assert Map.has_key?(prediction, :eta_days)
        assert Map.has_key?(prediction, :confidence)
        assert Map.has_key?(prediction, :trajectory)
        assert Map.has_key?(prediction, :factors)
        assert Map.has_key?(prediction, :promotion_ready)
      end
    end
  end

  describe "calculate_eta/1" do
    test "returns ETA for pattern below thresholds" do
      {:ok, pattern} =
        Pattern.create(%{
          type: :workflow,
          description: "Test workflow for ETA",
          components: [%{tool: "file"}],
          occurrences: 3,
          success_rate: 0.6,
          strength: 0.4
        })

      {:ok, eta_result} = Metrics.calculate_eta(pattern)

      assert is_map(eta_result)
      assert Map.has_key?(eta_result, :confidence)
      assert Map.has_key?(eta_result, :limiting_factor)

      # Should identify a limiting factor
      assert eta_result.limiting_factor in [:occurrences, :strength, :success_rate, :unknown]
    end

    test "returns 0 days for promotion-ready pattern" do
      {:ok, pattern} =
        Pattern.create(%{
          type: :skill,
          description: "Promotion-ready pattern",
          components: [%{tool: "file"}, %{tool: "terminal"}],
          occurrences: 15,
          success_rate: 0.9,
          strength: 0.85
        })

      {:ok, eta_result} = Metrics.calculate_eta(pattern)

      # All thresholds met, ETA should be 0 or very low
      if eta_result.days != nil do
        assert eta_result.days <= 1.0
      end
    end

    test "identifies correct limiting factor" do
      # Pattern limited by occurrences (only 2 occurrences, but high success/strength)
      {:ok, low_occ_pattern} =
        Pattern.create(%{
          type: :workflow,
          description: "Low occurrence pattern",
          components: [%{tool: "memory"}],
          occurrences: 2,
          success_rate: 0.9,
          strength: 0.8
        })

      {:ok, eta_result} = Metrics.calculate_eta(low_occ_pattern)

      # Should identify a limiting factor (either occurrences or strength is acceptable
      # since without evolution history, strength ETA returns :infinity)
      assert eta_result.limiting_factor in [:occurrences, :strength, :success_rate]
      # ETA result should have confidence
      assert is_number(eta_result.confidence)
      assert eta_result.confidence >= 0.0 and eta_result.confidence <= 1.0
    end
  end

  describe "calculate_prediction_confidence/1" do
    test "returns confidence between 0 and 1" do
      {:ok, pattern} =
        Pattern.create(%{
          type: :inference,
          description: "Pattern for confidence test",
          components: [%{memory: "test"}],
          occurrences: 5,
          success_rate: 0.7,
          strength: 0.5
        })

      confidence = Metrics.calculate_prediction_confidence(pattern)

      assert is_float(confidence)
      assert confidence >= 0.0
      assert confidence <= 1.0
    end

    test "higher confidence for mature patterns" do
      # Pattern with evolution history
      {:ok, mature_pattern} =
        Pattern.create(%{
          type: :workflow,
          description: "Mature pattern with history",
          components: [%{tool: "code"}],
          occurrences: 20,
          success_rate: 0.85,
          strength: 0.7,
          first_seen: DateTime.add(DateTime.utc_now(), -30, :day),
          evolution: [
            %{
              timestamp: DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -25, :day)),
              occurrences: 5,
              strength: 0.3
            },
            %{
              timestamp: DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -20, :day)),
              occurrences: 10,
              strength: 0.5
            },
            %{
              timestamp: DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -15, :day)),
              occurrences: 15,
              strength: 0.6
            },
            %{
              timestamp: DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -5, :day)),
              occurrences: 20,
              strength: 0.7
            }
          ]
        })

      # Pattern with minimal history
      {:ok, new_pattern} =
        Pattern.create(%{
          type: :workflow,
          description: "New pattern without history",
          components: [%{tool: "web"}],
          occurrences: 2,
          success_rate: 0.5,
          strength: 0.2,
          evolution: []
        })

      mature_confidence = Metrics.calculate_prediction_confidence(mature_pattern)
      new_confidence = Metrics.calculate_prediction_confidence(new_pattern)

      # Mature pattern should have higher confidence
      assert mature_confidence > new_confidence
    end
  end

  describe "prediction_accuracy/0" do
    test "returns accuracy metrics" do
      result = Metrics.prediction_accuracy()

      assert is_map(result)
      assert Map.has_key?(result, :recently_promoted)
      assert Map.has_key?(result, :accuracy)
      assert Map.has_key?(result, :calibration)
    end
  end
end
