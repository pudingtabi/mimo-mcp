defmodule Mimo.Tools.Dispatchers.Verify do
  @moduledoc """
  Verify tool dispatcher.

  Handles executable verification operations:
  - count: Count letters, words, or characters with actual enumeration
  - math: Verify arithmetic by evaluating expressions
  - logic: Check logical consistency
  - compare: Compare two values with explicit relation
  - self_check: Framework for independent re-derivation

  Based on AI Intelligence Test recommendations (SPEC-AI-TEST):
  Eliminates gap between "ceremonial verification" (claiming to verify)
  and "executable verification" (actually running checks).
  """

  alias Mimo.Skills.Verify

  @doc """
  Dispatch verify operation based on args.
  """
  def dispatch(args) do
    operation = String.to_atom(args["operation"] || "count")

    case operation do
      :count ->
        dispatch_count(args)

      :math ->
        dispatch_math(args)

      :logic ->
        dispatch_logic(args)

      :compare ->
        dispatch_compare(args)

      :self_check ->
        dispatch_self_check(args)

      _ ->
        {:error,
         "Unknown verify operation: #{args["operation"]}. Available: count, math, logic, compare, self_check"}
    end
  end

  # ==========================================================================
  # OPERATION DISPATCHERS
  # ==========================================================================

  defp dispatch_count(args) do
    text = args["text"]
    type = args["type"]
    target = args["target"]

    cond do
      is_nil(text) or text == "" ->
        {:error, "text parameter is required for count operation"}

      is_nil(type) or type == "" ->
        {:error, "type parameter is required (letter/word/character)"}

      type == "letter" and (is_nil(target) or target == "") ->
        {:error, "target parameter is required when counting letters"}

      true ->
        params = %{
          operation: :count,
          text: text,
          type: type
        }

        params = if type == "letter", do: Map.put(params, :target, target), else: params

        case Verify.verify(params) do
          {:ok, result} ->
            {:ok, Map.put(result, :message, "Count verification completed")}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp dispatch_math(args) do
    expression = args["expression"]
    claimed = args["claimed_result"]

    cond do
      is_nil(expression) or expression == "" ->
        {:error, "expression parameter is required for math verification"}

      is_nil(claimed) ->
        {:error, "claimed_result parameter is required for math verification"}

      true ->
        case Verify.verify(%{
               operation: :math,
               expression: expression,
               claimed_result: claimed
             }) do
          {:ok, result} ->
            message =
              if result.match do
                "✅ Math verification PASSED: #{expression} = #{result.actual} (claimed: #{claimed})"
              else
                "❌ Math verification FAILED: #{expression} = #{result.actual} (claimed: #{claimed}, discrepancy: #{result.discrepancy})"
              end

            {:ok, Map.put(result, :message, message)}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp dispatch_logic(args) do
    statements = args["statements"]
    claim = args["claim"]

    cond do
      is_nil(statements) or not is_list(statements) ->
        {:error, "statements parameter (list) is required for logic verification"}

      is_nil(claim) or claim == "" ->
        {:error, "claim parameter is required for logic verification"}

      true ->
        case Verify.verify(%{
               operation: :logic,
               statements: statements,
               claim: claim
             }) do
          {:ok, result} ->
            message =
              cond do
                result.has_contradictions ->
                  "⚠️ Logic verification: Contradictions detected in premises!"

                result.claim_entailed ->
                  "✅ Logic verification: Claim appears consistent with statements"

                true ->
                  "⚠️ Logic verification: Claim not clearly entailed by statements"
              end

            {:ok, Map.put(result, :message, message)}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp dispatch_compare(args) do
    value_a = args["value_a"]
    value_b = args["value_b"]
    relation = args["relation"]

    cond do
      is_nil(value_a) ->
        {:error, "value_a parameter is required for compare verification"}

      is_nil(value_b) ->
        {:error, "value_b parameter is required for compare verification"}

      is_nil(relation) or relation == "" ->
        {:error, "relation parameter is required (greater/less/equal/greater_equal/less_equal)"}

      true ->
        case Verify.verify(%{
               operation: :compare,
               value_a: value_a,
               value_b: value_b,
               relation: relation
             }) do
          {:ok, result} ->
            message =
              if result.result do
                "✅ Compare verification PASSED: #{result.description}"
              else
                "❌ Compare verification FAILED: #{result.description}"
              end

            {:ok, Map.put(result, :message, message)}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp dispatch_self_check(args) do
    problem = args["problem"]
    claimed_answer = args["claimed_answer"]

    cond do
      is_nil(problem) or problem == "" ->
        {:error, "problem parameter is required for self-check verification"}

      is_nil(claimed_answer) ->
        {:error, "claimed_answer parameter is required for self-check verification"}

      true ->
        case Verify.verify(%{
               operation: :self_check,
               problem: problem,
               claimed_answer: claimed_answer
             }) do
          {:ok, result} ->
            {:ok,
             Map.put(
               result,
               :message,
               "Self-check framework ready. Follow recommended workflow to independently verify."
             )}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end
end
