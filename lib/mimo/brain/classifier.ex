defmodule Mimo.Brain.Classifier do
  @moduledoc """
  Intent classifier for Meta-Cognitive Routing.

  Determines whether a query should be routed to:
  - GRAPH (Semantic Store) - for logic/dependency questions
  - VECTOR (Episodic Memory) - for narrative/vibe questions
  - HYBRID - for complex queries needing both

  Uses a two-tier approach:
  1. Fast Path: Regex keyword matching (~1ms)
  2. Slow Path: LLM classification (~500ms)
  """

  require Logger
  alias Mimo.Brain.LLM

  @graph_patterns [
    ~r/\b(depend|relies?\s+on|requires?|needs?)\b/i,
    ~r/\b(relation|relationship|connected|linked)\b/i,
    ~r/\b(hierarchy|parent|child|ancestor|descendant)\b/i,
    ~r/\b(cause|effect|impact|affects?)\b/i,
    ~r/\b(reports?\s+to|manages?|owns?|belongs?\s+to)\b/i,
    ~r/\bwhat\s+(depends|uses|requires)\b/i,
    ~r/\bwho\s+(reports|manages|owns)\b/i,
    ~r/\b(upstream|downstream)\b/i,
    ~r/\b(trace|path|route)\s+(from|to|between)\b/i
  ]

  @vector_patterns [
    ~r/\b(feel|feeling|vibe|tone|mood)\b/i,
    ~r/\b(style|approach|manner)\b/i,
    ~r/\b(story|narrative|experience|memory)\b/i,
    ~r/\b(similar|like|remind|resemble)\b/i,
    ~r/\b(remember|recall|when\s+did)\b/i,
    ~r/\b(context|background|history)\b/i,
    ~r/\b(example|instance|case)\b/i
  ]

  @type intent :: :graph | :vector | :hybrid
  @type classification_result :: {:ok, intent, float()} | {:error, term()}

  @doc """
  Classifies a query to determine routing destination.

  ## Parameters
    - `query` - The user's query string
    - `opts` - Options:
      - `:force_llm` - Skip fast path, use LLM (default: false)
      - `:context` - Additional context for classification

  ## Returns
    - `{:ok, :graph | :vector | :hybrid, confidence}` - Classification with confidence
    - `{:error, reason}` - Classification failed
  """
  @spec classify(String.t(), keyword()) :: classification_result()
  def classify(query, opts \\ []) do
    start_time = System.monotonic_time(:millisecond)
    force_llm = Keyword.get(opts, :force_llm, false)

    result =
      if force_llm do
        slow_path(query)
      else
        case fast_path(query) do
          {:ok, intent, confidence} when confidence >= 0.8 ->
            Logger.debug("Fast path classification: #{intent} (#{confidence})")
            {:ok, intent, confidence}

          _ ->
            Logger.debug("Fast path uncertain, using LLM")
            slow_path(query)
        end
      end

    # Emit telemetry
    duration_ms = System.monotonic_time(:millisecond) - start_time

    {intent, confidence, path} =
      case result do
        {:ok, i, c} -> {i, c, if(force_llm, do: "llm", else: "auto")}
        _ -> {:unknown, 0, "failed"}
      end

    :telemetry.execute(
      [:mimo, :brain, :classify],
      %{duration_ms: duration_ms},
      %{intent: intent, confidence: confidence, path: path}
    )

    result
  end

  @doc """
  Fast classification using regex patterns.
  Returns {:ok, intent, confidence} or {:uncertain, nil, 0.0}
  """
  @spec fast_path(String.t()) :: {:ok, intent(), float()} | {:uncertain, nil, float()}
  def fast_path(query) do
    graph_score = pattern_score(query, @graph_patterns)
    vector_score = pattern_score(query, @vector_patterns)

    cond do
      graph_score > 0 and vector_score > 0 ->
        # Both matched - hybrid
        confidence = min(graph_score, vector_score) * 0.7
        {:ok, :hybrid, confidence}

      graph_score >= 2 ->
        {:ok, :graph, min(0.9, 0.5 + graph_score * 0.15)}

      graph_score == 1 ->
        {:ok, :graph, 0.7}

      vector_score >= 2 ->
        {:ok, :vector, min(0.9, 0.5 + vector_score * 0.15)}

      vector_score == 1 ->
        {:ok, :vector, 0.7}

      true ->
        {:uncertain, nil, 0.0}
    end
  end

  @doc """
  Slow classification using LLM.
  """
  @spec slow_path(String.t()) :: classification_result()
  def slow_path(query) do
    prompt = """
    Classify the following user query into exactly one category.

    Categories:
    - LOGIC: Questions about dependencies, relationships, hierarchies, causes/effects
    - NARRATIVE: Questions about experiences, memories, similar things, context, stories

    Query: "#{query}"

    Respond with only one word: LOGIC or NARRATIVE
    """

    case LLM.complete(prompt, max_tokens: 10, temperature: 0.1) do
      {:ok, response} ->
        parse_llm_response(response)

      {:error, reason} ->
        Logger.warning("LLM classification failed: #{inspect(reason)}, defaulting to hybrid")
        {:ok, :hybrid, 0.5}
    end
  end

  defp pattern_score(query, patterns) do
    Enum.count(patterns, fn pattern ->
      Regex.match?(pattern, query)
    end)
  end

  defp parse_llm_response(response) do
    cleaned = response |> String.trim() |> String.upcase()

    cond do
      String.contains?(cleaned, "LOGIC") ->
        {:ok, :graph, 0.85}

      String.contains?(cleaned, "NARRATIVE") ->
        {:ok, :vector, 0.85}

      true ->
        Logger.warning("Unexpected LLM response: #{response}")
        {:ok, :hybrid, 0.5}
    end
  end
end
