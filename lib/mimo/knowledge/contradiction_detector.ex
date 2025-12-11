defmodule Mimo.Knowledge.ContradictionDetector do
  @moduledoc """
  SPEC-065: Proactive Knowledge Injection Engine - Contradiction Detection

  Detects when the AI is about to contradict stored knowledge.

  Examples:
  - AI says "I'll use deprecated API X"
  - Memory has: "API X deprecated, use Y instead"
  - → Alert: "⚠️ Contradiction: You stored that API X is deprecated"

  This prevents the AI from repeating mistakes it has already learned about.
  """

  alias Mimo.Brain.Memory

  require Logger

  @contradiction_threshold 0.8
  @max_contradictions 3

  # Words that often indicate stored warnings/issues
  @negation_words [
    "deprecated",
    "don't",
    "avoid",
    "wrong",
    "bug",
    "issue",
    "failed",
    "broken",
    "warning",
    "error",
    "problem",
    "not recommended",
    "obsolete",
    "outdated",
    "removed"
  ]

  @type contradiction :: %{
          type: :contradiction,
          stored: String.t(),
          proposed: String.t(),
          confidence: float(),
          warning: String.t()
        }

  # ============================================================================
  # PUBLIC API
  # ============================================================================

  @doc """
  Check if a proposed action contradicts stored knowledge.

  Returns a list of potential contradictions with confidence scores.
  """
  @spec check(String.t()) :: {:ok, [contradiction()]}
  def check(proposed_action) when is_binary(proposed_action) do
    # Search for potentially contradicting memories
    case Memory.search(proposed_action, limit: 5, threshold: @contradiction_threshold) do
      {:ok, %{results: results}} ->
        find_contradictions(proposed_action, results)

      {:ok, results} when is_list(results) ->
        find_contradictions(proposed_action, results)

      _ ->
        {:ok, []}
    end
  end

  def check(_), do: {:ok, []}

  @doc """
  Check a tool result for contradictions with stored knowledge.

  Useful for post-execution validation.
  """
  @spec check_result(map()) :: {:ok, [contradiction()]}
  def check_result(%{content: content}) when is_binary(content) do
    check(content)
  end

  def check_result(%{"content" => content}) when is_binary(content) do
    check(content)
  end

  def check_result(_), do: {:ok, []}

  # ============================================================================
  # CONTRADICTION DETECTION
  # ============================================================================

  defp find_contradictions(action, memories) when is_list(memories) do
    contradictions =
      memories
      |> Enum.filter(&is_map/1)
      |> Enum.filter(fn m ->
        content = Map.get(m, :content, "")
        potentially_contradicts?(content, action)
      end)
      |> Enum.take(@max_contradictions)
      |> Enum.map(fn m ->
        content = Map.get(m, :content, "")
        score = Map.get(m, :score, 0.5)

        %{
          type: :contradiction,
          stored: content,
          proposed: action,
          confidence: score,
          warning: "⚠️ This may contradict: #{truncate(content, 100)}"
        }
      end)

    if length(contradictions) > 0 do
      Logger.info(
        "[ContradictionDetector] Found #{length(contradictions)} potential contradictions"
      )
    end

    {:ok, contradictions}
  end

  defp find_contradictions(_action, _memories), do: {:ok, []}

  @doc """
  Determine if stored content potentially contradicts a proposed action.

  Uses heuristics based on negation words and topic overlap.
  """
  @spec potentially_contradicts?(String.t(), String.t()) :: boolean()
  def potentially_contradicts?(stored, proposed) when is_binary(stored) and is_binary(proposed) do
    stored_lower = String.downcase(stored)
    proposed_lower = String.downcase(proposed)

    # Check if stored content contains negation words AND has topic overlap
    has_negation = Enum.any?(@negation_words, &String.contains?(stored_lower, &1))
    has_overlap = has_topic_overlap?(stored_lower, proposed_lower)

    has_negation and has_overlap
  end

  def potentially_contradicts?(_, _), do: false

  # ============================================================================
  # TOPIC ANALYSIS
  # ============================================================================

  defp has_topic_overlap?(text1, text2) do
    words1 = extract_keywords(text1)
    words2 = extract_keywords(text2)

    overlap = MapSet.intersection(MapSet.new(words1), MapSet.new(words2))

    # Need at least 2 overlapping keywords to consider it related
    MapSet.size(overlap) >= 2
  end

  defp extract_keywords(text) do
    # Common words to exclude
    stop_words =
      MapSet.new([
        "the",
        "a",
        "an",
        "and",
        "or",
        "but",
        "in",
        "on",
        "at",
        "to",
        "for",
        "of",
        "with",
        "by",
        "from",
        "as",
        "is",
        "was",
        "are",
        "were",
        "been",
        "be",
        "have",
        "has",
        "had",
        "do",
        "does",
        "did",
        "will",
        "would",
        "could",
        "should",
        "may",
        "might",
        "must",
        "can",
        "this",
        "that",
        "these",
        "those",
        "it",
        "its",
        "you",
        "your",
        "i",
        "my",
        "we",
        "our",
        "they",
        "their"
      ])

    text
    |> String.split(~r/\W+/)
    |> Enum.filter(fn word ->
      String.length(word) > 3 and not MapSet.member?(stop_words, word)
    end)
    |> Enum.take(20)
  end

  # ============================================================================
  # UTILITIES
  # ============================================================================

  defp truncate(text, max) when is_binary(text) do
    if String.length(text) > max do
      String.slice(text, 0, max) <> "..."
    else
      text
    end
  end

  defp truncate(_, _), do: ""
end
