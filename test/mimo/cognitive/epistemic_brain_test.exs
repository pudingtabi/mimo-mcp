defmodule Mimo.Cognitive.EpistemicBrainTest do
  use Mimo.DataCase, async: false
  alias Mimo.Cognitive.{EpistemicBrain, Uncertainty}

  describe "query/2" do
    test "returns query result with epistemic awareness" do
      {:ok, result} = EpistemicBrain.query("test query")

      assert Map.has_key?(result, :response)
      assert Map.has_key?(result, :uncertainty)
      assert Map.has_key?(result, :gap_analysis)
      assert Map.has_key?(result, :actions_taken)

      assert is_binary(result.response)
      assert %Uncertainty{} = result.uncertainty
      assert is_map(result.gap_analysis)
      assert is_list(result.actions_taken)
    end

    test "tracks actions taken" do
      {:ok, result} = EpistemicBrain.query("test query")

      # Should have at least assessed confidence
      assert :assessed_confidence in result.actions_taken or
               :handled_no_knowledge in result.actions_taken or
               :handled_low_confidence in result.actions_taken
    end

    test "can disable confidence assessment" do
      {:ok, result} = EpistemicBrain.query("test", assess_confidence: false)

      refute :assessed_confidence in result.actions_taken
    end

    test "can disable response calibration" do
      {:ok, result} = EpistemicBrain.query("test", calibrate_response: false)

      refute :calibrated_response in result.actions_taken
    end

    test "can disable uncertainty tracking" do
      {:ok, result} = EpistemicBrain.query("test", track_uncertainty: false)

      refute :tracked_uncertainty in result.actions_taken
    end
  end

  describe "quick_query/1" do
    test "returns response tuple" do
      result = EpistemicBrain.quick_query("test query")

      assert {:ok, response} = result
      assert is_binary(response)
    end
  end

  describe "can_answer?/2" do
    test "returns boolean" do
      result = EpistemicBrain.can_answer?("test query")

      assert is_boolean(result)
    end

    test "respects minimum confidence parameter" do
      # With very high minimum, likely cannot answer
      result = EpistemicBrain.can_answer?("obscure topic xyz", :high)
      assert is_boolean(result)

      # With very low minimum, more likely can answer
      result = EpistemicBrain.can_answer?("test", :unknown)
      assert result == true
    end
  end

  describe "assess/1" do
    test "returns uncertainty struct" do
      result = EpistemicBrain.assess("test query")

      assert %Uncertainty{} = result
      assert result.topic == "test query"
    end
  end

  describe "analyze_gaps/1" do
    test "returns gap analysis" do
      result = EpistemicBrain.analyze_gaps("test query")

      assert is_map(result)
      assert Map.has_key?(result, :gap_type)
      assert Map.has_key?(result, :actions)
    end
  end

  describe "knowledge_improvement_suggestions/1" do
    test "returns list of suggestions" do
      suggestions = EpistemicBrain.knowledge_improvement_suggestions("obscure topic")

      assert is_list(suggestions)
    end

    test "suggestions have required fields" do
      suggestions = EpistemicBrain.knowledge_improvement_suggestions("test topic")

      Enum.each(suggestions, fn suggestion ->
        assert Map.has_key?(suggestion, :action)
        assert Map.has_key?(suggestion, :priority)
        assert Map.has_key?(suggestion, :description)
      end)
    end
  end
end
