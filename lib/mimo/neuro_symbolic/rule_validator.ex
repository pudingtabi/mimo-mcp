defmodule Mimo.NeuroSymbolic.RuleValidator do
  @moduledoc """
  Validates LLM-generated rules against existing triples in the semantic store.

  This module computes simple precision/recall metrics by looking up whether premises
  lead to conclusions in the knowledge graph. This is intentionally basic for Phase 1
  and should be extended to support rigorous ground-truth checks.
  """
  require Logger
  alias Mimo.SemanticStore.Repository

  @doc """
  Validate a candidate rule.

  Input: rule_map with keys :premise (list of triple patterns), :conclusion (map/string), :id, :confidence
  Output: {:ok, %{validated: boolean, precision: float(), recall: float(), evidence: []}}
  """
  def validate_rule(%{premise: premise, conclusion: conclusion} = _rule) do
    # For Phase 1: find counts of premise predicate occurrences and conclusion predicate occurrences
    premise_preds = extract_predicates_from_premise(premise)
    conclusion_pred = extract_predicate_from_conclusion(conclusion)

    premise_count = count_triples_for_predicates(premise_preds)
    conclusion_count = count_triples_for_predicates([conclusion_pred])

    precision = if premise_count > 0, do: min(1.0, conclusion_count / premise_count), else: 0.0

    # Simple heuristic: validated if precision >= 0.9
    validated = precision >= 0.9

    evidence = %{
      premise_count: premise_count,
      conclusion_count: conclusion_count
    }

    {:ok, %{validated: validated, precision: precision, recall: 0.0, evidence: evidence}}
  end
  
  # Fallback for rules missing required keys
  def validate_rule(rule) when is_map(rule) do
    {:error, {:invalid_rule, :missing_required_keys, Map.keys(rule)}}
  end
  
  def validate_rule(_), do: {:error, {:invalid_rule, :not_a_map}}

  defp extract_predicates_from_premise(nil), do: []
  
  defp extract_predicates_from_premise(premise) when is_list(premise) do
    premise
    |> Enum.map(fn
      %{"predicate" => p} -> p
      %{predicate: p} -> p
      {_, p, _} when is_binary(p) -> p
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end
  
  defp extract_predicates_from_premise(_), do: []

  defp extract_predicate_from_conclusion(nil), do: nil
  
  defp extract_predicate_from_conclusion(conclusion) when is_map(conclusion) do
    Map.get(conclusion, "predicate") || Map.get(conclusion, :predicate)
  end
  
  defp extract_predicate_from_conclusion(_), do: nil

  defp count_triples_for_predicates(preds) when is_list(preds) do
    preds
    |> Enum.reject(&is_nil/1)  # Filter out nil predicates
    |> Enum.map(&Repository.get_by_predicate(&1, limit: 1))
    |> Enum.map(&length/1)
    |> Enum.sum()
  end
end
