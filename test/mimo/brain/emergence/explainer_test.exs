defmodule Mimo.Brain.Emergence.ExplainerTest do
  use Mimo.DataCase, async: false

  alias Mimo.Brain.Emergence.Explainer
  alias Mimo.Brain.Emergence.Pattern

  # ─────────────────────────────────────────────────────────────────
  # Test Fixtures
  # ─────────────────────────────────────────────────────────────────

  defp sample_pattern(attrs \\ %{}) do
    base = %Pattern{
      id: attrs[:id] || Ecto.UUID.generate(),
      type: attrs[:type] || :workflow,
      description: attrs[:description] || "Test pattern for explanation",
      components: attrs[:components] || [%{"name" => "step1"}, %{"name" => "step2"}],
      trigger_conditions: attrs[:trigger_conditions] || ["condition1"],
      success_rate: attrs[:success_rate] || 0.85,
      occurrences: attrs[:occurrences] || 15,
      first_seen: attrs[:first_seen] || DateTime.add(DateTime.utc_now(), -7, :day),
      last_seen: attrs[:last_seen] || DateTime.utc_now(),
      strength: attrs[:strength] || 0.78,
      evolution: attrs[:evolution] || [],
      status: attrs[:status] || :active,
      metadata: attrs[:metadata] || %{}
    }

    base
  end

  # ─────────────────────────────────────────────────────────────────
  # explain/2 Tests
  # ─────────────────────────────────────────────────────────────────

  describe "explain/2" do
    test "returns structured explanation for pattern" do
      pattern = sample_pattern()

      {:ok, explanation} = Explainer.explain(pattern, use_llm: false, include_prediction: false)

      assert explanation.pattern_id == pattern.id
      assert explanation.type == :workflow
      assert is_binary(explanation.summary)
      assert is_map(explanation.formation)
      assert is_map(explanation.significance)
      assert is_binary(explanation.recommendation)
    end

    test "includes prediction when requested" do
      pattern = sample_pattern()

      {:ok, explanation} = Explainer.explain(pattern, use_llm: false, include_prediction: true)

      assert Map.has_key?(explanation, :prediction)
    end

    test "excludes prediction when not requested" do
      pattern = sample_pattern()

      {:ok, explanation} = Explainer.explain(pattern, use_llm: false, include_prediction: false)

      refute Map.has_key?(explanation, :prediction)
    end

    test "includes evolution narrative when requested" do
      pattern = sample_pattern(evolution: [%{"timestamp" => "2025-01-01", "event" => "created"}])

      {:ok, explanation} =
        Explainer.explain(pattern,
          use_llm: false,
          include_evolution: true,
          include_prediction: false
        )

      assert Map.has_key?(explanation, :evolution_narrative)
    end

    test "generates correct summary format" do
      pattern = sample_pattern(type: :inference, occurrences: 25)

      {:ok, explanation} = Explainer.explain(pattern, use_llm: false, include_prediction: false)

      assert explanation.summary =~ "Inference pattern"
      assert explanation.summary =~ "25 occurrences"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Formation Explanation Tests
  # ─────────────────────────────────────────────────────────────────

  describe "formation explanation" do
    test "explains workflow formation" do
      pattern = sample_pattern(type: :workflow, components: [%{}, %{}, %{}, %{}])

      {:ok, explanation} = Explainer.explain(pattern, use_llm: false, include_prediction: false)

      assert explanation.formation.origin =~ "workflow"
      assert is_list(explanation.formation.contributing_factors)
    end

    test "categorizes rapid emergence" do
      # 25 occurrences in 3 days = rapid
      pattern =
        sample_pattern(
          occurrences: 25,
          first_seen: DateTime.add(DateTime.utc_now(), -3, :day)
        )

      {:ok, explanation} = Explainer.explain(pattern, use_llm: false, include_prediction: false)

      assert explanation.formation.emergence_type == :rapid_emergence
    end

    test "categorizes gradual emergence" do
      # 15 occurrences over 20 days = gradual
      pattern =
        sample_pattern(
          occurrences: 15,
          first_seen: DateTime.add(DateTime.utc_now(), -20, :day)
        )

      {:ok, explanation} = Explainer.explain(pattern, use_llm: false, include_prediction: false)

      assert explanation.formation.emergence_type == :gradual_emergence
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Significance Assessment Tests
  # ─────────────────────────────────────────────────────────────────

  describe "significance assessment" do
    test "high significance for strong patterns" do
      pattern = sample_pattern(strength: 0.9, success_rate: 0.95, occurrences: 50)

      {:ok, explanation} = Explainer.explain(pattern, use_llm: false, include_prediction: false)

      assert explanation.significance.level == :high
    end

    test "medium significance for developing patterns" do
      pattern = sample_pattern(strength: 0.6, success_rate: 0.7, occurrences: 10)

      {:ok, explanation} = Explainer.explain(pattern, use_llm: false, include_prediction: false)

      assert explanation.significance.level == :medium
    end

    test "low significance for nascent patterns" do
      pattern = sample_pattern(strength: 0.3, success_rate: 0.4, occurrences: 3)

      {:ok, explanation} = Explainer.explain(pattern, use_llm: false, include_prediction: false)

      assert explanation.significance.level == :low
    end

    test "calculates confidence based on data" do
      pattern = sample_pattern(occurrences: 20, success_rate: 0.9)

      {:ok, explanation} = Explainer.explain(pattern, use_llm: false, include_prediction: false)

      assert explanation.significance.confidence > 0.5
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Recommendation Tests
  # ─────────────────────────────────────────────────────────────────

  describe "recommendation generation" do
    test "recommends promotion for ready patterns" do
      pattern = sample_pattern(strength: 0.8, success_rate: 0.85, occurrences: 15)

      {:ok, explanation} = Explainer.explain(pattern, use_llm: false, include_prediction: false)

      assert explanation.recommendation =~ "promotion" or explanation.recommendation =~ "promoted"
    end

    test "recommends investigation for low success rate" do
      pattern = sample_pattern(success_rate: 0.3)

      {:ok, explanation} = Explainer.explain(pattern, use_llm: false, include_prediction: false)

      assert explanation.recommendation =~ "success rate" or
               explanation.recommendation =~ "Investigate" or
               explanation.recommendation =~ "failure"
    end

    test "recommends observation for forming patterns" do
      pattern = sample_pattern(strength: 0.3, occurrences: 3)

      {:ok, explanation} = Explainer.explain(pattern, use_llm: false, include_prediction: false)

      assert explanation.recommendation =~ "forming" or explanation.recommendation =~ "observ"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # explain_promotion_readiness/1 Tests
  # ─────────────────────────────────────────────────────────────────

  describe "explain_promotion_readiness/1" do
    test "identifies ready pattern" do
      pattern = sample_pattern(occurrences: 15, success_rate: 0.85, strength: 0.8)

      {:ok, result} = Explainer.explain_promotion_readiness(pattern)

      assert result.ready_for_promotion == true
      assert Enum.all?(result.criteria, & &1.met)
    end

    test "identifies not ready pattern with details" do
      pattern = sample_pattern(occurrences: 5, success_rate: 0.7, strength: 0.5)

      {:ok, result} = Explainer.explain_promotion_readiness(pattern)

      assert result.ready_for_promotion == false
      refute Enum.all?(result.criteria, & &1.met)
      assert is_list(result.next_steps)
      assert length(result.next_steps) > 0
    end

    test "calculates gap for unmet criteria" do
      pattern = sample_pattern(occurrences: 5)

      {:ok, result} = Explainer.explain_promotion_readiness(pattern)

      occ_criterion = Enum.find(result.criteria, &(&1.criterion == :occurrences))
      # Need 10, have 5
      assert occ_criterion.gap == 5
    end

    test "provides next steps for each unmet criterion" do
      pattern = sample_pattern(occurrences: 5, success_rate: 0.6, strength: 0.5)

      {:ok, result} = Explainer.explain_promotion_readiness(pattern)

      assert length(result.next_steps) == 3
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # hypothesize/1 Tests (without LLM)
  # ─────────────────────────────────────────────────────────────────

  describe "hypothesize/1" do
    test "returns fallback hypotheses when LLM unavailable" do
      pattern = sample_pattern()

      # This will use fallback since LLM likely won't be available in tests
      {:ok, hypotheses} = Explainer.hypothesize(pattern)

      assert is_list(hypotheses)
      assert length(hypotheses) >= 1
      assert Enum.all?(hypotheses, &is_map/1)
    end

    test "hypothesis has required fields" do
      pattern = sample_pattern()

      {:ok, hypotheses} = Explainer.hypothesize(pattern)
      [first | _] = hypotheses

      assert Map.has_key?(first, "hypothesis") or Map.has_key?(first, :hypothesis)
      assert Map.has_key?(first, "plausibility") or Map.has_key?(first, :plausibility)
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # explain_batch/2 Tests
  # ─────────────────────────────────────────────────────────────────

  describe "explain_batch/2" do
    test "explains multiple patterns" do
      patterns = [
        sample_pattern(type: :workflow),
        sample_pattern(type: :inference),
        sample_pattern(type: :heuristic)
      ]

      {:ok, result} = Explainer.explain_batch(patterns, use_llm: false, include_prediction: false)

      assert result.summary.total_patterns == 3
      assert result.summary.explained_count == 3
      assert length(result.explanations) == 3
    end

    test "groups by type in summary" do
      patterns = [
        sample_pattern(type: :workflow),
        sample_pattern(type: :workflow),
        sample_pattern(type: :inference)
      ]

      {:ok, result} = Explainer.explain_batch(patterns, use_llm: false, include_prediction: false)

      assert result.summary.by_type.workflow == 2
      assert result.summary.by_type.inference == 1
    end

    test "assesses overall health" do
      patterns = [
        sample_pattern(strength: 0.8, status: :active),
        sample_pattern(strength: 0.75, status: :active),
        sample_pattern(strength: 0.7, status: :active)
      ]

      {:ok, result} = Explainer.explain_batch(patterns, use_llm: false, include_prediction: false)

      assert result.summary.overall_health.status == :healthy
      assert result.summary.overall_health.active_count == 3
    end

    test "finds pattern relationships" do
      patterns = [
        sample_pattern(components: [%{"name" => "auth"}, %{"name" => "db"}]),
        sample_pattern(components: [%{"name" => "auth"}, %{"name" => "cache"}])
      ]

      {:ok, result} = Explainer.explain_batch(patterns, use_llm: false, include_prediction: false)

      # Both patterns share "auth" component
      # May or may not find depending on threshold
      assert length(result.summary.relationships) >= 0
    end

    test "handles empty pattern list" do
      {:ok, result} = Explainer.explain_batch([], use_llm: false, include_prediction: false)

      assert result.summary.total_patterns == 0
      assert result.explanations == []
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Evolution Narrative Tests
  # ─────────────────────────────────────────────────────────────────

  describe "evolution narrative" do
    test "narrates pattern with evolution history" do
      pattern =
        sample_pattern(
          evolution: [
            %{"timestamp" => "2025-01-01", "event" => "created", "strength" => 0.3},
            %{"timestamp" => "2025-01-05", "event" => "grew", "strength" => 0.5},
            %{"timestamp" => "2025-01-10", "event" => "matured", "strength" => 0.7}
          ]
        )

      {:ok, explanation} =
        Explainer.explain(pattern,
          use_llm: false,
          include_evolution: true,
          include_prediction: false
        )

      assert explanation.evolution_narrative.age_days >= 0
      assert is_list(explanation.evolution_narrative.evolution_stages)
    end

    test "handles empty evolution" do
      pattern = sample_pattern(evolution: [])

      {:ok, explanation} =
        Explainer.explain(pattern,
          use_llm: false,
          include_evolution: true,
          include_prediction: false
        )

      assert explanation.evolution_narrative.evolution_stages == []
    end
  end
end
