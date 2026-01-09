defmodule Mimo.Integration.PredictiveDispatchTest do
  @moduledoc """
  Tests for Level 3 Self-Understanding integration with tool dispatch.
  Verifies that predictions are automatically made and calibrated during dispatch.
  """
  use Mimo.DataCase, async: false

  alias Mimo.Tools
  alias Mimo.Cognitive.PredictiveModeling

  describe "predictive dispatch integration" do
    test "file dispatch creates prediction and calibration" do
      # Clear any existing predictions
      {:ok, initial_stats} = PredictiveModeling.stats()
      initial_count = initial_stats.total_predictions

      # Dispatch a file operation (use current directory which is allowed)
      _result = Tools.dispatch("file", %{"operation" => "ls", "path" => "."})

      # The key is that prediction is made regardless of success/failure

      # Wait for async calibration
      Process.sleep(50)

      # Should have created a new prediction
      {:ok, new_stats} = PredictiveModeling.stats()
      assert new_stats.total_predictions > initial_count
      assert new_stats.total_calibrated > initial_stats.total_calibrated
    end

    test "cognitive predictive operations skip prediction to avoid recursion" do
      {:ok, initial_stats} = PredictiveModeling.stats()
      initial_count = initial_stats.total_predictions

      # Dispatch a predict operation (should NOT create another prediction from wrapper)
      Tools.dispatch("cognitive", %{
        "operation" => "predict",
        "tool" => "file"
      })

      # Wait
      Process.sleep(50)

      {:ok, new_stats} = PredictiveModeling.stats()

      # The dispatch itself should NOT have created an additional prediction
      # (It creates one via the predict operation, but dispatch wrapper shouldn't add another)
      # Since predict creates 1, we expect total to increase by 1, not 2
      assert new_stats.total_predictions == initial_count + 1
    end

    test "terminal dispatch creates prediction" do
      {:ok, initial_stats} = PredictiveModeling.stats()
      initial_count = initial_stats.total_predictions

      # Dispatch a terminal command
      Tools.dispatch("terminal", %{"command" => "echo hello"})

      Process.sleep(50)

      {:ok, new_stats} = PredictiveModeling.stats()
      assert new_stats.total_predictions > initial_count
    end
  end
end
