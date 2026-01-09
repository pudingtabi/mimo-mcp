defmodule Mimo.Cognitive.Amplifier.CoherenceValidator do
  @moduledoc """
  Validates logical consistency across reasoning chains.

  Detects contradictions, circular reasoning, unsupported leaps,
  and other coherence issues that undermine reasoning quality.

  ## Validation Types

  - `:contradiction` - Step N says X, Step M says NOT X
  - `:assumption_drift` - Assumptions changed mid-reasoning
  - `:scope_creep` - Reasoning drifted from original problem
  - `:circular` - A→B→C→A reasoning loops
  - `:unsupported_leap` - Conclusion doesn't follow from premises

  ## Integration

  Reuses claim extraction from InterleavedThinking.
  Builds on existing ThoughtEvaluator infrastructure.
  """

  require Logger

  @type issue_type ::
          :contradiction
          | :assumption_drift
          | :scope_creep
          | :circular
          | :unsupported_leap
          | :ungrounded_claim

  @type coherence_issue :: %{
          type: issue_type(),
          description: String.t(),
          steps_involved: [non_neg_integer()],
          severity: :major | :minor,
          resolution_prompt: String.t()
        }

  @type validation_result :: %{
          status: :coherent | :minor_issues | :major_issues,
          issues: [coherence_issue()],
          confidence_impact: float()
        }

  # Patterns that indicate potential issues
  @contradiction_markers [
    {"always", "never"},
    {"must", "cannot"},
    {"will", "won't"},
    {"is", "is not"},
    {"should", "should not"},
    {"true", "false"},
    {"correct", "incorrect"},
    {"yes", "no"}
  ]

  @doc """
  Validate coherence across all thoughts in a session.

  Returns a validation result with any detected issues.
  """
  @spec validate([map()], String.t()) :: validation_result()
  def validate(thoughts, original_problem) do
    if length(thoughts) < 2 do
      %{status: :coherent, issues: [], confidence_impact: 0.0}
    else
      contents = Enum.map(thoughts, & &1.content)

      # Run all validation checks
      issues =
        []
        |> check_contradictions(contents)
        |> check_scope_creep(contents, original_problem)
        |> check_unsupported_leaps(contents)
        |> check_circular_reasoning(contents)

      # Categorize result
      major_count = Enum.count(issues, &(&1.severity == :major))
      minor_count = Enum.count(issues, &(&1.severity == :minor))

      status =
        cond do
          major_count > 0 -> :major_issues
          minor_count > 0 -> :minor_issues
          true -> :coherent
        end

      confidence_impact = calculate_confidence_impact(issues)

      %{
        status: status,
        issues: issues,
        confidence_impact: confidence_impact
      }
    end
  end

  @doc """
  Validate a single new thought against existing chain.
  """
  @spec validate_thought(String.t(), [String.t()]) :: {:ok | :issues, [coherence_issue()]}
  def validate_thought(new_thought, existing_thoughts) do
    issues =
      []
      |> check_contradictions([new_thought | existing_thoughts])
      |> Enum.filter(fn issue ->
        # Only issues involving the new thought
        0 in issue.steps_involved
      end)

    if Enum.any?(issues, &(&1.severity == :major)) do
      {:issues, issues}
    else
      {:ok, issues}
    end
  end

  @doc """
  Generate resolution prompts for detected issues.
  """
  @spec generate_resolution_prompts([coherence_issue()]) :: [String.t()]
  def generate_resolution_prompts(issues) do
    issues
    |> Enum.filter(&(&1.severity == :major))
    |> Enum.map(& &1.resolution_prompt)
  end

  @doc """
  Format issues for display/injection.
  """
  @spec format_issues([coherence_issue()]) :: String.t()
  def format_issues([]), do: ""

  def format_issues(issues) do
    major =
      issues
      |> Enum.filter(&(&1.severity == :major))
      |> Enum.map(&"🚨 #{&1.description}")

    minor =
      issues
      |> Enum.filter(&(&1.severity == :minor))
      |> Enum.map(&"⚠️ #{&1.description}")

    parts = []

    parts =
      if major != [] do
        ["MAJOR COHERENCE ISSUES:\n" <> Enum.join(major, "\n") | parts]
      else
        parts
      end

    parts =
      if minor != [] do
        ["Minor concerns:\n" <> Enum.join(minor, "\n") | parts]
      else
        parts
      end

    Enum.reverse(parts) |> Enum.join("\n\n")
  end

  defp check_contradictions(issues, thoughts) do
    # Compare each pair of thoughts for contradictions
    indexed = Enum.with_index(thoughts)

    new_issues =
      for {thought_a, idx_a} <- indexed,
          {thought_b, idx_b} <- indexed,
          idx_a < idx_b,
          contradiction = find_contradiction(thought_a, thought_b),
          contradiction != nil do
        %{
          type: :contradiction,
          description:
            "Step #{idx_a + 1} and Step #{idx_b + 1} appear to contradict: #{contradiction}",
          steps_involved: [idx_a, idx_b],
          severity: :major,
          resolution_prompt: """
          You stated: "#{String.slice(thought_a, 0..100)}..." (Step #{idx_a + 1})
          But later: "#{String.slice(thought_b, 0..100)}..." (Step #{idx_b + 1})

          These appear to contradict. Please clarify which is correct and why.
          """
        }
      end

    issues ++ new_issues
  end

  defp find_contradiction(thought_a, thought_b) do
    # Skip false positives: sequential reasoning steps are not contradictions
    cond do
      sequential_reasoning?(thought_a) and sequential_reasoning?(thought_b) ->
        nil

      # STABILITY FIX: Skip when thoughts are about different subsystems/components
      # e.g., "Memory Search WORKS" vs "Code Index is NOT working" are not contradictions
      discusses_different_subsystems?(thought_a, thought_b) ->
        nil

      true ->
        check_marker_contradictions(thought_a, thought_b)
    end
  end

  # Check if two thoughts discuss different subsystems (not contradictions)
  defp discusses_different_subsystems?(thought_a, thought_b) do
    subsystem_patterns = [
      ~r/round\s*\d+[:\s]+(\w+)/i,
      ~r/(memory|code|file|terminal|web|reasoning|synapse|awakening|knowledge)\s*(search|index|system|store|tool)/i,
      ~r/(testing|checking|verifying|analyzing)\s+(\w+)\s+(system|tool|component)/i,
      # Bracketed subsystem names like [Memory System]
      ~r/\[([\w\s]+)\]/
    ]

    extract_subsystem = fn text ->
      Enum.find_value(subsystem_patterns, fn pattern ->
        case Regex.run(pattern, text) do
          [_, subsystem | _] -> String.downcase(subsystem)
          [match] -> String.downcase(match)
          _ -> nil
        end
      end)
    end

    subsystem_a = extract_subsystem.(thought_a)
    subsystem_b = extract_subsystem.(thought_b)

    # If both have identifiable subsystems and they're different, not a contradiction
    subsystem_a != nil and subsystem_b != nil and subsystem_a != subsystem_b
  end

  defp check_marker_contradictions(thought_a, thought_b) do
    a_lower = String.downcase(thought_a)
    b_lower = String.downcase(thought_b)

    # Check for marker pair contradictions
    Enum.find_value(@contradiction_markers, fn {pos, neg} ->
      a_has_pos = String.contains?(a_lower, pos)
      a_has_neg = String.contains?(a_lower, neg)
      b_has_pos = String.contains?(b_lower, pos)
      b_has_neg = String.contains?(b_lower, neg)

      # Check for XOR patterns on same subject
      cond do
        a_has_pos and b_has_neg and shares_subject?(a_lower, b_lower) ->
          "#{pos} vs #{neg}"

        a_has_neg and b_has_pos and shares_subject?(a_lower, b_lower) ->
          "#{neg} vs #{pos}"

        true ->
          nil
      end
    end)
  end

  # Check if thoughts are sequential reasoning steps that should not be flagged
  defp sequential_reasoning?(thought) do
    sequential_patterns = [
      ~r/^step\s*\d/i,
      ~r/^\d+\.\s/,
      ~r/^first[,:]/i,
      ~r/^second[,:]/i,
      ~r/^third[,:]/i,
      ~r/^next[,:]/i,
      ~r/^then[,:]/i,
      ~r/^finally[,:]/i,
      ~r/^thought\s*\d/i,
      ~r/^point\s*\d/i,
      ~r/^\[\d+\]/,
      ~r/^#\d+/
    ]

    Enum.any?(sequential_patterns, &Regex.match?(&1, thought))
  end

  defp shares_subject?(text_a, text_b) do
    # Extract significant nouns and check overlap
    words_a =
      text_a
      |> String.split(~r/\s+/)
      |> Enum.filter(&(String.length(&1) > 4))
      |> MapSet.new()

    words_b =
      text_b
      |> String.split(~r/\s+/)
      |> Enum.filter(&(String.length(&1) > 4))
      |> MapSet.new()

    overlap = MapSet.intersection(words_a, words_b) |> MapSet.size()

    # Require at least 3 shared significant words (reduced false positives)
    overlap >= 3
  end

  defp check_scope_creep(issues, thoughts, original_problem) do
    problem_terms = extract_key_terms(original_problem)

    # Check each thought for drift from original problem
    new_issues =
      thoughts
      |> Enum.with_index()
      |> Enum.flat_map(fn {thought, idx} ->
        thought_terms = extract_key_terms(thought)
        overlap = term_overlap(problem_terms, thought_terms)

        if overlap < 0.1 and String.length(thought) > 100 do
          [
            %{
              type: :scope_creep,
              description:
                "Step #{idx + 1} may have drifted from the original problem (low term overlap: #{Float.round(overlap * 100, 1)}%)",
              steps_involved: [idx],
              severity: :minor,
              resolution_prompt: """
              Your reasoning in Step #{idx + 1} seems to have drifted from the original problem:
              "#{String.slice(original_problem, 0..150)}..."

              Please verify this step is relevant to solving the original problem.
              """
            }
          ]
        else
          []
        end
      end)

    issues ++ new_issues
  end

  defp extract_key_terms(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/)
    |> Enum.filter(&(String.length(&1) > 3))
    |> Enum.reject(&stopword?/1)
    |> MapSet.new()
  end

  defp term_overlap(terms_a, terms_b) do
    if MapSet.size(terms_a) == 0 or MapSet.size(terms_b) == 0 do
      0.0
    else
      intersection = MapSet.intersection(terms_a, terms_b) |> MapSet.size()
      smaller = min(MapSet.size(terms_a), MapSet.size(terms_b))
      intersection / smaller
    end
  end

  defp stopword?(word) do
    word in ~w(the a an is are was were be been being have has had do does did
               will would could should may might must shall can this that these
               those what which who whom where when why how and or but if then
               else for with from into onto upon about above below between through)
  end

  defp check_unsupported_leaps(issues, thoughts) do
    # Check for conclusions that don't follow from previous reasoning
    new_issues =
      thoughts
      |> Enum.with_index()
      |> Enum.flat_map(fn {thought, idx} ->
        # Only check thoughts that look like conclusions
        if looks_like_conclusion?(thought) and idx > 0 do
          previous = Enum.take(thoughts, idx)
          support_score = calculate_support(thought, previous)

          if support_score < 0.3 do
            [
              %{
                type: :unsupported_leap,
                description:
                  "Step #{idx + 1} makes a conclusion that may not be fully supported by previous steps",
                steps_involved: [idx],
                severity: :minor,
                resolution_prompt: """
                Your conclusion in Step #{idx + 1}: "#{String.slice(thought, 0..100)}..."

                Please explain how this follows from your previous reasoning.
                What specific evidence or logic supports this conclusion?
                """
              }
            ]
          else
            []
          end
        else
          []
        end
      end)

    issues ++ new_issues
  end

  defp looks_like_conclusion?(thought) do
    conclusion_markers = [
      "therefore",
      "thus",
      "so ",
      "hence",
      "consequently",
      "in conclusion",
      "the answer is",
      "we can conclude",
      "this means",
      "the solution is"
    ]

    thought_lower = String.downcase(thought)
    Enum.any?(conclusion_markers, &String.contains?(thought_lower, &1))
  end

  defp calculate_support(conclusion, previous_thoughts) do
    # Check how much of the conclusion is grounded in previous thoughts
    conclusion_terms = extract_key_terms(conclusion)

    all_previous_terms =
      previous_thoughts
      |> Enum.flat_map(&extract_key_terms/1)
      |> MapSet.new()

    if MapSet.size(conclusion_terms) == 0 do
      1.0
    else
      intersection = MapSet.intersection(conclusion_terms, all_previous_terms) |> MapSet.size()
      intersection / MapSet.size(conclusion_terms)
    end
  end

  defp check_circular_reasoning(issues, thoughts) do
    # Simple check: does the last thought just restate the first?
    if length(thoughts) >= 3 do
      first = List.first(thoughts)
      last = List.last(thoughts)

      similarity = text_similarity(first, last)

      if similarity > 0.8 do
        issues ++
          [
            %{
              type: :circular,
              description:
                "Reasoning appears circular - conclusion restates the premise (#{Float.round(similarity * 100, 1)}% similar)",
              steps_involved: [0, length(thoughts) - 1],
              severity: :major,
              resolution_prompt: """
              Your reasoning may be circular. The conclusion:
              "#{String.slice(last, 0..100)}..."

              Is very similar to the starting premise:
              "#{String.slice(first, 0..100)}..."

              Please provide new information or reasoning that advances beyond the premise.
              """
            }
          ]
      else
        issues
      end
    else
      issues
    end
  end

  defp calculate_confidence_impact(issues) do
    if issues == [] do
      0.0
    else
      major_penalty = Enum.count(issues, &(&1.severity == :major)) * 0.15
      minor_penalty = Enum.count(issues, &(&1.severity == :minor)) * 0.05

      -1 * min(0.5, major_penalty + minor_penalty)
    end
  end

  defp text_similarity(text_a, text_b) do
    words_a = extract_words(text_a)
    words_b = extract_words(text_b)

    if MapSet.size(words_a) == 0 or MapSet.size(words_b) == 0 do
      0.0
    else
      intersection = MapSet.intersection(words_a, words_b) |> MapSet.size()
      union = MapSet.union(words_a, words_b) |> MapSet.size()
      intersection / max(union, 1)
    end
  end

  defp extract_words(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/)
    |> Enum.filter(&(String.length(&1) > 2))
    |> MapSet.new()
  end
end
