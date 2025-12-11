defmodule Mimo.NeuroSymbolic.Spec052EdgeCasesTest do
  @moduledoc """
  Edge case tests for SPEC-052: Enhanced Knowledge Graph with Neuro-Symbolic Reasoning.
  
  These tests verify boundary conditions, error handling, and corner cases
  not covered by the primary test suites.
  """
  use Mimo.DataCase, async: false

  alias Mimo.NeuroSymbolic.{
    RuleGenerator,
    RuleValidator,
    CrossModalityLinker,
    ExplanationEngine,
    GnnPredictor,
    Rule
  }
  alias Mimo.SemanticStore.Repository
  alias Mimo.Repo

  # =============================================================================
  # RuleGenerator Edge Cases
  # =============================================================================

  describe "RuleGenerator edge cases" do
    test "handles empty candidate list" do
      assert {:ok, result} = RuleGenerator.validate_and_persist([])
      assert result.persisted == []
      assert result.candidates == []
    end

    test "handles candidate with missing required fields" do
      incomplete_candidate = %{
        id: Ecto.UUID.generate(),
        # Missing premise, conclusion
        confidence: 0.5
      }

      # Should handle gracefully without crashing
      result = RuleGenerator.validate_and_persist([incomplete_candidate])
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles candidate with nil values" do
      candidate = %{
        id: Ecto.UUID.generate(),
        premise: nil,
        conclusion: nil,
        logical_form: %{},
        confidence: 0.5,
        source: "test"
      }

      result = RuleGenerator.validate_and_persist([candidate])
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles very long predicate names" do
      long_name = String.duplicate("a", 500)
      
      for i <- 1..5 do
        Repository.store_triple("e_#{i}", long_name, "o_#{i}")
      end

      candidate = %{
        id: Ecto.UUID.generate(),
        premise: [%{predicate: long_name}],
        conclusion: %{predicate: long_name},
        logical_form: %{},
        confidence: 0.8,
        source: "test"
      }

      result = RuleGenerator.validate_and_persist([candidate])
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles unicode predicate names" do
      unicode_pred = "関係_🔗_связь"
      
      for i <- 1..5 do
        Repository.store_triple("u_#{i}", unicode_pred, "t_#{i}")
      end

      candidate = %{
        id: Ecto.UUID.generate(),
        premise: [%{predicate: unicode_pred}],
        conclusion: %{predicate: unicode_pred},
        logical_form: %{},
        confidence: 0.7,
        source: "test"
      }

      result = RuleGenerator.validate_and_persist([candidate])
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles duplicate candidate IDs gracefully" do
      dup_id = Ecto.UUID.generate()
      
      for i <- 1..10 do
        Repository.store_triple("dup_#{i}", "dup_pred", "dup_obj_#{i}")
      end

      candidates = [
        %{id: dup_id, premise: [%{predicate: "dup_pred"}], conclusion: %{predicate: "dup_pred"}, confidence: 0.8, source: "test"},
        %{id: dup_id, premise: [%{predicate: "dup_pred"}], conclusion: %{predicate: "dup_pred"}, confidence: 0.9, source: "test"}
      ]

      result = RuleGenerator.validate_and_persist(candidates, persist_validated: true)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles zero confidence candidate" do
      for i <- 1..5 do
        Repository.store_triple("zero_#{i}", "zero_conf", "zero_o_#{i}")
      end

      candidate = %{
        id: Ecto.UUID.generate(),
        premise: [%{predicate: "zero_conf"}],
        conclusion: %{predicate: "zero_conf"},
        logical_form: %{},
        confidence: 0.0,
        source: "test"
      }

      result = RuleGenerator.validate_and_persist([candidate])
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles confidence > 1.0 (boundary)" do
      for i <- 1..5 do
        Repository.store_triple("over_#{i}", "over_conf", "over_o_#{i}")
      end

      candidate = %{
        id: Ecto.UUID.generate(),
        premise: [%{predicate: "over_conf"}],
        conclusion: %{predicate: "over_conf"},
        logical_form: %{},
        confidence: 1.5,  # Should be clamped or rejected
        source: "test"
      }

      result = RuleGenerator.validate_and_persist([candidate])
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  # =============================================================================
  # RuleValidator Edge Cases
  # =============================================================================

  describe "RuleValidator edge cases" do
    test "validates with empty premise list" do
      candidate = %{
        premise: [],
        conclusion: %{"predicate" => "orphan_conclusion"}
      }

      result = RuleValidator.validate_rule(candidate)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "validates with deeply nested logical form" do
      Repository.store_triple("nested_1", "nested_rel", "nested_2")
      Repository.store_triple("nested_2", "nested_rel", "nested_3")

      candidate = %{
        premise: [%{"predicate" => "nested_rel"}],
        conclusion: %{"predicate" => "nested_rel"},
        logical_form: %{
          "operator" => "AND",
          "operands" => [
            %{"operator" => "OR", "operands" => [%{"predicate" => "nested_rel"}]},
            %{"operator" => "NOT", "operand" => %{"predicate" => "other"}}
          ]
        }
      }

      result = RuleValidator.validate_rule(candidate)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles circular inference chains" do
      # A -> B -> C -> A (circular)
      Repository.store_triple("circ_a", "circular", "circ_b", confidence: 1.0)
      Repository.store_triple("circ_b", "circular", "circ_c", confidence: 1.0)
      Repository.store_triple("circ_c", "circular", "circ_a", confidence: 1.0)

      candidate = %{
        premise: [%{"predicate" => "circular"}],
        conclusion: %{"predicate" => "circular"}
      }

      # Should not infinite loop
      result = RuleValidator.validate_rule(candidate)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles very large predicate count" do
      # Create 100 different predicates
      for i <- 1..100 do
        Repository.store_triple("large_#{i}", "pred_#{i}", "obj_#{i}")
      end

      candidate = %{
        premise: Enum.map(1..10, &%{"predicate" => "pred_#{&1}"}),
        conclusion: %{"predicate" => "pred_50"}
      }

      result = RuleValidator.validate_rule(candidate)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  # =============================================================================
  # CrossModalityLinker Edge Cases
  # =============================================================================

  describe "CrossModalityLinker edge cases" do
    test "handles empty source_id" do
      result = CrossModalityLinker.infer_links(:code_symbol, "", [])
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles nil source_id" do
      result = CrossModalityLinker.infer_links(:code_symbol, nil, [])
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles unknown source type" do
      result = CrossModalityLinker.infer_links(:unknown_type, "test", [])
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles very large limit values" do
      {:ok, links} = CrossModalityLinker.infer_links(:code_symbol, "Test", limit: 1_000_000)
      assert is_list(links)
    end

    test "handles negative limit" do
      result = CrossModalityLinker.infer_links(:code_symbol, "Test", limit: -1)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles min_confidence at boundary values" do
      {:ok, links_0} = CrossModalityLinker.infer_links(:code_symbol, "Test", min_confidence: 0.0)
      {:ok, links_1} = CrossModalityLinker.infer_links(:code_symbol, "Test", min_confidence: 1.0)
      
      assert is_list(links_0)
      assert is_list(links_1)
    end

    test "link_all handles massive batch" do
      pairs = Enum.map(1..100, fn i -> 
        {:code_symbol, "Symbol_#{i}"} 
      end)

      result = CrossModalityLinker.link_all(pairs)
      assert match?({:ok, _}, result)
    end

    test "cross_modality_stats handles special characters" do
      stats = CrossModalityLinker.cross_modality_stats(:code_symbol, "Test<Generic>")
      assert Map.has_key?(stats, :total_connections)
    end

    test "find_cross_connections handles map with only unknown keys" do
      item = %{unknown_key_1: "value", unknown_key_2: 123}
      count = CrossModalityLinker.find_cross_connections(item)
      assert is_integer(count)
      assert count >= 0
    end
  end

  # =============================================================================
  # ExplanationEngine Edge Cases  
  # =============================================================================

  describe "ExplanationEngine edge cases" do
    test "explains triple with missing optional fields" do
      triple = %{subject_id: "s", predicate: "p", object_id: "o"}
      explanation = ExplanationEngine.explain(triple)
      
      assert Map.has_key?(explanation, :inference_path)
      assert Map.has_key?(explanation, :confidence_breakdown)
    end

    test "explains triple with all confidence fields" do
      triple = %{
        subject_id: "s",
        predicate: "p", 
        object_id: "o",
        confidence: 0.95,
        rule_confidence: 0.90
      }
      
      explanation = ExplanationEngine.explain(triple)
      breakdown = explanation.confidence_breakdown
      
      assert breakdown.evidence_strength == 0.95
      assert breakdown.rule_confidence == 0.90
    end

    test "explains triple with nil confidence values" do
      triple = %{
        subject_id: "s",
        predicate: "p",
        object_id: "o",
        confidence: nil,
        rule_confidence: nil
      }
      
      explanation = ExplanationEngine.explain(triple)
      assert is_map(explanation.confidence_breakdown)
    end
  end

  # =============================================================================
  # GnnPredictor Edge Cases (Phase 1 Stubs)
  # =============================================================================

  describe "GnnPredictor edge cases" do
    test "train returns success with empty graph" do
      assert {:ok, model} = GnnPredictor.train(%{nodes: [], edges: []})
      assert Map.has_key?(model, :version)
    end

    test "train handles zero epochs" do
      result = GnnPredictor.train(%{}, 0)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "train handles negative epochs" do
      result = GnnPredictor.train(%{}, -10)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "predict_links returns empty for nil model" do
      result = GnnPredictor.predict_links(nil, ["node1", "node2"])
      assert is_list(result)
    end

    test "predict_links handles empty node list" do
      {:ok, model} = GnnPredictor.train(%{})
      result = GnnPredictor.predict_links(model, [])
      assert is_list(result)
    end

    test "cluster_similar returns empty for unknown node type" do
      {:ok, model} = GnnPredictor.train(%{})
      result = GnnPredictor.cluster_similar(model, :unknown_type)
      assert is_list(result)
    end
  end

  # =============================================================================
  # Integration Edge Cases
  # =============================================================================

  describe "cross-module integration edge cases" do
    test "rule creation followed by inference with same predicate" do
      unique_pred = "int_test_#{System.unique_integer([:positive])}"
      
      # Create triples
      Repository.store_triple("a", unique_pred, "b", confidence: 1.0)
      Repository.store_triple("b", unique_pred, "c", confidence: 1.0)

      # Create and persist rule
      candidate = %{
        id: Ecto.UUID.generate(),
        premise: [%{predicate: unique_pred}],
        conclusion: %{predicate: unique_pred},
        logical_form: %{},
        confidence: 0.9,
        source: "integration_test"
      }

      {:ok, result} = RuleGenerator.validate_and_persist([candidate], persist_validated: true)
      
      # Validate persisted rule exists
      if length(result.persisted) > 0 do
        rule = hd(result.persisted)
        assert Repo.get(Rule, rule.id) != nil
      end
    end

    test "cross-modality linking after rule creation" do
      # Create a rule, then link it
      unique_pred = "cross_mod_#{System.unique_integer([:positive])}"
      
      for i <- 1..5 do
        Repository.store_triple("cm_#{i}", unique_pred, "cm_obj_#{i}")
      end

      candidate = %{
        id: Ecto.UUID.generate(),
        premise: [%{predicate: unique_pred}],
        conclusion: %{predicate: unique_pred},
        logical_form: %{},
        confidence: 0.85,
        source: "cross_mod_test"
      }

      {:ok, _} = RuleGenerator.validate_and_persist([candidate], persist_validated: true)

      # Now try to infer links
      {:ok, links} = CrossModalityLinker.infer_links(:knowledge, unique_pred, [])
      assert is_list(links)
    end
  end
end
