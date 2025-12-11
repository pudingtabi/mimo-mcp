defmodule Mimo.NeuroSymbolic.RuleValidatorTest do
  use Mimo.DataCase, async: true

  alias Mimo.NeuroSymbolic.RuleValidator
  alias Mimo.SemanticStore.Repository

  describe "validate_rule/1" do
    test "validates transitive rules when premise leads to conclusion" do
      # Insert chain: a -> b, b -> c
      Repository.store_triple("a", "reports_to", "b", confidence: 1.0)
      Repository.store_triple("b", "reports_to", "c", confidence: 1.0)

      candidate = %{
        premise: [
          %{"predicate" => "reports_to"}
        ],
        conclusion: %{"predicate" => "reports_to"}
      }

      {:ok, result} = RuleValidator.validate_rule(candidate)
      assert is_map(result)
      assert result.precision >= 0.0
      assert result.validated == true
    end

    test "returns false on invalid rule when no evidence" do
      candidate = %{
        premise: [%{"predicate" => "nonexistent_pred"}],
        conclusion: %{"predicate" => "something_else"}
      }

      {:ok, result} = RuleValidator.validate_rule(candidate)
      assert result.validated == false
    end
  end
end
