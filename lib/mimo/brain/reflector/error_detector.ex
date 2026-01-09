defmodule Mimo.Brain.Reflector.ErrorDetector do
  @moduledoc """
  Detects potential errors before output delivery.

  Part of SPEC-043: Reflective Intelligence System.

  Error categories detected:
  - **Factual Contradiction**: Output contradicts known facts in memory
  - **Logical Inconsistency**: Reasoning has internal contradictions
  - **Unsupported Claim**: Assertions made without evidence
  - **Missing Element**: Required information is absent
  - **Format Violation**: Output doesn't match expected format
  - **Confidence Mismatch**: Certainty language doesn't match evidence

  ## Example

      errors = ErrorDetector.detect(output, context)
      if Enum.any?(errors, &(&1.severity == :high)) do
        {:needs_refinement, errors}
      else
        {:ok, output}
      end
  """

  @type error_type ::
          :factual_contradiction
          | :logical_inconsistency
          | :unsupported_claim
          | :missing_element
          | :format_violation
          | :confidence_mismatch

  @type severity :: :high | :medium | :low

  @type error :: %{
          type: error_type(),
          severity: severity(),
          description: String.t(),
          evidence: String.t() | nil,
          suggestion: String.t()
        }

  @error_patterns [
    :factual_contradiction,
    :logical_inconsistency,
    :unsupported_claim,
    :missing_element,
    :format_violation,
    :confidence_mismatch
  ]

  @doc """
  Detect potential errors in output.

  ## Parameters

  - `output` - The generated output to check
  - `context` - Map containing:
    - `:query` - Original query
    - `:memories` - Retrieved memories
    - `:expected_format` - Expected output format (optional)
    - `:required_elements` - Elements that must be present (optional)
  """
  @spec detect(String.t(), map()) :: [error()]
  def detect(output, context) do
    @error_patterns
    |> Enum.map(&check_pattern(&1, output, context))
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn e -> severity_rank(e.severity) end)
  end

  @doc """
  Quick error check - only checks for high severity issues.
  """
  @spec quick_detect(String.t(), map()) :: [error()]
  def quick_detect(output, context) do
    # Only check the most critical patterns
    [:factual_contradiction, :logical_inconsistency]
    |> Enum.map(&check_pattern(&1, output, context))
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&(&1.severity == :high))
  end

  @doc """
  Check if output has any high severity errors.
  """
  @spec has_critical_errors?(String.t(), map()) :: boolean()
  def has_critical_errors?(output, context) do
    quick_detect(output, context) != []
  end

  @doc """
  Get error count by severity.
  """
  @spec error_summary([error()]) :: map()
  def error_summary(errors) do
    %{
      high: Enum.count(errors, &(&1.severity == :high)),
      medium: Enum.count(errors, &(&1.severity == :medium)),
      low: Enum.count(errors, &(&1.severity == :low)),
      total: length(errors)
    }
  end

  defp check_pattern(:factual_contradiction, output, context) do
    memories = context[:memories] || []

    if memories == [] do
      nil
    else
      # Extract claims from output
      claims = extract_claims(output)

      # Find contradictions with stored memories
      contradictions =
        for claim <- claims,
            memory <- memories,
            content = memory[:content] || memory["content"] || "",
            contradiction = find_contradiction(claim, content),
            contradiction != nil,
            do: %{claim: claim, memory_content: content, type: contradiction}

      if contradictions != [] do
        # Take the most severe contradiction
        worst = List.first(contradictions)

        %{
          type: :factual_contradiction,
          severity: :high,
          description: "Output contradicts stored knowledge",
          evidence:
            "Claim '#{String.slice(worst.claim, 0, 50)}...' conflicts with memory: '#{String.slice(worst.memory_content, 0, 50)}...'",
          suggestion: "Verify the claim against stored memories and correct if needed"
        }
      end
    end
  end

  defp check_pattern(:logical_inconsistency, output, _context) do
    # Check for internal contradictions within the output itself
    sentences = split_into_sentences(output)

    inconsistencies =
      for {s1, i} <- Enum.with_index(sentences),
          {s2, j} <- Enum.with_index(sentences),
          j > i,
          inconsistent = find_internal_inconsistency(s1, s2),
          inconsistent != nil,
          do: %{first: s1, second: s2, type: inconsistent}

    if inconsistencies != [] do
      inc = List.first(inconsistencies)

      %{
        type: :logical_inconsistency,
        severity: :high,
        description: "Output contains internal contradictions",
        evidence:
          "Statements appear inconsistent: '#{String.slice(inc.first, 0, 40)}...' vs '#{String.slice(inc.second, 0, 40)}...'",
        suggestion: "Review the logical flow and ensure consistency throughout"
      }
    end
  end

  defp check_pattern(:unsupported_claim, output, context) do
    memories = context[:memories] || []
    tool_results = context[:tool_results] || []

    # Extract specific/quantitative claims
    specific_claims = extract_specific_claims(output)

    if specific_claims == [] do
      nil
    else
      # Check which claims lack grounding
      unsupported =
        specific_claims
        |> Enum.reject(fn claim ->
          grounded_in_memories?(claim, memories) or grounded_in_tools?(claim, tool_results)
        end)

      if length(unsupported) >= 2 do
        %{
          type: :unsupported_claim,
          severity: :medium,
          description: "Multiple claims lack supporting evidence",
          evidence: "Examples: #{Enum.take(unsupported, 2) |> Enum.join("; ")}",
          suggestion: "Add qualifiers like 'I believe' or seek supporting evidence"
        }
      end
    end
  end

  defp check_pattern(:missing_element, output, context) do
    required_elements = context[:required_elements] || []
    query = context[:query] || ""

    # Auto-detect required elements from query if not specified
    elements =
      if required_elements == [] do
        infer_required_elements(query)
      else
        required_elements
      end

    if elements == [] do
      nil
    else
      output_lower = String.downcase(output)

      missing =
        elements
        |> Enum.reject(fn elem ->
          String.contains?(output_lower, String.downcase(elem))
        end)

      if missing != [] do
        severity = if length(missing) >= length(elements) / 2, do: :high, else: :medium

        %{
          type: :missing_element,
          severity: severity,
          description: "Output is missing required elements",
          evidence: "Missing: #{Enum.join(missing, ", ")}",
          suggestion: "Address all parts of the query: #{Enum.join(missing, ", ")}"
        }
      end
    end
  end

  defp check_pattern(:format_violation, output, context) do
    expected_format = context[:expected_format]

    if is_nil(expected_format) do
      nil
    else
      violation = check_format_compliance(output, expected_format)

      if violation do
        %{
          type: :format_violation,
          severity: :medium,
          description: "Output doesn't match expected format",
          evidence: violation,
          suggestion: "Reformat the output to match the expected structure"
        }
      end
    end
  end

  defp check_pattern(:confidence_mismatch, output, context) do
    memories = context[:memories] || []

    # Check for overconfident language with weak evidence
    overconfident_phrases = find_overconfident_phrases(output)
    evidence_strength = calculate_evidence_strength(memories)

    if overconfident_phrases != [] and evidence_strength < 0.5 do
      %{
        type: :confidence_mismatch,
        severity: :medium,
        description: "Confidence language doesn't match evidence strength",
        evidence:
          "Phrases like '#{List.first(overconfident_phrases)}' used with weak evidence (#{Float.round(evidence_strength, 2)})",
        suggestion: "Use more tentative language like 'I believe' or 'it appears that'"
      }
    end
  end

  defp severity_rank(:high), do: 1
  defp severity_rank(:medium), do: 2
  defp severity_rank(:low), do: 3

  defp extract_claims(text) do
    text
    |> split_into_sentences()
    |> Enum.filter(&looks_like_factual_claim?/1)
    |> Enum.take(10)
  end

  defp split_into_sentences(text) do
    text
    |> String.split(~r/[.!?]+/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(String.length(&1) < 5))
  end

  defp looks_like_factual_claim?(sentence) do
    # Factual claims typically use be-verbs or definitive language
    String.match?(sentence, ~r/\b(is|are|was|were|has|have|does|do|will|must|always|never)\b/i)
  end

  defp find_contradiction(claim, memory_content) do
    claim_lower = String.downcase(claim)
    memory_lower = String.downcase(memory_content)

    # Direct negation patterns
    negation_pairs = [
      {"is not", "is"},
      {"isn't", "is"},
      {"are not", "are"},
      {"aren't", "are"},
      {"cannot", "can"},
      {"can't", "can"},
      {"does not", "does"},
      {"doesn't", "does"},
      {"never", "always"},
      {"false", "true"},
      {"incorrect", "correct"},
      {"wrong", "right"}
    ]

    # Check if claim has negation where memory has assertion (or vice versa)
    contradiction =
      Enum.find(negation_pairs, fn {neg, pos} ->
        (String.contains?(claim_lower, neg) and String.contains?(memory_lower, pos) and
           not String.contains?(memory_lower, neg)) or
          (String.contains?(memory_lower, neg) and String.contains?(claim_lower, pos) and
             not String.contains?(claim_lower, neg))
      end)

    if contradiction do
      :direct_negation
    else
      # Check for semantic contradiction with key terms
      claim_terms = extract_key_terms(claim_lower)
      memory_terms = extract_key_terms(memory_lower)

      # Look for opposite value claims about same subject
      shared_subject = MapSet.intersection(MapSet.new(claim_terms), MapSet.new(memory_terms))

      if MapSet.size(shared_subject) >= 2 do
        # Could be talking about same thing differently
        # This is a weak signal - would need NLI for better detection
        nil
      else
        nil
      end
    end
  end

  defp find_internal_inconsistency(sentence1, sentence2) do
    s1_lower = String.downcase(sentence1)
    s2_lower = String.downcase(sentence2)

    # Check for same subject with contradicting predicates
    s1_terms = extract_key_terms(s1_lower)
    s2_terms = extract_key_terms(s2_lower)

    shared_terms = MapSet.intersection(MapSet.new(s1_terms), MapSet.new(s2_terms))

    if MapSet.size(shared_terms) >= 2 do
      # Same subject mentioned - check for negation patterns
      has_negation_1 =
        String.match?(s1_lower, ~r/\b(not|no|never|cannot|won't|doesn't|isn't|aren't)\b/)

      has_negation_2 =
        String.match?(s2_lower, ~r/\b(not|no|never|cannot|won't|doesn't|isn't|aren't)\b/)

      if has_negation_1 != has_negation_2 do
        :potential_contradiction
      else
        nil
      end
    else
      nil
    end
  end

  defp extract_specific_claims(output) do
    # Claims with specific numbers, percentages, dates, etc.
    patterns = [
      # Percentages
      ~r/\b\d+\.?\d*%/,
      # Years
      ~r/\b\d{4}\b/,
      # Money
      ~r/\$\d+/,
      # Large numbers
      ~r/\b\d+\s*(million|billion|thousand)\b/i,
      # Quoted content
      ~r/"[^"]+"/
    ]

    output
    |> split_into_sentences()
    |> Enum.filter(fn sentence ->
      Enum.any?(patterns, &String.match?(sentence, &1))
    end)
    |> Enum.map(&String.slice(&1, 0, 100))
  end

  defp grounded_in_memories?(claim, memories) do
    claim_terms = extract_key_terms(claim)

    Enum.any?(memories, fn m ->
      content = m[:content] || m["content"] || ""
      memory_terms = extract_key_terms(content)

      overlap = MapSet.intersection(MapSet.new(claim_terms), MapSet.new(memory_terms))
      MapSet.size(overlap) >= 3
    end)
  end

  defp grounded_in_tools?(claim, tool_results) do
    if tool_results == [] do
      false
    else
      claim_lower = String.downcase(claim)

      Enum.any?(tool_results, fn result ->
        result_str =
          cond do
            is_binary(result) -> result
            is_map(result) -> Jason.encode!(result) |> String.downcase()
            true -> inspect(result)
          end
          |> String.downcase()

        # Check for significant overlap
        claim_terms = extract_key_terms(claim_lower)
        Enum.any?(claim_terms, &String.contains?(result_str, &1))
      end)
    end
  end

  defp infer_required_elements(query) do
    # Extract key question terms that should be addressed
    query
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, "")
    |> String.split()
    |> Enum.reject(fn x -> String.length(x) < 4 or common_word?(x) end)
    |> Enum.take(5)
  end

  defp check_format_compliance(output, expected_format) do
    case expected_format do
      :json ->
        case Jason.decode(output) do
          {:ok, _} -> nil
          {:error, _} -> "Output is not valid JSON"
        end

      :markdown ->
        if String.match?(output, ~r/^#|\n#|\*|-|\d+\./m) do
          nil
        else
          "Output doesn't appear to use Markdown formatting"
        end

      :code ->
        if String.match?(output, ~r/```/) do
          nil
        else
          "Output doesn't contain code blocks"
        end

      :list ->
        if String.match?(output, ~r/^[-*\d]/m) do
          nil
        else
          "Output doesn't appear to be a list"
        end

      _ ->
        nil
    end
  end

  defp find_overconfident_phrases(output) do
    patterns = [
      ~r/\bdefinitely\b/i,
      ~r/\bcertainly\b/i,
      ~r/\babsolutely\b/i,
      ~r/\balways\b/i,
      ~r/\bnever\b/i,
      ~r/\bmust be\b/i,
      ~r/\bguaranteed\b/i,
      ~r/\bwithout a doubt\b/i,
      ~r/\b100%\b/,
      ~r/\bimpossible\b/i
    ]

    patterns
    |> Enum.flat_map(fn pattern ->
      Regex.scan(pattern, output)
      |> Enum.map(fn [match | _] -> match end)
    end)
    |> Enum.uniq()
  end

  defp calculate_evidence_strength(memories) do
    if memories == [] do
      0.1
    else
      # Based on number and quality of memories
      count_factor = min(1.0, length(memories) / 5)

      avg_similarity =
        memories
        |> Enum.map(fn m -> m[:similarity] || m["similarity"] || 0.5 end)
        |> Enum.sum()
        |> Kernel./(length(memories))

      (count_factor + avg_similarity) / 2
    end
  end

  defp extract_key_terms(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, "")
    |> String.split()
    |> Enum.reject(fn x -> String.length(x) < 3 or common_word?(x) end)
    |> Enum.uniq()
  end

  defp common_word?(word) do
    common = ~w(the a an is are was were be been being have has had
      do does did will would could should may might must can
      this that these those what when where which who how
      for from with about into through and but or not
      to of in on at by it its i we you they them their
      very really just also only even more most some any)

    word in common
  end
end
