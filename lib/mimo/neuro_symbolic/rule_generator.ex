defmodule Mimo.NeuroSymbolic.RuleGenerator do
  @moduledoc """
  LLM-driven rule discovery for neuro-symbolic inference.

  This module provides a lightweight wrapper around Mimo.Brain.LLM to
  generate candidate rules and parse them into structured forms.
  """
  alias Mimo.Brain.LLM
  alias Mimo.NeuroSymbolic.Rule
  alias Mimo.NeuroSymbolic.RuleValidator
  alias Mimo.Repo
  require Logger

  @doc """
  Generate candidate rules for a given prompt and optional examples.

  Returns: {:ok, list_of_rule_maps} | {:error, reason}
  """
  def generate_rules(prompt, opts \\ []) when is_binary(prompt) do
    max_rules = Keyword.get(opts, :max_rules, 5)

    llm_prompt = build_prompt(prompt, max_rules, opts)

    case LLM.complete(llm_prompt, format: :json, max_tokens: 800, provider: :auto) do
      {:ok, response} ->
        parse_rules_from_response(response)

      {:error, reason} ->
        Logger.error("LLM rule generation failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Generate rules and optionally validate & persist validated rules.

  If `:persist_validated` is true in `opts`, validated rules are saved to the database.
  Returns: {:ok, %{candidates: [...], persisted: [...]}} | {:error, reason}
  """
  def generate_and_persist_rules(prompt, opts \\ []) when is_binary(prompt) do
    case generate_rules(prompt, opts) do
      {:ok, candidates} -> validate_and_persist(candidates, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Validate and optionally persist a list of candidate rules.

  Returns: {:ok, %{candidates: [...], persisted: [...], others: [...]}}
  """
  def validate_and_persist(candidates, opts \\ []) when is_list(candidates) do
    persist_validated = Keyword.get(opts, :persist_validated, false)
    persist_rejected = Keyword.get(opts, :persist_rejected, false)

    {persisted, others} =
      Enum.reduce(candidates, {[], []}, fn candidate, {acc_persisted, acc_other} ->
        case RuleValidator.validate_rule(candidate) do
          {:ok, %{validated: true} = v} ->
            if persist_validated do
              attrs =
                Map.merge(candidate, %{
                  premise:
                    Jason.encode!(Map.get(candidate, :premise) || Map.get(candidate, "premise")),
                  conclusion:
                    Jason.encode!(
                      Map.get(candidate, :conclusion) || Map.get(candidate, "conclusion")
                    ),
                  validation_status: "validated",
                  validation_evidence: v.evidence,
                  confidence: v.precision
                })

              changeset = Rule.changeset(%Rule{}, attrs)

              case Repo.insert(changeset) do
                {:ok, struct} ->
                  {[struct | acc_persisted], acc_other}

                {:error, cs} ->
                  Logger.error("Failed to persist rule: #{inspect(cs)}")
                  {acc_persisted, [Map.put(candidate, :validation, v) | acc_other]}
              end
            else
              {acc_persisted, [Map.put(candidate, :validation, v) | acc_other]}
            end

          {:ok, %{validated: false} = v} ->
            if persist_rejected do
              attrs =
                Map.merge(candidate, %{
                  premise:
                    Jason.encode!(Map.get(candidate, :premise) || Map.get(candidate, "premise")),
                  conclusion:
                    Jason.encode!(
                      Map.get(candidate, :conclusion) || Map.get(candidate, "conclusion")
                    ),
                  validation_status: "rejected",
                  validation_evidence: v.evidence,
                  confidence: v.precision
                })

              changeset = Rule.changeset(%Rule{}, attrs)

              case Repo.insert(changeset) do
                {:ok, struct} ->
                  {[struct | acc_persisted], acc_other}

                {:error, cs} ->
                  Logger.error("Failed to persist rejected rule: #{inspect(cs)}")
                  {acc_persisted, [Map.put(candidate, :validation, v) | acc_other]}
              end
            else
              {acc_persisted, [Map.put(candidate, :validation, v) | acc_other]}
            end

          {:error, reason} ->
            # Validation failed due to invalid structure - log and skip
            Logger.warning(
              "Rule validation failed: #{inspect(reason)}, candidate: #{inspect(Map.keys(candidate))}"
            )

            {acc_persisted, [Map.put(candidate, :validation_error, reason) | acc_other]}
        end
      end)

    {:ok,
     %{candidates: candidates, persisted: Enum.reverse(persisted), others: Enum.reverse(others)}}
  end

  defp build_prompt(prompt, max_rules, _opts) do
    """
    Generate up to #{max_rules} candidate inference rules in JSON format.

    Each rule must contain fields: premise (string), conclusion (string), logical_form (map), confidence (float 0.0-1.0)

    Provide the output as a JSON list.

    Prompt: #{prompt}
    """
  end

  defp parse_rules_from_response(response) do
    case Jason.decode(response) do
      {:ok, %{} = map} ->
        # Single object - wrap in list for uniformity
        {:ok, [normalize_candidate(map)]}

      {:ok, list} when is_list(list) ->
        {:ok, Enum.map(list, &normalize_candidate/1)}

      {:error, _} ->
        # Fallback: try each line as JSON
        response
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.reduce([], fn line, acc ->
          case Jason.decode(line) do
            {:ok, candidate} -> [normalize_candidate(candidate) | acc]
            _ -> acc
          end
        end)
        |> case do
          [] -> {:error, :parse_failed}
          list -> {:ok, Enum.reverse(list)}
        end
    end
  end

  defp normalize_candidate(candidate) when is_map(candidate) do
    %{
      id: Map.get(candidate, "id") || Ecto.UUID.generate(),
      premise: Map.get(candidate, "premise") || Map.get(candidate, :premise),
      conclusion: Map.get(candidate, "conclusion") || Map.get(candidate, :conclusion),
      logical_form: Map.get(candidate, "logical_form") || Map.get(candidate, :logical_form) || %{},
      confidence: Map.get(candidate, "confidence") || Map.get(candidate, :confidence) || 0.5,
      source: Map.get(candidate, "source") || Map.get(candidate, :source) || "llm_generated"
    }
  end
end
