defmodule Mimo.Cognitive.Amplifier.ChallengeGenerator do
  @moduledoc """
  Generates counter-arguments and devil's advocate challenges.

  Forces the LLM to address potential weaknesses in its reasoning
  before concluding. Prevents confirmation bias and shallow thinking.

  ## Challenge Types

  - `:negation` - What if the opposite is true?
  - `:edge_case` - What happens at extremes?
  - `:alternative` - What other approaches exist?
  - `:failure_mode` - How could this fail?
  - `:stakeholder` - Who might disagree?
  - `:historical` - When has this failed before?

  ## Challenge Severity

  - `:must_address` - Blocking - cannot conclude without addressing
  - `:should_consider` - Warning - strongly recommended to address
  - `:optional` - Informational - consider if time permits

  ## Integration with Neuro+ML

  - Uses CorrectionLearning to surface past failures
  - Uses EdgePredictor to find blind spots
  - Uses Memory to find contradicting facts
  """

  require Logger

  alias Mimo.Brain.CorrectionLearning
  alias Mimo.Brain.Memory

  @type challenge_type ::
          :negation
          | :edge_case
          | :alternative
          | :failure_mode
          | :stakeholder
          | :historical
          | :contradiction

  @type severity :: :must_address | :should_consider | :optional

  @type challenge :: %{
          type: challenge_type(),
          content: String.t(),
          severity: severity(),
          source: atom(),
          context: map()
        }

  # Challenge templates by type
  @challenge_templates %{
    negation: [
      "What if the opposite is true? Consider: %{claim} might be wrong because...",
      "Challenge your assumption: Why might %{claim} NOT be the case?",
      "Devil's advocate: Argue against your position on %{topic}."
    ],
    edge_case: [
      "What happens if %{variable} is at its extreme (zero, maximum, null)?",
      "Consider edge cases: What if there are no %{items}? What if there are millions?",
      "What boundary conditions could break this approach?"
    ],
    alternative: [
      "What are 2-3 alternative approaches to %{problem}?",
      "If you couldn't use %{approach}, what would you do instead?",
      "What would a completely different solution look like?"
    ],
    failure_mode: [
      "How could this solution fail? List at least 3 failure modes.",
      "What could go wrong with %{approach}?",
      "Under what conditions would this approach break down?"
    ],
    stakeholder: [
      "Who might disagree with this approach and why?",
      "What objections might a %{stakeholder} have?",
      "Consider the perspective of someone who has to maintain this."
    ],
    historical: [
      "When has a similar approach failed in the past?",
      "What lessons from past failures apply here?",
      "What patterns of failure should we avoid?"
    ]
  }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Generate challenges for a thought or reasoning step.

  Combines template-based, memory-based, and correction-based challenges.
  """
  @spec generate(String.t(), map(), keyword()) :: [challenge()]
  def generate(thought, context \\ %{}, opts \\ []) do
    max_challenges = Keyword.get(opts, :max_challenges, 4)
    types = Keyword.get(opts, :types, [:negation, :alternative, :failure_mode])

    # Generate from multiple sources
    template_challenges = generate_from_templates(thought, context, types)
    memory_challenges = generate_from_memory(thought, context)
    correction_challenges = generate_from_corrections(thought, context)

    # Combine and deduplicate
    all_challenges =
      (template_challenges ++ memory_challenges ++ correction_challenges)
      |> Enum.uniq_by(& &1.content)
      |> assign_severity()
      |> Enum.sort_by(&severity_order(&1.severity))
      |> limit_challenges(max_challenges)

    all_challenges
  end

  # Handle :all or integer limit
  defp limit_challenges(challenges, :all), do: challenges
  defp limit_challenges(challenges, n) when is_integer(n), do: Enum.take(challenges, n)
  defp limit_challenges(challenges, _), do: challenges

  @doc """
  Generate a single challenge of a specific type.
  """
  @spec generate_challenge(challenge_type(), String.t(), map()) :: challenge()
  def generate_challenge(type, thought, context \\ %{}) do
    templates = Map.get(@challenge_templates, type, @challenge_templates.negation)
    template = Enum.random(templates)

    # Extract variables for template
    variables = extract_template_variables(thought, context)
    content = interpolate_template(template, variables)

    %{
      type: type,
      content: content,
      severity: default_severity(type),
      source: :template,
      context: %{thought: String.slice(thought, 0..100)}
    }
  end

  @doc """
  Check if a response adequately addresses a challenge.
  """
  @spec challenge_addressed?(challenge(), String.t()) :: boolean()
  def challenge_addressed?(challenge, response) do
    response_lower = String.downcase(response)
    challenge_lower = String.downcase(challenge.content)

    # Extract key terms from challenge
    key_terms =
      challenge_lower
      |> String.split(~r/\s+/)
      |> Enum.filter(&(String.length(&1) > 4))
      |> Enum.take(5)

    # Check if response engages with the challenge
    term_matches = Enum.count(key_terms, &String.contains?(response_lower, &1))
    has_engagement = String.length(response) > 50

    # Must mention at least half the key terms and have substantive content
    term_matches >= length(key_terms) / 2 and has_engagement
  end

  @doc """
  Format challenges for injection into reasoning prompt.
  """
  @spec format_for_injection([challenge()]) :: String.t()
  def format_for_injection(challenges) do
    if challenges == [] do
      ""
    else
      must_address =
        challenges
        |> Enum.filter(&(&1.severity == :must_address))
        |> Enum.map(& &1.content)

      should_consider =
        challenges
        |> Enum.filter(&(&1.severity == :should_consider))
        |> Enum.map(& &1.content)

      parts = []

      parts =
        if must_address != [] do
          must_str = Enum.map_join(must_address, "\n", &"⚠️ #{&1}")

          [
            """
            MUST ADDRESS before concluding:
            #{must_str}
            """
            | parts
          ]
        else
          parts
        end

      parts =
        if should_consider != [] do
          should_str = Enum.map_join(should_consider, "\n", &"💭 #{&1}")

          [
            """
            SHOULD CONSIDER:
            #{should_str}
            """
            | parts
          ]
        else
          parts
        end

      Enum.reverse(parts) |> Enum.join("\n")
    end
  end

  # ============================================================================
  # Private: Template-based Generation
  # ============================================================================

  defp generate_from_templates(thought, context, types) do
    Enum.flat_map(types, fn type ->
      templates = Map.get(@challenge_templates, type, [])

      if templates != [] do
        template = Enum.random(templates)
        variables = extract_template_variables(thought, context)

        [
          %{
            type: type,
            content: interpolate_template(template, variables),
            severity: default_severity(type),
            source: :template,
            context: %{}
          }
        ]
      else
        []
      end
    end)
  end

  defp extract_template_variables(thought, context) do
    # Extract nouns and key terms for template interpolation
    words =
      thought
      |> String.split(~r/\s+/)
      |> Enum.filter(&(String.length(&1) > 3))

    # Build variable map
    %{
      claim: String.slice(thought, 0..80),
      topic: Map.get(context, :topic, Enum.take(words, 3) |> Enum.join(" ")),
      approach: Map.get(context, :approach, "this approach"),
      problem: Map.get(context, :problem, "the problem"),
      variable: Map.get(context, :variable, "the input"),
      items: Map.get(context, :items, "items"),
      stakeholder: Map.get(context, :stakeholder, "reviewer")
    }
  end

  defp interpolate_template(template, variables) do
    Enum.reduce(variables, template, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", value)
    end)
  end

  # ============================================================================
  # Private: Memory-based Generation
  # ============================================================================

  defp generate_from_memory(thought, _context) do
    # Search for contradicting facts in memory
    case Memory.search_memories(thought, limit: 5, min_similarity: 0.5) do
      memories when is_list(memories) and length(memories) > 0 ->
        memories
        |> Enum.filter(&potentially_contradicts?(thought, &1))
        |> Enum.take(2)
        |> Enum.map(fn memory ->
          %{
            type: :contradiction,
            content:
              "Consider stored knowledge: \"#{String.slice(memory.content, 0..150)}\" - does this affect your reasoning?",
            severity: :should_consider,
            source: :memory,
            context: %{memory_id: memory.id}
          }
        end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp potentially_contradicts?(thought, memory) do
    # Simple heuristic: look for negation patterns
    thought_lower = String.downcase(thought)
    memory_lower = String.downcase(memory.content || "")

    # Check for words that appear negated in one but not other
    negation_patterns = ["not ", "never ", "don't ", "doesn't ", "won't ", "cannot "]

    thought_has_negation = Enum.any?(negation_patterns, &String.contains?(thought_lower, &1))
    memory_has_negation = Enum.any?(negation_patterns, &String.contains?(memory_lower, &1))

    # XOR - one has negation, other doesn't
    thought_has_negation != memory_has_negation
  end

  # ============================================================================
  # Private: Correction-based Generation
  # ============================================================================

  defp generate_from_corrections(thought, _context) do
    case CorrectionLearning.check_against_corrections(thought) do
      {:contradiction, correction} ->
        [
          %{
            type: :historical,
            content: "⚠️ Past correction applies: \"#{String.slice(correction.content, 0..150)}\"",
            severity: :must_address,
            source: :correction_learning,
            context: %{correction_id: correction.id}
          }
        ]

      :ok ->
        []
    end
  rescue
    _ -> []
  end

  # ============================================================================
  # Private: Severity Assignment
  # ============================================================================

  defp default_severity(type) do
    case type do
      :contradiction -> :must_address
      :historical -> :must_address
      :failure_mode -> :should_consider
      :negation -> :should_consider
      :alternative -> :should_consider
      :edge_case -> :optional
      :stakeholder -> :optional
      _ -> :optional
    end
  end

  defp assign_severity(challenges) do
    # Adjust severity based on source
    Enum.map(challenges, fn challenge ->
      adjusted =
        case challenge.source do
          :correction_learning -> :must_address
          :memory -> max_severity(challenge.severity, :should_consider)
          :template -> challenge.severity
          _ -> challenge.severity
        end

      %{challenge | severity: adjusted}
    end)
  end

  defp max_severity(a, b) do
    order = %{must_address: 3, should_consider: 2, optional: 1}

    if Map.get(order, a, 0) >= Map.get(order, b, 0) do
      a
    else
      b
    end
  end

  defp severity_order(severity) do
    case severity do
      :must_address -> 1
      :should_consider -> 2
      :optional -> 3
      _ -> 4
    end
  end
end
