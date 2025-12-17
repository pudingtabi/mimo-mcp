defmodule Mimo.Cognitive.UncertaintyTest do
  use ExUnit.Case, async: true
  alias Mimo.Cognitive.Uncertainty

  describe "new/1" do
    test "creates uncertainty struct with topic" do
      u = Uncertainty.new("authentication")

      assert u.topic == "authentication"
      assert u.confidence == :unknown
      assert u.score == 0.0
      assert u.evidence_count == 0
      assert u.sources == []
    end
  end

  describe "to_confidence_level/1" do
    test "converts high scores to :high" do
      assert Uncertainty.to_confidence_level(0.7) == :high
      assert Uncertainty.to_confidence_level(0.85) == :high
      assert Uncertainty.to_confidence_level(1.0) == :high
    end

    test "converts medium scores to :medium" do
      assert Uncertainty.to_confidence_level(0.4) == :medium
      assert Uncertainty.to_confidence_level(0.5) == :medium
      assert Uncertainty.to_confidence_level(0.69) == :medium
    end

    test "converts low scores to :low" do
      assert Uncertainty.to_confidence_level(0.2) == :low
      assert Uncertainty.to_confidence_level(0.3) == :low
      assert Uncertainty.to_confidence_level(0.39) == :low
    end

    test "converts very low scores to :unknown" do
      assert Uncertainty.to_confidence_level(0.0) == :unknown
      assert Uncertainty.to_confidence_level(0.1) == :unknown
      assert Uncertainty.to_confidence_level(0.19) == :unknown
    end

    test "handles integer scores" do
      assert Uncertainty.to_confidence_level(1) == :high
      assert Uncertainty.to_confidence_level(0) == :unknown
    end
  end

  describe "from_assessment/4" do
    test "creates uncertainty from score and sources" do
      sources = [
        %{type: :memory, id: "1", name: "test", relevance: 0.8},
        %{type: :code, id: "2", name: "func", relevance: 0.7}
      ]

      u = Uncertainty.from_assessment("topic", 0.75, sources)

      assert u.topic == "topic"
      assert u.confidence == :high
      assert u.score == 0.75
      assert u.evidence_count == 2
      assert length(u.sources) == 2
      assert u.last_verified != nil
    end

    test "applies staleness penalty" do
      sources = [%{type: :memory, id: "1", name: "test", relevance: 0.8}]

      u = Uncertainty.from_assessment("topic", 0.7, sources, staleness: 0.5)

      # 0.7 * (1.0 - 0.5 * 0.3) = 0.7 * 0.85 = 0.595
      assert u.score < 0.7
      assert u.confidence == :medium
    end

    test "includes gap indicators" do
      sources = []
      gaps = ["missing docs", "no code found"]

      u = Uncertainty.from_assessment("topic", 0.3, sources, gap_indicators: gaps)

      assert u.gap_indicators == gaps
    end
  end

  describe "merge/1" do
    test "returns nil for empty list" do
      assert Uncertainty.merge([]) == nil
    end

    test "returns single item unchanged" do
      u = Uncertainty.new("test")
      assert Uncertainty.merge([u]) == u
    end

    test "merges multiple assessments" do
      u1 =
        Uncertainty.from_assessment("topic1", 0.8, [
          %{type: :memory, id: "1", name: "m1", relevance: 0.9}
        ])

      u2 =
        Uncertainty.from_assessment("topic2", 0.6, [
          %{type: :code, id: "2", name: "c1", relevance: 0.7},
          %{type: :code, id: "3", name: "c2", relevance: 0.6}
        ])

      merged = Uncertainty.merge([u1, u2])

      assert merged.evidence_count == 3
      assert length(merged.sources) == 3
      assert String.contains?(merged.topic, "topic1")
      assert String.contains?(merged.topic, "topic2")
    end
  end

  describe "has_gap?/1" do
    test "returns true for unknown confidence" do
      u = Uncertainty.new("test")
      assert Uncertainty.has_gap?(u) == true
    end

    test "returns true for low confidence" do
      u = Uncertainty.from_assessment("test", 0.25, [])
      assert Uncertainty.has_gap?(u) == true
    end

    test "returns true for sparse evidence" do
      u =
        Uncertainty.from_assessment("test", 0.7, [
          %{type: :memory, id: "1", name: "m1", relevance: 0.8}
        ])

      assert Uncertainty.has_gap?(u) == true
    end

    test "returns true when gap indicators present" do
      u =
        Uncertainty.from_assessment(
          "test",
          0.8,
          [
            %{type: :memory, id: "1", name: "m1", relevance: 0.8},
            %{type: :code, id: "2", name: "c1", relevance: 0.7},
            %{type: :graph, id: "3", name: "g1", relevance: 0.6}
          ],
          gap_indicators: ["missing library docs"]
        )

      assert Uncertainty.has_gap?(u) == true
    end

    test "returns false for high confidence with multiple sources" do
      u =
        Uncertainty.from_assessment("test", 0.8, [
          %{type: :memory, id: "1", name: "m1", relevance: 0.8},
          %{type: :code, id: "2", name: "c1", relevance: 0.7},
          %{type: :graph, id: "3", name: "g1", relevance: 0.6}
        ])

      assert Uncertainty.has_gap?(u) == false
    end
  end

  describe "summary/1" do
    test "generates human-readable summary" do
      u =
        Uncertainty.from_assessment("authentication", 0.75, [
          %{type: :memory, id: "1", name: "m1", relevance: 0.8},
          %{type: :code, id: "2", name: "c1", relevance: 0.7}
        ])

      summary = Uncertainty.summary(u)

      assert String.contains?(summary, "authentication")
      assert String.contains?(summary, "High confidence")
      assert String.contains?(summary, "2 sources")
    end

    test "includes gap indicators in summary" do
      u = Uncertainty.from_assessment("test", 0.4, [], gap_indicators: ["missing docs"])

      summary = Uncertainty.summary(u)

      assert String.contains?(summary, "Gaps: missing docs")
    end
  end
end
