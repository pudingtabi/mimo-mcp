defmodule Mimo.MetaCognitiveRouter do
  @moduledoc """
  Meta-Cognitive Router: Intelligent query classification layer.

  Routes natural language inputs to the appropriate store:
  - Episodic Store (vector): Narrative, experiential queries
  - Semantic Store (graph): Logic, relationship queries  
  - Procedural Store (rules): Code, procedure queries

  Ref: Universal Aperture TDD - preserves the routing layer while enabling multi-protocol access.
  """
  require Logger

  @type store :: :episodic | :semantic | :procedural
  @type decision :: %{
          primary_store: store(),
          secondary_stores: [store()],
          confidence: float(),
          reasoning: String.t(),
          requires_synthesis: boolean()
        }

  # Keyword patterns for classification
  @procedural_keywords ~w(code bug fix function method class implement compile error syntax)
  @semantic_keywords ~w(relationship between depends structure architecture graph linked)
  @episodic_keywords ~w(remember when before earlier previously history past experience)

  @doc """
  Classify a query and determine routing to Triad Stores.

  ## Examples

      iex> Mimo.MetaCognitiveRouter.classify("Fix the null pointer bug in authenticate_user")
      %{
        primary_store: :procedural,
        confidence: 0.94,
        reasoning: "Code syntax detected; 'bug' and 'fix' keywords",
        ...
      }

  """
  @spec classify(String.t()) :: decision()
  def classify(query) when is_binary(query) do
    start_time = System.monotonic_time(:microsecond)

    query_lower = String.downcase(query)
    tokens = tokenize(query_lower)

    # Score each store
    procedural_score = score_procedural(tokens, query_lower)
    semantic_score = score_semantic(tokens, query_lower)
    episodic_score = score_episodic(tokens, query_lower)

    # avoid div/0
    total = procedural_score + semantic_score + episodic_score + 0.01

    scores = %{
      procedural: procedural_score / total,
      semantic: semantic_score / total,
      episodic: episodic_score / total
    }

    {primary_store, confidence} =
      scores
      |> Enum.max_by(fn {_k, v} -> v end)

    secondary_stores =
      scores
      |> Enum.filter(fn {k, v} -> k != primary_store and v > 0.2 end)
      |> Enum.map(fn {k, _v} -> k end)

    reasoning = generate_reasoning(primary_store, tokens)

    # Emit telemetry
    duration_us = System.monotonic_time(:microsecond) - start_time
    emit_telemetry(duration_us, primary_store, confidence)

    %{
      primary_store: primary_store,
      secondary_stores: secondary_stores,
      confidence: Float.round(confidence, 2),
      reasoning: reasoning,
      requires_synthesis: confidence < 0.7 or length(secondary_stores) > 0
    }
  end

  defp tokenize(text) do
    text
    |> String.replace(~r/[^\w\s]/, " ")
    |> String.split(~r/\s+/, trim: true)
  end

  defp score_procedural(tokens, query) do
    keyword_hits = count_keyword_hits(tokens, @procedural_keywords)

    # Code patterns boost
    code_patterns = [
      ~r/\b(function|method|class|def|fn)\b/,
      ~r/\b(bug|error|fix|debug)\b/,
      ~r/\b(implement|code|compile|runtime)\b/,
      # function calls
      ~r/\([^)]*\)/,
      # snake_case identifiers
      ~r/_[a-z]+/
    ]

    pattern_hits = Enum.count(code_patterns, &Regex.match?(&1, query))

    keyword_hits * 2.0 + pattern_hits * 1.5
  end

  defp score_semantic(tokens, query) do
    keyword_hits = count_keyword_hits(tokens, @semantic_keywords)

    # Relationship patterns
    relationship_patterns = [
      ~r/\b(between|relates?|connects?|linked)\b/,
      ~r/\b(depends|requires|uses)\b/,
      ~r/\b(structure|architecture|diagram)\b/
    ]

    pattern_hits = Enum.count(relationship_patterns, &Regex.match?(&1, query))

    keyword_hits * 2.0 + pattern_hits * 1.5
  end

  defp score_episodic(tokens, query) do
    keyword_hits = count_keyword_hits(tokens, @episodic_keywords)

    # Narrative patterns
    narrative_patterns = [
      ~r/\b(remember|recall|when|before)\b/,
      ~r/\b(last time|previously|earlier)\b/,
      ~r/\b(experience|story|happened)\b/,
      ~r/\b(vibe|feel|atmosphere|mood)\b/
    ]

    pattern_hits = Enum.count(narrative_patterns, &Regex.match?(&1, query))

    # Default baseline for general queries
    baseline = 1.0

    keyword_hits * 2.0 + pattern_hits * 1.5 + baseline
  end

  defp count_keyword_hits(tokens, keywords) do
    Enum.count(tokens, &(&1 in keywords))
  end

  defp generate_reasoning(store, tokens) do
    matched_keywords =
      case store do
        :procedural -> Enum.filter(tokens, &(&1 in @procedural_keywords))
        :semantic -> Enum.filter(tokens, &(&1 in @semantic_keywords))
        :episodic -> Enum.filter(tokens, &(&1 in @episodic_keywords))
      end

    store_name = Atom.to_string(store) |> String.capitalize()

    if Enum.empty?(matched_keywords) do
      "#{store_name} store selected as default for general query"
    else
      "#{store_name} store selected; keywords detected: #{Enum.join(matched_keywords, ", ")}"
    end
  end

  defp emit_telemetry(duration_us, primary_store, confidence) do
    # Telemetry event for monitoring
    :telemetry.execute(
      [:mimo, :router, :classify],
      %{duration_us: duration_us, confidence: confidence},
      %{primary_store: primary_store}
    )

    duration_ms = duration_us / 1000

    if duration_ms > 10 do
      Logger.warning("Router classification slow: #{Float.round(duration_ms, 2)}ms")
    end
  end
end
