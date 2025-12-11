defmodule Mimo.NeuroSymbolic.RuleGeneratorTest do
  use Mimo.DataCase

  alias Mimo.NeuroSymbolic.RuleGenerator
  alias Mimo.NeuroSymbolic.Rule
  alias Mimo.SemanticStore.Repository
  alias Mimo.Repo

  describe "validate_and_persist/2" do
    test "persists validated rules when persist_validated is true" do
      # Ensure premise and conclusion predicates exist in the store with similar counts
      for i <- 1..10 do
        Repository.store_triple("user_#{i}", "p_friend", "obj_#{i}")
        Repository.store_triple("user_#{i}", "p_likes", "item_#{i}")
      end

      candidate = %{
        id: Ecto.UUID.generate(),
        premise: [%{predicate: "p_friend"}],
        conclusion: %{predicate: "p_likes"},
        logical_form: %{},
        confidence: 0.9,
        source: "test"
      }

      assert {:ok, %{persisted: persisted, candidates: _}} =
               RuleGenerator.validate_and_persist([candidate], persist_validated: true)

      assert length(persisted) == 1
      persisted_rule = hd(persisted)
      assert persisted_rule.validation_status == "validated"
      assert Repo.get(Rule, persisted_rule.id)
    end

    test "persists rejected rules when persist_rejected is true" do
      # Ensure premise predicate exists but conclusion predicate does not
      for i <- 1..10 do
        Repository.store_triple("user_#{i}", "prem_only", "x_#{i}")
      end

      candidate = %{
        id: Ecto.UUID.generate(),
        premise: [%{predicate: "prem_only"}],
        conclusion: %{predicate: "conclusion_not_present"},
        logical_form: %{},
        confidence: 0.1,
        source: "test"
      }

      assert {:ok, %{persisted: persisted, candidates: _}} =
               RuleGenerator.validate_and_persist([candidate], persist_rejected: true)

      assert length(persisted) == 1
      persisted_rule = hd(persisted)
      assert persisted_rule.validation_status == "rejected"
    end
  end
end
