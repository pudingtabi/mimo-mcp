defmodule Mimo.Brain.EmotionalScorerTest do
  @moduledoc """
  Tests for SPEC-105 Emotional Salience Scoring.
  """
  use Mimo.DataCase, async: true

  alias Mimo.Brain.EmotionalScorer

  describe "score/1" do
    test "detects high positive emotional content" do
      content = "Finally fixed the authentication bug! This is amazing!"
      assert {:ok, result} = EmotionalScorer.score(content)

      assert result.score >= 0.5
      assert result.valence == :positive
      assert result.importance_boost > 0
      assert "finally" in result.keywords_found or "fixed" in result.keywords_found
    end

    test "detects high negative emotional content" do
      content = "The system crashed again. This is a terrible nightmare!"
      assert {:ok, result} = EmotionalScorer.score(content)

      assert result.score >= 0.5
      assert result.valence == :negative
      assert result.importance_boost > 0
    end

    test "detects neutral content" do
      content = "Updated the configuration file with new database settings."
      assert {:ok, result} = EmotionalScorer.score(content)

      assert result.score < 0.3
      assert result.valence == :neutral
      assert result.importance_boost == 0
    end

    test "handles empty content" do
      assert {:ok, result} = EmotionalScorer.score("")
      assert result.score == 0.0
      assert result.valence == :neutral
    end

    test "returns method indicator" do
      assert {:ok, result} = EmotionalScorer.score("Test content")
      assert result.method == :keywords
    end
  end

  describe "apply_boost/1" do
    test "boosts importance for emotional content" do
      attrs = %{content: "Finally solved the problem! Amazing breakthrough!", importance: 0.5}
      result = EmotionalScorer.apply_boost(attrs)

      assert result.importance > 0.5
      assert result.importance <= 1.0
      assert result.metadata[:emotional_score] != nil
    end

    test "does not boost neutral content" do
      attrs = %{content: "Updated file", importance: 0.5}
      result = EmotionalScorer.apply_boost(attrs)

      # Should remain unchanged or have minimal change
      assert result.importance == 0.5 or result.importance <= 0.55
    end

    test "clamps importance at 1.0" do
      attrs = %{content: "Amazing success! Finally fixed it!", importance: 0.95}
      result = EmotionalScorer.apply_boost(attrs)

      assert result.importance <= 1.0
    end

    test "handles attrs without content" do
      attrs = %{importance: 0.5}
      result = EmotionalScorer.apply_boost(attrs)

      assert result == attrs
    end
  end

  describe "batch_score/1" do
    test "scores multiple contents" do
      contents = [
        "Fixed the bug!",
        "Normal update",
        "Terrible crash!"
      ]

      assert {:ok, results} = EmotionalScorer.batch_score(contents)
      assert length(results) == 3

      # First should be positive
      assert Enum.at(results, 0).valence == :positive or Enum.at(results, 0).score > 0

      # Third should be negative
      assert Enum.at(results, 2).valence == :negative or Enum.at(results, 2).score > 0
    end
  end

  describe "stats/0" do
    test "returns statistics about emotional scoring" do
      stats = EmotionalScorer.stats()

      assert is_map(stats)
      assert Map.has_key?(stats, :total_memories)
      assert Map.has_key?(stats, :with_emotional_score)
      assert Map.has_key?(stats, :coverage_percent)
      assert Map.has_key?(stats, :average_emotional_score)
    end
  end

  describe "integration with dispatcher" do
    test "emotional_score operation works" do
      args = %{"operation" => "emotional_score", "content" => "Fixed the bug!"}
      assert {:ok, result} = Mimo.Tools.Dispatchers.Cognitive.dispatch(args)

      assert result.type == "emotional_score"
      assert result.score >= 0
      assert result.valence in [:positive, :negative, :neutral]
    end

    test "emotional_stats operation works" do
      args = %{"operation" => "emotional_stats"}
      assert {:ok, result} = Mimo.Tools.Dispatchers.Cognitive.dispatch(args)

      assert result.type == "emotional_stats"
      assert is_map(result.stats)
    end
  end
end
