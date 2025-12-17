defmodule Mimo.Brain.CorrectionLearning do
  @moduledoc """
  SPEC-084: Correction Learning Loop

  Detects when the user corrects the AI and stores corrections as high-importance
  memories that prevent repeating the same mistakes.

  ## How It Works

  1. **Detection**: Analyzes user messages for correction patterns like:
     - "No, that's wrong..."
     - "Actually, it's..."
     - "You made a mistake..."
     - "That's incorrect..."

  2. **Extraction**: Extracts what was wrong and what is correct

  3. **Storage**: Stores as high-importance memory with category :correction

  4. **Linking**: Links correction to the original claim in knowledge graph

  5. **Retrieval**: Corrections are surfaced during interleaved thinking
     verification to prevent repeating mistakes

  ## Example

  User: "No, Memory.search_memories returns a list directly, not {:ok, list}"

  This triggers:
  - Detection: "No, ... returns ... not" pattern
  - Store: "CORRECTION: Memory.search_memories returns list directly, NOT {:ok, list}"
  - Link: Creates contradiction edge in knowledge graph
  """

  require Logger

  alias Mimo.Brain.Memory
  alias Mimo.Synapse.Graph

  # Correction detection patterns (order matters - more specific first)
  @correction_patterns [
    # Explicit corrections
    ~r/(?:no|nope),?\s+(?:that's|thats|it's|its|you're|youre)\s+(?:wrong|incorrect|not right|mistaken)/i,
    ~r/(?:actually|in fact),?\s+(?:it's|its|that's|thats|the)\s+/i,
    ~r/you\s+(?:made a|have a)\s+mistake/i,
    ~r/that's\s+(?:not|incorrect|wrong)/i,
    ~r/(?:should be|is actually|is really)\s+/i,
    # Specific pattern for tuple corrections
    ~r/not\s+\{:ok,?\s*[^}]+\}/i,
    ~r/returns?\s+(?:a\s+)?list\s+directly/i,

    # Gentle corrections
    ~r/i\s+(?:think|believe)\s+you\s+(?:meant|mean)/i,
    ~r/(?:small|minor)\s+(?:correction|fix)/i,
    ~r/(?:let me|allow me to)\s+correct/i,

    # Code-specific corrections
    ~r/the\s+(?:function|method|api)\s+(?:returns?|takes?|expects?)/i,
    ~r/(?:wrong|incorrect)\s+(?:parameter|argument|return type)/i
  ]

  # Confidence threshold for pattern match
  @min_correction_confidence 0.6

  @doc """
  Analyze a user message for corrections and store if found.

  Returns {:correction_detected, details} or :no_correction
  """
  @spec analyze_and_learn(String.t(), map()) :: {:correction_detected, map()} | :no_correction
  def analyze_and_learn(user_message, context \\ %{}) do
    case detect_correction(user_message) do
      {:ok, detection} ->
        correction = extract_correction(user_message, detection, context)
        store_correction(correction)
        link_correction(correction, context)
        {:correction_detected, correction}

      :no_correction ->
        :no_correction
    end
  end

  @doc """
  Check if a message contains a correction pattern.
  """
  @spec detect_correction(String.t()) :: {:ok, map()} | :no_correction
  def detect_correction(message) do
    # Check each pattern
    results =
      @correction_patterns
      |> Enum.with_index()
      |> Enum.map(fn {pattern, priority} ->
        case Regex.run(pattern, message) do
          [match | _] ->
            # Earlier patterns (lower index) are more confident
            confidence = 1.0 - priority * 0.05
            %{pattern: pattern, match: match, confidence: confidence, priority: priority}

          nil ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    case results do
      [] ->
        :no_correction

      matches ->
        # Take the highest confidence match
        best = Enum.max_by(matches, & &1.confidence)

        if best.confidence >= @min_correction_confidence do
          {:ok, best}
        else
          :no_correction
        end
    end
  end

  @doc """
  Extract the correction details from the message.
  """
  @spec extract_correction(String.t(), map(), map()) :: map()
  def extract_correction(message, detection, context) do
    # Try to extract what was wrong vs what is correct
    {wrong_claim, correct_claim} = parse_correction_content(message)

    %{
      original_message: message,
      detection_pattern: inspect(detection.pattern),
      detection_confidence: detection.confidence,
      wrong_claim: wrong_claim,
      correct_claim: correct_claim,
      context: context,
      timestamp: DateTime.utc_now(),
      learned: false
    }
  end

  # Parse the message to extract wrong vs correct claims
  defp parse_correction_content(message) do
    # Try common patterns

    # Pattern: "X returns Y, not Z" -> wrong: "returns Z", correct: "returns Y"
    case Regex.run(~r/(\w+(?:\.\w+)*)\s+returns?\s+(.+?),?\s+not\s+(.+)/i, message) do
      [_, subject, correct, wrong] ->
        {"#{subject} returns #{String.trim(wrong)}", "#{subject} returns #{String.trim(correct)}"}

      nil ->
        # Pattern: "No, it's X not Y"
        case Regex.run(
               ~r/(?:no|actually),?\s+(?:it's|its|that's|thats)\s+(.+?),?\s+not\s+(.+)/i,
               message
             ) do
          [_, correct, wrong] ->
            {String.trim(wrong), String.trim(correct)}

          nil ->
            # Pattern: "should be X" (implies current is wrong)
            case Regex.run(~r/should\s+be\s+(.+)/i, message) do
              [_, correct] ->
                {"(previous claim)", String.trim(correct)}

              nil ->
                # Fallback: whole message is the correction
                {"(unknown wrong claim)", message}
            end
        end
    end
  end

  @doc """
  Store the correction as a high-importance memory.
  """
  @spec store_correction(map()) :: {:ok, integer()} | {:error, term()}
  def store_correction(correction) do
    content = format_correction_memory(correction)

    case Memory.persist_memory(content, :fact, 0.95,
           metadata: %{
             type: "correction",
             wrong_claim: correction.wrong_claim,
             correct_claim: correction.correct_claim,
             source: "user_correction",
             detection_confidence: correction.detection_confidence
           }
         ) do
      {:ok, engram} ->
        Logger.info("[CorrectionLearning] Stored correction: #{content}")
        {:ok, engram.id}

      error ->
        Logger.warning("[CorrectionLearning] Failed to store correction: #{inspect(error)}")
        error
    end
  end

  defp format_correction_memory(correction) do
    "CORRECTION: #{correction.correct_claim} (NOT: #{correction.wrong_claim})"
  end

  @doc """
  Link the correction in the knowledge graph.
  Creates a 'contradicts' edge between the wrong claim and correct claim.
  """
  @spec link_correction(map(), map()) :: :ok
  def link_correction(correction, _context) do
    # Try to link in knowledge graph if we have enough context
    if correction.wrong_claim != "(unknown wrong claim)" do
      # Create nodes for both claims
      wrong_node = "claim:#{hash_claim(correction.wrong_claim)}"
      correct_node = "claim:#{hash_claim(correction.correct_claim)}"

      # Add contradiction edge using create_edge
      case Graph.create_edge(%{
             source_node_id: wrong_node,
             target_node_id: correct_node,
             edge_type: "relates_to",
             weight: 1.0,
             confidence: correction.detection_confidence,
             properties: %{
               relationship: "contradicted_by",
               source: "user_correction",
               timestamp: DateTime.to_iso8601(correction.timestamp)
             },
             source: "correction_learning"
           }) do
        {:ok, _} ->
          Logger.debug("[CorrectionLearning] Linked correction in graph")

        {:error, reason} ->
          Logger.debug("[CorrectionLearning] Could not link in graph: #{inspect(reason)}")
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  defp hash_claim(claim) do
    :crypto.hash(:md5, claim) |> Base.encode16(case: :lower) |> String.slice(0, 12)
  end

  @doc """
  Search for corrections relevant to a claim or topic.
  Used by interleaved thinking to check if a claim contradicts known corrections.
  """
  @spec find_relevant_corrections(String.t(), keyword()) :: [map()]
  def find_relevant_corrections(claim, opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)

    # Search for correction memories
    query = "CORRECTION #{claim}"

    case Memory.search_memories(query, limit: limit, min_similarity: 0.5) do
      memories when is_list(memories) ->
        memories
        |> Enum.filter(fn m ->
          m.metadata["type"] == "correction" or
            String.starts_with?(m.content || "", "CORRECTION:")
        end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  @doc """
  Check if a claim contradicts any known corrections.
  Returns {:contradiction, correction} if found, :ok otherwise.
  """
  @spec check_against_corrections(String.t()) :: {:contradiction, map()} | :ok
  def check_against_corrections(claim) do
    corrections = find_relevant_corrections(claim, limit: 3)

    # Check if any correction's wrong_claim matches the current claim
    contradiction =
      Enum.find(corrections, fn correction ->
        wrong = correction.metadata["wrong_claim"] || ""
        # Fuzzy match - if the claim contains the wrong claim pattern
        String.contains?(String.downcase(claim), String.downcase(wrong)) and wrong != ""
      end)

    case contradiction do
      nil -> :ok
      c -> {:contradiction, c}
    end
  end

  @doc """
  Get statistics about corrections learned.
  """
  @spec stats() :: map()
  def stats do
    corrections = find_relevant_corrections("CORRECTION", limit: 100)

    %{
      total_corrections: length(corrections),
      recent_corrections:
        corrections
        |> Enum.take(5)
        |> Enum.map(& &1.content)
    }
  end
end
