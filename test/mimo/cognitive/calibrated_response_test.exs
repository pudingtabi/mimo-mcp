defmodule Mimo.Cognitive.CalibratedResponseTest do
  use ExUnit.Case, async: true
  alias Mimo.Cognitive.{CalibratedResponse, Uncertainty}

  describe "format_response/3" do
    test "adds prefix for high confidence" do
      uncertainty = %Uncertainty{
        topic: "test",
        confidence: :high,
        score: 0.8,
        evidence_count: 5,
        sources: [],
        staleness: 0.0,
        gap_indicators: []
      }

      response = CalibratedResponse.format_response("Phoenix uses plugs.", uncertainty)

      # Should have a high confidence prefix
      assert String.contains?(response, "Phoenix uses plugs.")
      # Should have one of the high confidence prefixes
      has_prefix =
        String.contains?(response, "Based on my knowledge") or
          String.contains?(response, "I'm confident") or
          String.contains?(response, "According to") or
          String.contains?(response, "From what I know")

      assert has_prefix
    end

    test "adds prefix for medium confidence" do
      uncertainty = %Uncertainty{
        topic: "test",
        confidence: :medium,
        score: 0.5,
        evidence_count: 3,
        sources: [],
        staleness: 0.1,
        gap_indicators: []
      }

      response = CalibratedResponse.format_response("It works this way.", uncertainty)

      has_prefix =
        String.contains?(response, "From what I understand") or
          String.contains?(response, "I believe") or
          String.contains?(response, "It seems") or
          String.contains?(response, "Based on available") or
          String.contains?(response, "As far as I can tell")

      assert has_prefix
    end

    test "adds prefix and caveat for low confidence" do
      uncertainty = %Uncertainty{
        topic: "test",
        confidence: :low,
        score: 0.25,
        evidence_count: 1,
        sources: [%{type: :memory, id: "1", name: "m", relevance: 0.4}],
        staleness: 0.2,
        gap_indicators: []
      }

      response = CalibratedResponse.format_response("Maybe it works.", uncertainty)

      # Should have low confidence indicator
      assert String.contains?(response, "Confidence")
    end

    test "returns unknown message for unknown confidence" do
      uncertainty = %Uncertainty{
        topic: "test",
        confidence: :unknown,
        score: 0.0,
        evidence_count: 0,
        sources: [],
        staleness: 0.0,
        gap_indicators: []
      }

      response = CalibratedResponse.format_response("Some content", uncertainty)

      # Should be one of the unknown prefixes
      is_unknown_response =
        String.contains?(response, "don't have") or
          String.contains?(response, "outside my") or
          String.contains?(response, "need to research") or
          String.contains?(response, "not familiar")

      assert is_unknown_response
    end
  end

  describe "confidence_indicator/2" do
    test "generates indicator with emoji" do
      uncertainty = %Uncertainty{
        topic: "test",
        confidence: :high,
        score: 0.85,
        evidence_count: 5,
        sources: [],
        staleness: 0.0,
        gap_indicators: []
      }

      indicator = CalibratedResponse.confidence_indicator(uncertainty, include_emoji: true)

      assert String.contains?(indicator, "🟢") or String.contains?(indicator, "High")
    end

    test "generates indicator with score" do
      uncertainty = %Uncertainty{
        topic: "test",
        confidence: :medium,
        score: 0.55,
        evidence_count: 3,
        sources: [],
        staleness: 0.0,
        gap_indicators: []
      }

      indicator = CalibratedResponse.confidence_indicator(uncertainty, include_score: true)

      # Score is rounded to whole percentage
      assert String.contains?(indicator, "55")
    end

    test "generates indicator with source count" do
      uncertainty = %Uncertainty{
        topic: "test",
        confidence: :low,
        score: 0.3,
        evidence_count: 2,
        sources: [],
        staleness: 0.0,
        gap_indicators: []
      }

      indicator = CalibratedResponse.confidence_indicator(uncertainty, include_sources: true)

      assert String.contains?(indicator, "2 sources")
    end
  end

  describe "caveat_message/1" do
    test "returns nil for high confidence" do
      uncertainty = %Uncertainty{
        topic: "test",
        confidence: :high,
        score: 0.8,
        evidence_count: 5,
        sources: [],
        staleness: 0.1,
        gap_indicators: []
      }

      assert CalibratedResponse.caveat_message(uncertainty) == nil
    end

    test "returns caveat for low confidence" do
      uncertainty = %Uncertainty{
        topic: "test",
        confidence: :low,
        score: 0.3,
        evidence_count: 1,
        sources: [],
        staleness: 0.2,
        gap_indicators: []
      }

      caveat = CalibratedResponse.caveat_message(uncertainty)

      assert caveat != nil
      assert String.contains?(caveat, "may not be complete")
    end

    test "includes staleness warning" do
      uncertainty = %Uncertainty{
        topic: "test",
        confidence: :medium,
        score: 0.5,
        evidence_count: 3,
        sources: [],
        staleness: 0.6,
        gap_indicators: []
      }

      caveat = CalibratedResponse.caveat_message(uncertainty)

      assert caveat != nil
      assert String.contains?(caveat, "outdated")
    end

    test "includes gap indicators" do
      # Use low confidence so caveat is generated
      uncertainty = %Uncertainty{
        topic: "test",
        confidence: :low,
        score: 0.3,
        evidence_count: 1,
        sources: [],
        staleness: 0.1,
        gap_indicators: ["missing documentation"]
      }

      caveat = CalibratedResponse.caveat_message(uncertainty)

      assert caveat != nil
      assert String.contains?(caveat, "missing documentation")
    end
  end

  describe "unknown_response/3" do
    test "generates response with suggestions" do
      uncertainty = %Uncertainty{
        topic: "test",
        confidence: :unknown,
        score: 0.0,
        evidence_count: 0,
        sources: [],
        staleness: 0.0,
        gap_indicators: ["missing documentation"]
      }

      response = CalibratedResponse.unknown_response("what is X?", uncertainty)

      assert is_binary(response)
      # Should have unknown prefix
      is_unknown =
        String.contains?(response, "don't have") or
          String.contains?(response, "outside") or
          String.contains?(response, "need to research") or
          String.contains?(response, "not familiar")

      assert is_unknown
    end

    test "generates response without suggestions when disabled" do
      uncertainty = %Uncertainty{
        topic: "test",
        confidence: :unknown,
        score: 0.0,
        evidence_count: 0,
        sources: [],
        staleness: 0.0,
        gap_indicators: []
      }

      response =
        CalibratedResponse.unknown_response("what is X?", uncertainty, include_suggestions: false)

      assert is_binary(response)
      refute String.contains?(response, "However, I can help")
    end
  end

  describe "format_alternatives/1" do
    test "formats multiple alternatives with confidence" do
      u1 = %Uncertainty{
        topic: "test1",
        confidence: :high,
        score: 0.8,
        evidence_count: 5,
        sources: [],
        staleness: 0.0,
        gap_indicators: []
      }

      u2 = %Uncertainty{
        topic: "test2",
        confidence: :medium,
        score: 0.5,
        evidence_count: 2,
        sources: [],
        staleness: 0.0,
        gap_indicators: []
      }

      alternatives = [
        {"Option A does X", u1},
        {"Option B does Y", u2}
      ]

      formatted = CalibratedResponse.format_alternatives(alternatives)

      assert String.contains?(formatted, "Option 1")
      assert String.contains?(formatted, "Option 2")
      assert String.contains?(formatted, "Option A does X")
      assert String.contains?(formatted, "Option B does Y")
    end
  end
end
