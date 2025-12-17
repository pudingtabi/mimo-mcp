defmodule Mimo.Cognitive.GapDetectorTest do
  use Mimo.DataCase, async: false
  alias Mimo.Cognitive.{GapDetector, Uncertainty}

  describe "analyze/2" do
    test "returns gap analysis map" do
      analysis = GapDetector.analyze("test query")

      assert is_map(analysis)
      assert Map.has_key?(analysis, :gap_type)
      assert Map.has_key?(analysis, :severity)
      assert Map.has_key?(analysis, :suggestion)
      assert Map.has_key?(analysis, :actions)
      assert Map.has_key?(analysis, :details)
    end

    test "gap_type is valid" do
      analysis = GapDetector.analyze("unknown topic xyz123")

      assert analysis.gap_type in [
               :no_knowledge,
               :weak_knowledge,
               :sparse_evidence,
               :stale_knowledge,
               :partial_coverage,
               :none
             ]
    end

    test "severity is valid" do
      analysis = GapDetector.analyze("test")

      assert analysis.severity in [:critical, :moderate, :minor, :none]
    end

    test "actions is a list" do
      analysis = GapDetector.analyze("test")

      assert is_list(analysis.actions)

      assert Enum.all?(analysis.actions, fn a ->
               a in [
                 :ask_user,
                 :search_external,
                 :search_codebase,
                 :present_with_caveat,
                 :proceed_normally,
                 :research_library
               ]
             end)
    end
  end

  describe "analyze_uncertainty/1" do
    test "detects no_knowledge gap for unknown confidence with no evidence" do
      uncertainty = %Uncertainty{
        topic: "test",
        confidence: :unknown,
        score: 0.0,
        evidence_count: 0,
        sources: [],
        gap_indicators: []
      }

      analysis = GapDetector.analyze_uncertainty(uncertainty)

      assert analysis.gap_type == :no_knowledge
      assert analysis.severity == :critical
      assert :ask_user in analysis.actions
    end

    test "detects weak_knowledge gap for low confidence" do
      uncertainty = %Uncertainty{
        topic: "test",
        confidence: :low,
        score: 0.25,
        evidence_count: 1,
        sources: [%{type: :memory, id: "1", name: "m", relevance: 0.4}],
        gap_indicators: []
      }

      analysis = GapDetector.analyze_uncertainty(uncertainty)

      assert analysis.gap_type == :weak_knowledge
      assert analysis.severity in [:critical, :moderate]
    end

    test "detects sparse_evidence for limited sources" do
      uncertainty = %Uncertainty{
        topic: "test",
        confidence: :medium,
        score: 0.5,
        evidence_count: 2,
        sources: [
          %{type: :memory, id: "1", name: "m1", relevance: 0.6},
          %{type: :memory, id: "2", name: "m2", relevance: 0.5}
        ],
        staleness: 0.1,
        gap_indicators: []
      }

      analysis = GapDetector.analyze_uncertainty(uncertainty)

      assert analysis.gap_type == :sparse_evidence
      assert analysis.severity == :minor
    end

    test "detects stale_knowledge for high staleness" do
      uncertainty = %Uncertainty{
        topic: "test",
        confidence: :medium,
        score: 0.5,
        evidence_count: 5,
        sources: [],
        staleness: 0.6,
        gap_indicators: []
      }

      analysis = GapDetector.analyze_uncertainty(uncertainty)

      assert analysis.gap_type == :stale_knowledge
    end

    test "returns none for high confidence" do
      uncertainty = %Uncertainty{
        topic: "test",
        confidence: :high,
        score: 0.8,
        evidence_count: 5,
        sources: [
          %{type: :memory, id: "1", name: "m1", relevance: 0.9},
          %{type: :code, id: "2", name: "c1", relevance: 0.8},
          %{type: :graph, id: "3", name: "g1", relevance: 0.7},
          %{type: :library, id: "4", name: "l1", relevance: 0.8},
          %{type: :memory, id: "5", name: "m2", relevance: 0.85}
        ],
        staleness: 0.1,
        gap_indicators: []
      }

      analysis = GapDetector.analyze_uncertainty(uncertainty)

      assert analysis.gap_type == :none
      assert analysis.severity == :none
      assert :proceed_normally in analysis.actions
    end
  end

  describe "requires_user_input?/1" do
    test "returns true when ask_user is in actions" do
      analysis = %{actions: [:ask_user, :search_external]}
      assert GapDetector.requires_user_input?(analysis) == true
    end

    test "returns false when ask_user not in actions" do
      analysis = %{actions: [:proceed_normally]}
      assert GapDetector.requires_user_input?(analysis) == false
    end
  end

  describe "researchable?/1" do
    test "returns true for search_external" do
      analysis = %{actions: [:search_external]}
      assert GapDetector.researchable?(analysis) == true
    end

    test "returns true for research_library" do
      analysis = %{actions: [:research_library]}
      assert GapDetector.researchable?(analysis) == true
    end

    test "returns false for proceed_normally only" do
      analysis = %{actions: [:proceed_normally]}
      assert GapDetector.researchable?(analysis) == false
    end
  end

  describe "primary_action/1" do
    test "returns first action" do
      analysis = %{actions: [:search_external, :ask_user]}
      assert GapDetector.primary_action(analysis) == :search_external
    end

    test "returns proceed_normally for empty actions" do
      analysis = %{actions: []}
      assert GapDetector.primary_action(analysis) == :proceed_normally
    end
  end

  describe "detect_gap_patterns/1" do
    test "detects library references" do
      patterns = GapDetector.detect_gap_patterns("How do I use the phoenix library?")

      assert Enum.any?(patterns, fn p -> p.type == :library_reference end)
    end

    test "detects code references" do
      patterns = GapDetector.detect_gap_patterns("What does this function do?")

      assert Enum.any?(patterns, fn p -> p.type == :code_reference end)
    end

    test "detects how-to questions" do
      patterns = GapDetector.detect_gap_patterns("How do I implement authentication?")

      assert Enum.any?(patterns, fn p -> p.type == :how_to_question end)
    end

    test "detects recency requirements" do
      patterns = GapDetector.detect_gap_patterns("What's the latest version of Elixir?")

      assert Enum.any?(patterns, fn p -> p.type == :recency_required end)
    end
  end

  describe "generate_research_plan/1" do
    test "returns empty list for no gap" do
      analysis = %{gap_type: :none, actions: [:proceed_normally], details: %{}}

      plan = GapDetector.generate_research_plan(analysis)

      assert plan == []
    end

    test "generates plan for gaps" do
      analysis = %{
        gap_type: :weak_knowledge,
        actions: [:search_external, :research_library],
        details: %{confidence: :low}
      }

      plan = GapDetector.generate_research_plan(analysis)

      assert length(plan) == 2

      assert Enum.all?(plan, fn item ->
               Map.has_key?(item, :action) and
                 Map.has_key?(item, :priority) and
                 Map.has_key?(item, :description)
             end)
    end
  end
end
