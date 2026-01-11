defmodule Mimo.Tools.Dispatchers.EmergencePredictTest do
  @moduledoc """
  Tests for the emergence_predict MCP operation (SPEC-044 v1.4).
  """

  use Mimo.DataCase

  alias Mimo.Tools.Dispatchers.Emergence, as: EmergenceDispatcher
  alias Mimo.Brain.Emergence.Pattern

  describe "dispatch/1 with operation=predict" do
    test "returns predictions for all active patterns" do
      {:ok, result} = EmergenceDispatcher.dispatch(%{"operation" => "predict"})

      assert result.operation == :predict
      assert result.spec == "SPEC-044 v1.4 Phase 4.2"
      assert Map.has_key?(result, :predictions)
      assert Map.has_key?(result, :model_accuracy)
      assert Map.has_key?(result, :interpretation)
      assert Map.has_key?(result, :timestamp)
    end

    test "respects limit parameter" do
      {:ok, result} =
        EmergenceDispatcher.dispatch(%{
          "operation" => "predict",
          "limit" => 3
        })

      assert length(result.predictions) <= 3
    end

    test "respects min_confidence parameter" do
      {:ok, result} =
        EmergenceDispatcher.dispatch(%{
          "operation" => "predict",
          "min_confidence" => 0.5
        })

      for prediction <- result.predictions do
        assert prediction.confidence >= 0.5
      end
    end

    test "returns prediction for specific pattern" do
      # Create a test pattern
      {:ok, pattern} =
        Pattern.create(%{
          type: :workflow,
          description: "Specific pattern for predict test",
          components: [%{tool: "file"}, %{tool: "memory"}],
          occurrences: 5,
          success_rate: 0.7,
          strength: 0.5
        })

      {:ok, result} =
        EmergenceDispatcher.dispatch(%{
          "operation" => "predict",
          "pattern_id" => pattern.id
        })

      assert result.operation == :predict
      assert result.pattern_id == pattern.id
      assert Map.has_key?(result, :current_state)
      assert Map.has_key?(result, :prediction)
      assert Map.has_key?(result, :recommendation)
    end

    test "returns error for non-existent pattern" do
      fake_id = Ecto.UUID.generate()

      {:error, message} =
        EmergenceDispatcher.dispatch(%{
          "operation" => "predict",
          "pattern_id" => fake_id
        })

      assert message =~ "Pattern not found"
    end
  end
end
