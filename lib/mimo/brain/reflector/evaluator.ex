defmodule Mimo.Brain.Reflector.Evaluator do
  @moduledoc """
  Evaluates output quality across multiple dimensions.

  Part of SPEC-043: Reflective Intelligence System.

  Dimensions evaluated:
  - **Correctness**: Does the output contain accurate information?
  - **Completeness**: Does it address all parts of the query?
  - **Confidence**: How certain are we about this output?
  - **Clarity**: Is the output clear and well-structured?
  - **Grounding**: Is the output grounded in stored knowledge?
  - **Error Risk**: What's the probability of errors in the output?

  ## Example

      evaluation = Evaluator.evaluate(output, %{query: "...", memories: [...]})
      if evaluation.aggregate_score >= 0.75 do
        {:ok, output}
      else
        {:refine, evaluation.suggestions}
      end
  """

  alias Mimo.Cognitive.{ConfidenceAssessor, ThoughtEvaluator}

  @type dimension_scores :: %{
          correctness: float(),
          completeness: float(),
          confidence: float(),
          clarity: float(),
          grounding: float(),
          error_risk: float()
        }

  @type issue :: %{
          dimension: atom(),
          severity: :high | :medium | :low,
          description: String.t()
        }

  @type suggestion :: %{
          priority: :high | :medium | :low,
          action: String.t(),
          reason: String.t()
        }

  @type evaluation :: %{
          scores: dimension_scores(),
          aggregate_score: float(),
          issues: [issue()],
          suggestions: [suggestion()],
          quality_level: :excellent | :good | :acceptable | :poor,
          metadata: map()
        }

  @default_weights %{
    correctness: 0.25,
    completeness: 0.20,
    confidence: 0.20,
    clarity: 0.15,
    grounding: 0.15,
    error_penalty: 0.30
  }

  @doc """
  Evaluate output quality across all dimensions.

  ## Parameters

  - `output` - The output content to evaluate
  - `context` - Map containing:
    - `:query` - The original query/prompt
    - `:memories` - Related memories retrieved
    - `:tool_results` - Any tool outputs included
    - `:reasoning_steps` - Reasoning chain if available

  ## Options

  - `:weights` - Custom dimension weights (default: balanced)
  - `:skip_confidence` - Skip confidence assessment (faster)
  - `:strict` - Apply stricter thresholds
  """
  @spec evaluate(String.t(), map(), keyword()) :: evaluation()
  def evaluate(output, context, opts \\ []) do
    weights = Keyword.get(opts, :weights, @default_weights)
    skip_confidence = Keyword.get(opts, :skip_confidence, false)

    # Calculate individual dimension scores
    scores = %{
      correctness: check_correctness(output, context),
      completeness: check_completeness(output, context),
      confidence: if(skip_confidence, do: 0.5, else: estimate_confidence(output, context)),
      clarity: assess_clarity(output),
      grounding: validate_grounding(output, context),
      error_risk: detect_error_risk(output, context)
    }

    # Calculate aggregate score
    aggregate = calculate_aggregate(scores, weights)

    # Generate issues based on low scores
    issues = generate_issues(scores, output, context)

    # Generate improvement suggestions
    suggestions = generate_suggestions(scores, issues, output, context)

    # Determine quality level
    quality_level = determine_quality_level(aggregate)

    %{
      scores: scores,
      aggregate_score: Float.round(aggregate, 3),
      issues: issues,
      suggestions: suggestions,
      quality_level: quality_level,
      metadata: %{
        output_length: String.length(output),
        evaluated_at: DateTime.utc_now(),
        weights_used: weights
      }
    }
  end

  @doc """
  Quick evaluation for fast feedback (skips expensive checks).
  """
  @spec quick_evaluate(String.t(), map()) :: %{score: float(), pass: boolean()}
  def quick_evaluate(output, context) do
    # Only check clarity and basic grounding
    clarity = assess_clarity(output)
    basic_grounding = check_basic_grounding(output, context)

    score = (clarity + basic_grounding) / 2

    %{
      score: Float.round(score, 3),
      pass: score >= 0.5
    }
  end

  @doc """
  Check correctness - does output contain accurate information?
  """
  @spec check_correctness(String.t(), map()) :: float()
  def check_correctness(output, context) do
    # Extract claims from output
    claims = extract_claims(output)

    if claims == [] do
      # No verifiable claims - neutral score
      0.6
    else
      # Check claims against stored knowledge
      memories = context[:memories] || []

      verified_count =
        claims
        |> Enum.count(fn claim ->
          verify_claim_against_memories(claim, memories)
        end)

      # Calculate ratio of verified claims
      ratio = verified_count / max(length(claims), 1)

      # Check for contradictions
      contradictions = find_contradictions(output, memories)

      # Penalize contradictions heavily
      penalty = length(contradictions) * 0.15

      max(0.0, min(1.0, ratio - penalty))
    end
  end

  @doc """
  Check completeness - does output address all parts of the query?
  """
  @spec check_completeness(String.t(), map()) :: float()
  def check_completeness(output, context) do
    query = context[:query] || ""

    if query == "" do
      # No query to compare against
      0.7
    else
      # Extract key requirements from query
      requirements = extract_requirements(query)

      if requirements == [] do
        0.7
      else
        # Check how many requirements are addressed
        addressed_count =
          requirements
          |> Enum.count(fn req ->
            String.contains?(String.downcase(output), String.downcase(req))
          end)

        ratio = addressed_count / max(length(requirements), 1)

        # Bonus for comprehensive coverage
        bonus = if ratio >= 0.9, do: 0.1, else: 0.0

        min(1.0, ratio + bonus)
      end
    end
  end

  @doc """
  Estimate confidence in the output.
  Delegates to ConfidenceAssessor for sophisticated assessment.
  """
  @spec estimate_confidence(String.t(), map()) :: float()
  def estimate_confidence(output, context) do
    query = context[:query] || output

    # Use existing confidence assessor
    case ConfidenceAssessor.quick_assess(query) do
      :high -> 0.9
      :medium -> 0.6
      :unknown -> 0.3
    end
  end

  @doc """
  Assess clarity of the output.
  """
  @spec assess_clarity(String.t()) :: float()
  def assess_clarity(output) do
    # Check various clarity factors
    factors = %{
      has_structure: has_clear_structure?(output),
      reasonable_length: reasonable_length?(output),
      no_jargon_overload: not jargon_heavy?(output),
      coherent_sentences: coherent_sentences?(output),
      no_repetition: not highly_repetitive?(output)
    }

    # Calculate weighted score
    weights = %{
      has_structure: 0.25,
      reasonable_length: 0.15,
      no_jargon_overload: 0.20,
      coherent_sentences: 0.25,
      no_repetition: 0.15
    }

    factors
    |> Enum.reduce(0.0, fn {factor, passed}, acc ->
      weight = Map.get(weights, factor, 0.2)
      acc + if(passed, do: weight, else: 0.0)
    end)
  end

  @doc """
  Validate that output is grounded in stored knowledge.
  """
  @spec validate_grounding(String.t(), map()) :: float()
  def validate_grounding(output, context) do
    memories = context[:memories] || []
    tool_results = context[:tool_results] || []

    cond do
      # If we have tool results, check grounding in those
      tool_results != [] ->
        grounded_in_tools = check_grounding_in_tools(output, tool_results)
        if grounded_in_tools, do: 0.9, else: 0.5

      # If we have memories, check grounding in those
      memories != [] ->
        check_grounding_in_memories(output, memories)

      # No grounding sources available
      true ->
        # Uncertain grounding
        0.4
    end
  end

  @doc """
  Detect potential error risks in the output.
  Returns a risk score (higher = more risky).
  """
  @spec detect_error_risk(String.t(), map()) :: float()
  def detect_error_risk(output, context) do
    # Use ThoughtEvaluator's hallucination detection
    thought_eval =
      ThoughtEvaluator.evaluate(output, %{
        previous_thoughts: context[:reasoning_steps] || [],
        problem: context[:query] || ""
      })

    # Additional risk checks
    risk_factors = [
      # Overconfident language without backing
      if(has_overconfident_claims?(output), do: 0.2, else: 0.0),

      # Specific numbers without sources
      if(has_unverified_specifics?(output), do: 0.15, else: 0.0),

      # Code that might not work
      if(has_potentially_broken_code?(output), do: 0.1, else: 0.0),

      # Converts thought evaluator issues to risk
      length(thought_eval.issues) * 0.05
    ]

    total_risk = Enum.sum(risk_factors)

    # Cap at 1.0
    min(1.0, total_risk)
  end

  defp calculate_aggregate(scores, weights) do
    # Positive contributions
    positive =
      [:correctness, :completeness, :confidence, :clarity, :grounding]
      |> Enum.map(fn dim ->
        score = Map.get(scores, dim, 0.5)
        weight = Map.get(weights, dim, 0.2)
        score * weight
      end)
      |> Enum.sum()

    # Error risk is a penalty
    error_penalty = scores.error_risk * Map.get(weights, :error_penalty, 0.3)

    max(0.0, min(1.0, positive - error_penalty))
  end

  defp determine_quality_level(score) do
    cond do
      score >= 0.85 -> :excellent
      score >= 0.70 -> :good
      score >= 0.50 -> :acceptable
      true -> :poor
    end
  end

  defp generate_issues(scores, output, context) do
    issues = []

    # Correctness issues
    issues =
      if scores.correctness < 0.5 do
        [
          %{
            dimension: :correctness,
            severity: if(scores.correctness < 0.3, do: :high, else: :medium),
            description: "Output may contain inaccurate information"
          }
          | issues
        ]
      else
        issues
      end

    # Completeness issues
    issues =
      if scores.completeness < 0.6 do
        missing = find_missing_requirements(output, context[:query] || "")

        [
          %{
            dimension: :completeness,
            severity: if(scores.completeness < 0.4, do: :high, else: :medium),
            description:
              "Output may not fully address the query" <>
                if(missing != [], do: ": #{Enum.join(missing, ", ")}", else: "")
          }
          | issues
        ]
      else
        issues
      end

    # Confidence issues
    issues =
      if scores.confidence < 0.4 do
        [
          %{
            dimension: :confidence,
            severity: :medium,
            description: "Low confidence in the accuracy of this response"
          }
          | issues
        ]
      else
        issues
      end

    # Clarity issues
    issues =
      if scores.clarity < 0.5 do
        [
          %{
            dimension: :clarity,
            severity: if(scores.clarity < 0.3, do: :high, else: :medium),
            description: "Output may be unclear or poorly structured"
          }
          | issues
        ]
      else
        issues
      end

    # Grounding issues
    issues =
      if scores.grounding < 0.4 do
        [
          %{
            dimension: :grounding,
            severity: :high,
            description: "Output lacks grounding in stored knowledge or tool results"
          }
          | issues
        ]
      else
        issues
      end

    # Error risk issues
    issues =
      if scores.error_risk > 0.3 do
        [
          %{
            dimension: :error_risk,
            severity: if(scores.error_risk > 0.5, do: :high, else: :medium),
            description: "Elevated risk of errors or hallucinations"
          }
          | issues
        ]
      else
        issues
      end

    Enum.reverse(issues)
  end

  defp generate_suggestions(scores, issues, _output, _context) do
    suggestions = []

    # Generate suggestions based on issues
    suggestions =
      if Enum.any?(issues, &(&1.dimension == :correctness)) do
        [
          %{
            priority: :high,
            action: "Verify factual claims against stored memories or external sources",
            reason: "Correctness score is below threshold"
          }
          | suggestions
        ]
      else
        suggestions
      end

    suggestions =
      if Enum.any?(issues, &(&1.dimension == :completeness)) do
        [
          %{
            priority: :high,
            action: "Address all parts of the original query",
            reason: "Some requirements may not be covered"
          }
          | suggestions
        ]
      else
        suggestions
      end

    suggestions =
      if Enum.any?(issues, &(&1.dimension == :grounding)) do
        [
          %{
            priority: :high,
            action: "Add references to stored knowledge or tool outputs",
            reason: "Output lacks sufficient grounding"
          }
          | suggestions
        ]
      else
        suggestions
      end

    suggestions =
      if scores.clarity < 0.6 do
        [
          %{
            priority: :medium,
            action: "Improve structure with clear sections or bullet points",
            reason: "Output could be clearer"
          }
          | suggestions
        ]
      else
        suggestions
      end

    suggestions =
      if scores.error_risk > 0.4 do
        [
          %{
            priority: :high,
            action: "Add qualifiers to uncertain claims and verify specific details",
            reason: "Risk of errors detected"
          }
          | suggestions
        ]
      else
        suggestions
      end

    Enum.reverse(suggestions)
  end

  defp extract_claims(output) do
    # Simple claim extraction: sentences that look like factual statements
    output
    |> String.split(~r/[.!?]/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(String.length(&1) < 10))
    |> Enum.filter(&looks_like_claim?/1)
    # Limit to 10 claims for performance
    |> Enum.take(10)
  end

  defp looks_like_claim?(sentence) do
    # Sentences that make factual assertions
    indicators =
      ~r/\b(is|are|was|were|has|have|does|do|can|will|must|should|always|never|every|all|most|many|usually|typically)\b/i

    String.match?(sentence, indicators)
  end

  defp verify_claim_against_memories(claim, memories) do
    # Check if claim has semantic overlap with memories
    claim_words = extract_significant_words(claim)

    Enum.any?(memories, fn memory ->
      content = memory[:content] || memory["content"] || ""
      memory_words = extract_significant_words(content)

      overlap =
        MapSet.intersection(
          MapSet.new(claim_words),
          MapSet.new(memory_words)
        )
        |> MapSet.size()

      overlap >= 2
    end)
  end

  defp find_contradictions(output, memories) do
    # Look for contradictions between output and memories
    # This is a simple heuristic - could be enhanced with NLI
    output_claims = extract_claims(output)

    contradictions =
      for claim <- output_claims,
          memory <- memories,
          contradicts?(claim, memory[:content] || memory["content"] || ""),
          do: %{claim: claim, conflicts_with: memory[:content]}

    contradictions
  end

  defp contradicts?(claim, memory_content) do
    # Simple contradiction detection using negation patterns
    claim_lower = String.downcase(claim)
    memory_lower = String.downcase(memory_content)

    # Check for direct negation patterns
    negation_patterns = [
      {~r/\bis not\b/, ~r/\bis\b/},
      {~r/\bcannot\b/, ~r/\bcan\b/},
      {~r/\bnever\b/, ~r/\balways\b/},
      {~r/\bfalse\b/, ~r/\btrue\b/}
    ]

    Enum.any?(negation_patterns, fn {neg, pos} ->
      (String.match?(claim_lower, neg) and String.match?(memory_lower, pos)) or
        (String.match?(claim_lower, pos) and String.match?(memory_lower, neg))
    end)
  end

  defp extract_requirements(query) do
    # Extract question words and key nouns
    query
    |> String.downcase()
    |> String.split(~r/[\s,]+/)
    |> Enum.reject(fn x -> String.length(x) < 3 or common_word?(x) end)
    |> Enum.take(10)
  end

  defp find_missing_requirements(output, query) do
    requirements = extract_requirements(query)
    output_lower = String.downcase(output)

    requirements
    |> Enum.reject(fn req ->
      String.contains?(output_lower, req)
    end)
    |> Enum.take(3)
  end

  defp extract_significant_words(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, "")
    |> String.split()
    |> Enum.reject(fn x -> String.length(x) < 3 or common_word?(x) end)
  end

  defp common_word?(word) do
    common_words = ~w(the a an is are was were be been being have has had
      do does did will would could should may might must can
      this that these those what when where which who how
      for from with about into through and but or not
      to of in on at by it its i we you they them their)

    word in common_words
  end

  # Clarity helpers

  defp has_clear_structure?(output) do
    # Check for headers, bullets, or numbered lists
    has_headers = String.match?(output, ~r/^#+\s|\n#+\s/m)
    has_bullets = String.match?(output, ~r/^[-*]\s|\n[-*]\s/m)
    has_numbers = String.match?(output, ~r/^\d+\.\s|\n\d+\.\s/m)
    has_paragraphs = String.split(output, ~r/\n\n/) |> length() > 1

    has_headers or has_bullets or has_numbers or has_paragraphs
  end

  defp reasonable_length?(output) do
    len = String.length(output)
    len >= 20 and len <= 50_000
  end

  defp jargon_heavy?(output) do
    # Check for excessive technical jargon without explanations
    jargon_patterns = ~r/\b(paradigm|synergy|leverage|utilize|optimize|scalab\w*|implementat\w*)\b/i
    jargon_count = Regex.scan(jargon_patterns, output) |> length()
    word_count = output |> String.split() |> length()

    jargon_count > word_count * 0.1
  end

  defp coherent_sentences?(output) do
    # Check that sentences have reasonable length
    sentences =
      String.split(output, ~r/[.!?]+/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if sentences == [] do
      false
    else
      avg_length = Enum.sum(Enum.map(sentences, &String.length/1)) / length(sentences)
      avg_length >= 10 and avg_length <= 500
    end
  end

  defp highly_repetitive?(output) do
    # Check for repeated phrases
    words = output |> String.downcase() |> String.split()
    unique_words = Enum.uniq(words)

    if length(words) < 10 do
      false
    else
      uniqueness_ratio = length(unique_words) / length(words)
      uniqueness_ratio < 0.3
    end
  end

  # Grounding helpers

  defp check_basic_grounding(output, context) do
    memories = context[:memories] || []

    if memories == [] do
      0.5
    else
      # Simple word overlap check
      output_words = extract_significant_words(output) |> MapSet.new()

      memory_words =
        memories
        |> Enum.flat_map(fn m ->
          content = m[:content] || m["content"] || ""
          extract_significant_words(content)
        end)
        |> MapSet.new()

      overlap = MapSet.intersection(output_words, memory_words) |> MapSet.size()

      min(1.0, overlap / 10.0)
    end
  end

  defp check_grounding_in_memories(output, memories) do
    # Check how much of the output is grounded in memories
    output_words = extract_significant_words(output) |> MapSet.new()

    grounded_words =
      memories
      |> Enum.flat_map(fn m ->
        content = m[:content] || m["content"] || ""
        extract_significant_words(content)
      end)
      |> MapSet.new()
      |> MapSet.intersection(output_words)
      |> MapSet.size()

    output_word_count = MapSet.size(output_words)

    if output_word_count == 0 do
      0.5
    else
      grounding_ratio = grounded_words / output_word_count
      # Scale up since not all words need grounding
      min(1.0, grounding_ratio * 2)
    end
  end

  defp check_grounding_in_tools(output, tool_results) do
    # Check if output mentions or reflects tool results
    tool_content =
      tool_results
      |> Enum.map_join(" ", fn r ->
        cond do
          is_binary(r) -> r
          is_map(r) -> Jason.encode!(r) |> String.slice(0, 1000)
          true -> inspect(r) |> String.slice(0, 1000)
        end
      end)

    output_words = extract_significant_words(output) |> MapSet.new()
    tool_words = extract_significant_words(tool_content) |> MapSet.new()

    overlap = MapSet.intersection(output_words, tool_words) |> MapSet.size()

    overlap >= 3
  end

  # Error risk helpers

  defp has_overconfident_claims?(output) do
    overconfident_patterns =
      ~r/\b(definitely|certainly|always|never|must be|guaranteed|100%|impossible)\b/i

    String.match?(output, overconfident_patterns)
  end

  defp has_unverified_specifics?(output) do
    # Specific numbers or dates without context
    has_numbers = String.match?(output, ~r/\b\d{4,}\b/)
    has_percentages = String.match?(output, ~r/\b\d+\.?\d*%\b/)
    has_attribution = String.match?(output, ~r/\b(according to|source|based on|from)\b/i)

    (has_numbers or has_percentages) and not has_attribution
  end

  defp has_potentially_broken_code?(output) do
    # Check for code blocks that might have issues
    has_code = String.match?(output, ~r/```[\w]*\n/)

    if has_code do
      # Check for common error patterns in code
      error_patterns = [
        # Placeholder ellipsis
        ~r/\.\.\./,
        ~r/TODO/i,
        ~r/FIXME/i,
        ~r/undefined/,
        ~r/not implemented/i
      ]

      Enum.any?(error_patterns, &String.match?(output, &1))
    else
      false
    end
  end
end
