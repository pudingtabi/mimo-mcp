defmodule Mimo.Brain.EmotionalScorer do
  @moduledoc """
  SPEC-105: Emotional Salience Scoring for Memory Importance.

  Detects emotional content in memories and adjusts importance accordingly.
  Memories with high emotional weight (success, failure, frustration, breakthrough)
  are naturally more memorable and should be prioritized in retrieval.

  ## Emotion Categories

  - **High Positive**: Success, breakthrough, achievement, excitement
  - **High Negative**: Failure, error, frustration, blocker
  - **Neutral**: Factual, procedural, reference

  ## Importance Boost

  | Emotion Level | Importance Boost |
  |---------------|------------------|
  | High (0.8+)   | +0.2             |
  | Medium (0.5-0.8) | +0.1          |
  | Low (<0.5)    | +0.0             |

  ## Integration

  Called during memory storage to enhance importance scoring.
  Works with existing importance field, no schema changes needed.
  """

  require Logger
  alias Mimo.Brain.LLM

  @emotion_keywords %{
    high_positive:
      ~w[success succeeded breakthrough achieved fixed solved working finally got it eureka amazing excellent wonderful],
    high_negative:
      ~w[failed error crash bug stuck blocked frustrated annoying impossible broken nightmare terrible horrible],
    medium_positive: ~w[good better improved helpful useful interesting learned discovered found],
    medium_negative: ~w[issue problem warning difficult tricky confusing unclear slow]
  }

  @doc """
  Score the emotional weight of content.

  Returns a map with:
  - `score`: Float 0.0-1.0 indicating emotional intensity
  - `valence`: :positive, :negative, or :neutral
  - `importance_boost`: How much to add to base importance
  - `keywords_found`: Which emotional keywords were detected

  ## Examples

      iex> EmotionalScorer.score("Finally fixed the authentication bug!")
      {:ok, %{score: 0.85, valence: :positive, importance_boost: 0.2, keywords_found: ["finally", "fixed"]}}

      iex> EmotionalScorer.score("Updated config file")
      {:ok, %{score: 0.1, valence: :neutral, importance_boost: 0.0, keywords_found: []}}
  """
  @spec score(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def score(content, opts \\ []) do
    use_llm = Keyword.get(opts, :use_llm, false)

    if use_llm do
      score_with_llm(content)
    else
      score_with_keywords(content)
    end
  end

  @doc """
  Apply emotional importance boost to a memory attrs map.

  Takes the existing importance and adds the emotional boost.
  Clamps result to 0.0-1.0 range.

  ## Example

      iex> attrs = %{content: "Finally solved it!", importance: 0.5}
      iex> EmotionalScorer.apply_boost(attrs)
      %{content: "Finally solved it!", importance: 0.7, emotional_score: 0.85}
  """
  @spec apply_boost(map()) :: map()
  def apply_boost(%{content: content} = attrs) do
    case score(content) do
      {:ok, %{importance_boost: boost, score: emotional_score}} when boost > 0 ->
        base_importance = Map.get(attrs, :importance, 0.5)
        new_importance = min(1.0, base_importance + boost)

        attrs
        |> Map.put(:importance, new_importance)
        |> Map.update(:metadata, %{emotional_score: emotional_score}, fn meta ->
          Map.put(meta || %{}, :emotional_score, emotional_score)
        end)

      _ ->
        attrs
    end
  end

  def apply_boost(attrs), do: attrs

  @doc """
  Batch score multiple contents for efficiency.
  """
  @spec batch_score([String.t()]) :: {:ok, [map()]}
  def batch_score(contents) when is_list(contents) do
    results =
      Enum.map(contents, fn content ->
        case score(content) do
          {:ok, result} -> result
          _ -> %{score: 0.0, valence: :neutral, importance_boost: 0.0, keywords_found: []}
        end
      end)

    {:ok, results}
  end

  # ──────────────────────────────────────────────────────────────────
  # Private: Keyword-based scoring (fast, local)
  # ──────────────────────────────────────────────────────────────────

  defp score_with_keywords(content) do
    content_lower = String.downcase(content)
    words = String.split(content_lower, ~r/\W+/, trim: true)

    # Find matching keywords
    high_pos = find_matches(words, @emotion_keywords.high_positive)
    high_neg = find_matches(words, @emotion_keywords.high_negative)
    med_pos = find_matches(words, @emotion_keywords.medium_positive)
    med_neg = find_matches(words, @emotion_keywords.medium_negative)

    # Calculate scores
    high_count = length(high_pos) + length(high_neg)
    med_count = length(med_pos) + length(med_neg)
    all_keywords = high_pos ++ high_neg ++ med_pos ++ med_neg

    # Determine valence (positive vs negative bias)
    positive_weight = length(high_pos) * 2 + length(med_pos)
    negative_weight = length(high_neg) * 2 + length(med_neg)

    valence =
      cond do
        positive_weight > negative_weight -> :positive
        negative_weight > positive_weight -> :negative
        true -> :neutral
      end

    # Calculate emotional intensity (0-1)
    # High keywords = 0.3 each (capped at 0.9)
    # Medium keywords = 0.15 each (capped at 0.6)
    raw_score = min(0.9, high_count * 0.3) + min(0.6, med_count * 0.15)
    score = min(1.0, raw_score)

    # Determine importance boost
    importance_boost =
      cond do
        score >= 0.8 -> 0.2
        score >= 0.5 -> 0.1
        score >= 0.3 -> 0.05
        true -> 0.0
      end

    {:ok,
     %{
       score: Float.round(score, 2),
       valence: valence,
       importance_boost: importance_boost,
       keywords_found: all_keywords,
       method: :keywords
     }}
  end

  defp find_matches(words, keyword_list) do
    Enum.filter(keyword_list, fn kw -> kw in words end)
  end

  # ──────────────────────────────────────────────────────────────────
  # Private: LLM-based scoring (more accurate, slower)
  # ──────────────────────────────────────────────────────────────────

  defp score_with_llm(content) do
    prompt = """
    Analyze the emotional intensity of this text. Rate:
    1. Emotional intensity: 0.0 (neutral/factual) to 1.0 (highly emotional)
    2. Valence: positive, negative, or neutral
    3. Key emotional indicators (if any)

    Text: #{String.slice(content, 0, 500)}

    Respond in JSON format:
    {"score": 0.X, "valence": "positive|negative|neutral", "indicators": ["word1", "word2"]}
    """

    case LLM.complete(prompt, model: "fast", max_tokens: 100) do
      {:ok, response} ->
        parse_llm_response(response)

      {:error, reason} ->
        Logger.debug(
          "[EmotionalScorer] LLM unavailable, falling back to keywords: #{inspect(reason)}"
        )

        score_with_keywords(content)
    end
  end

  defp parse_llm_response(response) do
    # Extract JSON from response
    case Jason.decode(response) do
      {:ok, %{"score" => score, "valence" => valence} = data} ->
        valence_atom =
          case valence do
            "positive" -> :positive
            "negative" -> :negative
            _ -> :neutral
          end

        importance_boost =
          cond do
            score >= 0.8 -> 0.2
            score >= 0.5 -> 0.1
            score >= 0.3 -> 0.05
            true -> 0.0
          end

        {:ok,
         %{
           score: score,
           valence: valence_atom,
           importance_boost: importance_boost,
           keywords_found: Map.get(data, "indicators", []),
           method: :llm
         }}

      _ ->
        # If JSON parsing fails, fall back to keywords
        Logger.debug("[EmotionalScorer] Failed to parse LLM response, using keywords")
        score_with_keywords(response)
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # Statistics
  # ──────────────────────────────────────────────────────────────────

  @doc """
  Get statistics about emotional scoring in stored memories.
  """
  @spec stats() :: map()
  def stats do
    # Query memories with emotional scores in metadata
    alias Mimo.Repo
    alias Mimo.Brain.Engram
    import Ecto.Query

    total =
      Repo.one(
        from(e in Engram,
          where: e.archived == false,
          select: count(e.id)
        )
      ) || 0

    # Count memories with emotional scores (stored in metadata)
    with_emotion =
      Repo.one(
        from(e in Engram,
          where:
            e.archived == false and
              fragment("json_extract(?, '$.emotional_score') IS NOT NULL", e.metadata),
          select: count(e.id)
        )
      ) || 0

    # Average emotional score
    avg_score =
      Repo.one(
        from(e in Engram,
          where:
            e.archived == false and
              fragment("json_extract(?, '$.emotional_score') IS NOT NULL", e.metadata),
          select:
            fragment(
              "AVG(CAST(json_extract(?, '$.emotional_score') AS REAL))",
              e.metadata
            )
        )
      ) || 0.0

    %{
      total_memories: total,
      with_emotional_score: with_emotion,
      coverage_percent: if(total > 0, do: Float.round(with_emotion / total * 100, 1), else: 0.0),
      average_emotional_score: if(is_number(avg_score), do: Float.round(avg_score, 2), else: 0.0)
    }
  end
end
