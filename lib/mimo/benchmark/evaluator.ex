defmodule Mimo.Benchmark.Evaluator do
  @moduledoc """
  Answer evaluation helpers for benchmark pipelines (e.g., LOCOMO).

  Supports multiple strategies so callers can trade speed for fidelity:
  - `:exact`     : case-insensitive string match
  - `:semantic`  : embedding cosine similarity
  - `:llm`       : LLM-as-judge with semantic fallback
  """

  alias Mimo.Brain.LLM
  alias Mimo.Vector.Math

  require Logger

  @type strategy :: :exact | :semantic | :llm

  @doc """
  Evaluate a predicted answer against an expected answer.

  Returns `{correct?, score, details}` where `score` is 0.0-1.0.
  """
  @spec evaluate(String.t(), String.t(), strategy(), keyword()) :: {boolean(), float(), map()}
  def evaluate(predicted, expected, strategy \\ :semantic, opts \\ [])

  def evaluate(predicted, expected, :exact, _opts) do
    match? = normalize(predicted) == normalize(expected)

    {match?, if(match?, do: 1.0, else: 0.0),
     %{similarity: if(match?, do: 1.0, else: 0.0), mode: :exact}}
  end

  def evaluate(predicted, expected, :semantic, opts) do
    threshold = Keyword.get(opts, :threshold, 0.7)

    {similarity, details} = semantic_similarity(predicted, expected)
    {similarity >= threshold, similarity, Map.put(details, :mode, :semantic)}
  end

  def evaluate(predicted, expected, :llm, opts) do
    threshold = Keyword.get(opts, :threshold, 0.7)

    case llm_judge(predicted, expected, opts) do
      {:ok, score} ->
        {score >= threshold, score, %{similarity: score, mode: :llm}}

      {:error, reason} ->
        Logger.warning("LLM judge unavailable, falling back to semantic: #{inspect(reason)}")
        evaluate(predicted, expected, :semantic, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp semantic_similarity(predicted, expected) do
    with {:ok, pred_emb} <- LLM.generate_embedding(predicted),
         {:ok, exp_emb} <- LLM.generate_embedding(expected),
         {:ok, similarity} <- Math.cosine_similarity(pred_emb, exp_emb) do
      {similarity, %{similarity: similarity}}
    else
      {:error, reason} ->
        Logger.warning("Semantic similarity failed: #{inspect(reason)}")
        {0.0, %{error: reason, similarity: 0.0}}
    end
  end

  defp llm_judge(predicted, expected, opts) do
    prompt = """
    Judge if the PREDICTED answer correctly answers the EXPECTED answer.

    EXPECTED: #{expected}
    PREDICTED: #{predicted}

    Respond with a JSON object: {"score": 0.0-1.0, "reason": "brief"}
    Score guidance:
    - 1.0 fully correct
    - 0.7 mostly correct with minor omissions
    - 0.5 partially correct
    - 0.0 incorrect or irrelevant
    """

    case LLM.complete(prompt, format: :json, max_tokens: Keyword.get(opts, :max_tokens, 150)) do
      {:ok, resp} ->
        with {:ok, decoded} <- Jason.decode(resp),
             score when is_number(score) <- decoded["score"] do
          {:ok, max(min(score, 1.0), 0.0)}
        else
          _ -> {:error, :invalid_llm_response}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize(text) when is_binary(text), do: text |> String.downcase() |> String.trim()
  defp normalize(_), do: ""
end
