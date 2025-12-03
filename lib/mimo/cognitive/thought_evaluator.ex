defmodule Mimo.Cognitive.ThoughtEvaluator do
  @moduledoc """
  Evaluates the quality of reasoning steps.

  Provides feedback on individual thoughts in a reasoning chain,
  checking for logical flow, progress, and potential errors.

  ## Evaluation Criteria

  - **Logical Flow**: Does this step follow from previous ones?
  - **Progress**: Does this step move toward the solution?
  - **Errors**: Are there logical fallacies or contradictions?
  - **Hallucination Risk**: Is the step grounded in evidence?
  """

  alias Mimo.Cognitive.{ConfidenceAssessor, ReasoningSession}

  @type evaluation :: %{
          quality: :good | :maybe | :bad,
          score: float(),
          feedback: String.t(),
          suggestions: [String.t()],
          issues: [String.t()]
        }

  @type thought :: ReasoningSession.thought()

  # Patterns indicating problematic reasoning
  @assumption_patterns ~r/\b(assume|assuming|suppose|supposing|presumably|probably|likely|might be)\b/i
  @certainty_patterns ~r/\b(definitely|certainly|obviously|clearly|always|never|must be|has to be)\b/i
  @vague_patterns ~r/\b(somehow|something|somewhere|some kind of|sort of|kind of|maybe)\b/i
  @contradiction_patterns ~r/\b(but|however|although|yet|despite|nevertheless)\b/i

  @doc """
  Evaluate a single thought for quality.

  ## Parameters

  - `thought` - The thought content to evaluate
  - `context` - Map containing:
    - `:previous_thoughts` - List of prior thoughts
    - `:problem` - The original problem
    - `:strategy` - The reasoning strategy being used
  """
  @spec evaluate(String.t(), map()) :: evaluation()
  def evaluate(thought, context \\ %{}) do
    previous_thoughts = Map.get(context, :previous_thoughts, [])
    problem = Map.get(context, :problem, "")

    # Run all checks
    flow_result = check_logical_flow(thought, previous_thoughts)
    progress_result = check_progress(thought, problem, previous_thoughts)
    error_result = detect_errors(thought, previous_thoughts)
    hallucination_result = detect_hallucination_risk(thought)

    # Aggregate issues and suggestions
    issues =
      [flow_result.issue, progress_result.issue, error_result.issue, hallucination_result.issue]
      |> Enum.reject(&is_nil/1)

    suggestions =
      [
        flow_result.suggestion,
        progress_result.suggestion,
        error_result.suggestion,
        hallucination_result.suggestion
      ]
      |> Enum.reject(&is_nil/1)

    # Calculate overall score
    scores = [
      flow_result.score,
      progress_result.score,
      error_result.score,
      hallucination_result.score
    ]

    avg_score = Enum.sum(scores) / length(scores)

    # Determine quality
    quality =
      cond do
        avg_score >= 0.7 -> :good
        avg_score >= 0.4 -> :maybe
        true -> :bad
      end

    # Generate feedback
    feedback = generate_feedback(quality, issues, suggestions)

    %{
      quality: quality,
      score: Float.round(avg_score, 3),
      feedback: feedback,
      suggestions: suggestions,
      issues: issues
    }
  end

  @doc """
  Evaluate thought quality within a session context.
  """
  @spec evaluate_in_session(String.t(), ReasoningSession.session()) :: evaluation()
  def evaluate_in_session(thought, session) do
    previous_contents = Enum.map(session.thoughts, & &1.content)

    context = %{
      previous_thoughts: previous_contents,
      problem: session.problem,
      strategy: session.strategy
    }

    evaluate(thought, context)
  end

  @doc """
  Check if a thought follows logically from previous thoughts.
  """
  @spec check_logical_flow(String.t(), [String.t()]) :: %{
          score: float(),
          issue: String.t() | nil,
          suggestion: String.t() | nil
        }
  def check_logical_flow(thought, previous_thoughts) do
    if previous_thoughts == [] do
      # First thought - just check it makes sense
      %{score: 0.8, issue: nil, suggestion: nil}
    else
      last_thought = List.last(previous_thoughts)

      # Check for logical connectors
      has_connector =
        String.match?(
          thought,
          ~r/^\s*(therefore|so|thus|hence|because|since|as a result|consequently|this means|from this|next|then|building on)\b/i
        )

      # Check for abrupt topic shifts (simple heuristic)
      thought_words = extract_significant_words(thought)
      last_words = extract_significant_words(last_thought)

      overlap =
        MapSet.intersection(MapSet.new(thought_words), MapSet.new(last_words)) |> MapSet.size()

      flow_score =
        cond do
          has_connector and overlap > 0 -> 1.0
          has_connector -> 0.8
          overlap > 2 -> 0.7
          overlap > 0 -> 0.5
          true -> 0.3
        end

      issue =
        if flow_score < 0.5 do
          "Thought may not follow logically from previous steps"
        end

      suggestion =
        if flow_score < 0.5 do
          "Consider connecting this step to the previous reasoning with 'therefore', 'because', or explaining the link"
        end

      %{score: flow_score, issue: issue, suggestion: suggestion}
    end
  end

  @doc """
  Check if a thought makes progress toward solving the problem.
  """
  @spec check_progress(String.t(), String.t(), [String.t()]) :: %{
          score: float(),
          issue: String.t() | nil,
          suggestion: String.t() | nil
        }
  def check_progress(thought, problem, previous_thoughts) do
    # Extract problem keywords
    problem_words = extract_significant_words(problem)
    thought_words = extract_significant_words(thought)

    # Check relevance to problem
    relevance =
      MapSet.intersection(MapSet.new(problem_words), MapSet.new(thought_words)) |> MapSet.size()

    # Check if thought is just repeating previous content
    is_repetitive =
      Enum.any?(previous_thoughts, fn prev ->
        similarity = calculate_similarity(thought, prev)
        similarity > 0.8
      end)

    # Check for progress indicators
    has_progress_indicators =
      String.match?(
        thought,
        ~r/\b(found|determined|calculated|discovered|realized|concluded|answer is|result is|solution is)\b/i
      )

    progress_score =
      cond do
        is_repetitive -> 0.2
        has_progress_indicators and relevance > 0 -> 1.0
        relevance > 2 -> 0.8
        relevance > 0 -> 0.6
        true -> 0.4
      end

    issue =
      cond do
        is_repetitive -> "This step appears to repeat previous reasoning"
        relevance == 0 -> "This step may not be relevant to the problem"
        true -> nil
      end

    suggestion =
      cond do
        is_repetitive -> "Focus on new insights rather than restating what was already established"
        relevance == 0 -> "Ensure this reasoning relates to the original problem"
        true -> nil
      end

    %{score: progress_score, issue: issue, suggestion: suggestion}
  end

  @doc """
  Detect potential logical errors in reasoning.
  """
  @spec detect_errors(String.t(), [String.t()]) :: %{
          score: float(),
          issue: String.t() | nil,
          suggestion: String.t() | nil
        }
  def detect_errors(thought, _previous_thoughts) do
    issues = []

    # Check for unsupported certainty
    issues =
      if String.match?(thought, @certainty_patterns) and
           not String.match?(thought, ~r/\b(because|since|given|from)\b/i) do
        ["Unsupported certainty claim" | issues]
      else
        issues
      end

    # Check for excessive assumptions
    assumption_count = Regex.scan(@assumption_patterns, thought) |> length()

    issues =
      if assumption_count > 2 do
        ["Too many assumptions (#{assumption_count})" | issues]
      else
        issues
      end

    # Check for internal contradiction
    issues =
      if String.match?(thought, @contradiction_patterns) and String.length(thought) < 100 do
        # Short thoughts with contradictions are suspicious
        ["Possible internal contradiction" | issues]
      else
        issues
      end

    error_score =
      cond do
        length(issues) >= 2 -> 0.2
        length(issues) == 1 -> 0.5
        true -> 0.9
      end

    %{
      score: error_score,
      issue: if(issues != [], do: Enum.join(issues, "; ")),
      suggestion: if(issues != [], do: "Review and justify any assumptions or certainty claims")
    }
  end

  @doc """
  Detect potential hallucination risk in a thought.
  """
  @spec detect_hallucination_risk(String.t()) :: %{
          score: float(),
          issue: String.t() | nil,
          suggestion: String.t() | nil
        }
  def detect_hallucination_risk(thought) do
    risk_factors = 0

    # Vague language often indicates uncertainty being hidden
    vague_count = Regex.scan(@vague_patterns, thought) |> length()
    risk_factors = risk_factors + vague_count

    # Specific numbers or facts without justification
    has_specific_numbers =
      String.match?(thought, ~r/\b\d{3,}\b/) or String.match?(thought, ~r/\b\d+\.\d+%\b/)

    has_justification = String.match?(thought, ~r/\b(because|according to|based on|from|given)\b/i)

    risk_factors =
      if has_specific_numbers and not has_justification do
        risk_factors + 2
      else
        risk_factors
      end

    # Quotes without attribution
    has_quotes = String.match?(thought, ~r/"[^"]+"|'[^']+'/)
    has_attribution = String.match?(thought, ~r/\b(said|stated|according to|wrote)\b/i)

    risk_factors =
      if has_quotes and not has_attribution do
        risk_factors + 1
      else
        risk_factors
      end

    hallucination_score =
      cond do
        risk_factors >= 3 -> 0.2
        risk_factors >= 2 -> 0.4
        risk_factors >= 1 -> 0.6
        true -> 0.9
      end

    issue =
      if risk_factors >= 2 do
        "Potential hallucination risk - claims may lack grounding"
      end

    suggestion =
      if risk_factors >= 1 do
        "Verify specific claims and provide sources where possible"
      end

    %{score: hallucination_score, issue: issue, suggestion: suggestion}
  end

  @doc """
  Quick confidence check for a thought.
  """
  @spec quick_confidence(String.t()) :: float()
  def quick_confidence(thought) do
    # Use existing confidence assessor for quick check
    case ConfidenceAssessor.quick_assess(thought) do
      :high -> 0.9
      :medium -> 0.6
      :unknown -> 0.1
    end
  end

  # Private helpers

  defp extract_significant_words(text) do
    common_words = MapSet.new(~w(
      the a an is are was were be been being have has had
      do does did will would could should may might must can
      this that these those what when where which who how
      for from with about into through and but or not
      to of in on at by it its i we you they them their
    ))

    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, "")
    |> String.split()
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.reject(&MapSet.member?(common_words, &1))
  end

  defp calculate_similarity(text1, text2) do
    words1 = extract_significant_words(text1) |> MapSet.new()
    words2 = extract_significant_words(text2) |> MapSet.new()

    if MapSet.size(words1) == 0 or MapSet.size(words2) == 0 do
      0.0
    else
      intersection = MapSet.intersection(words1, words2) |> MapSet.size()
      union = MapSet.union(words1, words2) |> MapSet.size()
      intersection / union
    end
  end

  defp generate_feedback(quality, issues, suggestions) do
    base =
      case quality do
        :good -> "Good reasoning step."
        :maybe -> "Acceptable step with some concerns."
        :bad -> "This reasoning step has significant issues."
      end

    issue_text =
      if issues != [] do
        " Issues: #{Enum.join(issues, "; ")}."
      else
        ""
      end

    suggestion_text =
      if suggestions != [] and quality != :good do
        " Suggestions: #{List.first(suggestions)}."
      else
        ""
      end

    base <> issue_text <> suggestion_text
  end
end
