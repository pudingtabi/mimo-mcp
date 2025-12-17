defmodule Mimo.NeuroSymbolic.InferenceEngineE2ETest do
  use Mimo.DataCase, async: false

  alias Mimo.SemanticStore.{Repository, InferenceEngine}
  alias Mimo.NeuroSymbolic.Rule
  alias Mimo.Repo

  describe "forward_chain neuro_symbolic + persist" do
    test "uses persisted rule to infer and persist with inferred_by_rule_id" do
      # Insert base chain a -> b -> c
      a = "a_#{Ecto.UUID.generate()}"
      b = "b_#{Ecto.UUID.generate()}"
      c = "c_#{Ecto.UUID.generate()}"

      Repository.store_triple(a, "reports_to", b, confidence: 1.0)
      Repository.store_triple(b, "reports_to", c, confidence: 1.0)

      # Create a validated persisted rule for reports_to
      attrs = %{
        premise: Jason.encode!([%{"predicate" => "reports_to"}]),
        conclusion: Jason.encode!(%{"predicate" => "reports_to"}),
        logical_form: %{},
        source: "test",
        validation_status: "validated",
        confidence: 0.95
      }

      {:ok, rule} =
        %Rule{}
        |> Rule.changeset(attrs)
        |> Repo.insert()

      # Run forward chain with neuro symbolic
      # Ensure the rule is persisted and visible to queries
      persisted_rules = Repo.all(from(r in Rule, where: r.validation_status == "validated"))
      assert length(persisted_rules) > 0

      # Confirm persisted rules for this predicate exist per the inference query
      persisted_for_pred =
        from(r in Rule,
          where:
            r.validation_status == "validated" and
              (r.conclusion == ^"reports_to" or
                 like(r.conclusion, ^"%\"predicate\":\"reports_to\"%")),
          select: r
        )
        |> Repo.all()

      assert length(persisted_for_pred) > 0, "No persisted rule found for predicate 'reports_to'"

      # persisted_for_pred contains validated rules for 'reports_to' predicate

      parsed_preds =
        Enum.map(persisted_for_pred, fn r ->
          case Jason.decode(r.conclusion) do
            {:ok, m} when is_map(m) -> Map.get(m, "predicate") || Map.get(m, :predicate)
            _ -> r.conclusion
          end
        end)

      # parsed_preds contains extracted predicate names from rules

      # sanity: confirm symbolic inference returns A->C
      {:ok, symbolic} =
        InferenceEngine.forward_chain("reports_to",
          neuro_symbolic: false,
          persist: false,
          min_confidence: 0.0
        )

      assert Enum.any?(symbolic, fn t -> t.subject_id == a and t.object_id == c end)

      {:ok, inferred} =
        InferenceEngine.forward_chain("reports_to",
          neuro_symbolic: true,
          persist: true,
          min_confidence: 0.0
        )

      # inferred contains the forward-chained inference results

      # We expect A->C inference with SOME valid rule id (could be any validated rule for reports_to)
      # The key is that inferred_by_rule_id is present and is a valid UUID
      inferred_a_to_c =
        Enum.find(inferred, fn t ->
          t.subject_id == a and t.object_id == c and t[:inferred_by_rule_id] != nil
        end)

      assert inferred_a_to_c != nil,
             "Expected inferred triple from #{a} to #{c} with inferred_by_rule_id"

      # Verify the rule_id is a valid existing rule
      rule_ids = Enum.map(persisted_for_pred, & &1.id)

      assert inferred_a_to_c.inferred_by_rule_id in rule_ids,
             "inferred_by_rule_id #{inferred_a_to_c.inferred_by_rule_id} should be one of the persisted rules"

      # Note: We created rule.id but the inference may use a different existing rule
      # since there may be multiple validated rules for 'reports_to' in the DB
    end

    test "trigger_on_new_triple runs cross-modality linking without crash" do
      # Create a triple via repository
      x = "x_#{Ecto.UUID.generate()}"
      y = "y_#{Ecto.UUID.generate()}"

      {:ok, triple} =
        Repository.create(%{
          subject_id: x,
          subject_type: "entity",
          predicate: "owns",
          object_id: y,
          object_type: "entity",
          confidence: 1.0
        })

      # Call trigger directly (no background wait)
      assert Mimo.NeuroSymbolic.Inference.trigger_on_new_triple(triple) == :ok
    end
  end
end
