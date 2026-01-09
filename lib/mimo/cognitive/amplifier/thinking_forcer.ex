defmodule Mimo.Cognitive.Amplifier.ThinkingForcer do
  @moduledoc """
  Forces problem decomposition before allowing direct answers.

  This is the first stage of cognitive amplification. It intercepts
  prompts and forces the LLM to break down problems before answering.

  ## Philosophy

  Non-thinking models jump directly to answers. Thinking models
  decompose first. ThinkingForcer gives non-thinking models the
  benefit of decomposition by REQUIRING it externally.

  ## Decomposition Strategies

  - `:sub_questions` - Break into component questions
  - `:prerequisites` - Identify what must be true
  - `:assumptions` - Surface hidden assumptions
  - `:constraints` - Identify limiting factors
  - `:unknowns` - What information is missing?

  ## Integration with Neuro+ML

  - Uses SpreadingActivation to find similar past decompositions
  - Learns effective strategies via AttentionLearner feedback
  """

  require Logger

  alias Mimo.Cognitive.Amplifier.AmplificationLevel
  alias Mimo.Cognitive.ProblemAnalyzer

  @type decomposition_strategy ::
          :sub_questions
          | :prerequisites
          | :assumptions
          | :constraints
          | :unknowns
          | :steps
          | :alternatives

  @type forcing_result :: %{
          required: boolean(),
          prompts: [String.t()],
          strategies_used: [decomposition_strategy()],
          min_responses: non_neg_integer()
        }

  # Strategy templates
  @strategy_templates %{
    sub_questions: """
    Before answering, break this problem into sub-questions:
    1. What are the key components of this problem?
    2. What sub-questions must be answered first?
    3. List 2-4 specific sub-questions that, if answered, would solve this.
    """,
    prerequisites: """
    Before answering, identify prerequisites:
    1. What must be true for any solution to work?
    2. What dependencies exist?
    3. What conditions are required?
    """,
    assumptions: """
    Before answering, surface your assumptions:
    1. What are you assuming about the context?
    2. What are you assuming about the requirements?
    3. Which assumptions, if wrong, would invalidate your answer?
    """,
    constraints: """
    Before answering, identify constraints:
    1. What limitations apply here?
    2. What cannot be changed?
    3. What trade-offs exist?
    """,
    unknowns: """
    Before answering, identify unknowns:
    1. What information is missing?
    2. What would you need to know to be confident?
    3. What uncertainties affect your answer?
    """,
    steps: """
    Before answering, plan the steps:
    1. What is the first thing that needs to happen?
    2. What sequence of actions is required?
    3. What are the key milestones?
    """,
    alternatives: """
    Before answering, consider alternatives:
    1. What are at least 2 different approaches?
    2. What are the trade-offs of each?
    3. Why might you choose one over another?
    """
  }

  # Problem patterns that trigger specific strategies
  @pattern_strategies %{
    debugging: [:assumptions, :steps, :unknowns],
    implementation: [:sub_questions, :prerequisites, :constraints],
    design: [:alternatives, :constraints, :prerequisites],
    explanation: [:sub_questions, :assumptions],
    optimization: [:constraints, :alternatives, :prerequisites],
    decision: [:alternatives, :constraints, :assumptions]
  }

  @doc """
  Analyze a prompt and determine if decomposition should be forced.

  Returns forcing prompts if decomposition is required.
  """
  @spec force(String.t(), AmplificationLevel.t(), keyword()) :: forcing_result()
  def force(prompt, level, opts \\ []) do
    if level.decomposition do
      complexity = analyze_complexity(prompt)

      if should_force?(complexity, level, opts) do
        strategies = select_strategies(prompt, complexity, opts)
        prompts = generate_forcing_prompts(prompt, strategies)

        %{
          required: true,
          prompts: prompts,
          strategies_used: strategies,
          min_responses: length(strategies)
        }
      else
        %{required: false, prompts: [], strategies_used: [], min_responses: 0}
      end
    else
      %{required: false, prompts: [], strategies_used: [], min_responses: 0}
    end
  end

  @doc """
  Generate decomposition prompts for specific strategies.
  """
  @spec generate_forcing_prompts(String.t(), [decomposition_strategy()]) :: [String.t()]
  def generate_forcing_prompts(original_prompt, strategies) do
    Enum.map(strategies, fn strategy ->
      template = Map.get(@strategy_templates, strategy, @strategy_templates.sub_questions)

      """
      PROBLEM: #{String.slice(original_prompt, 0..500)}

      #{template}

      Respond with your analysis before proceeding to the solution.
      """
    end)
  end

  @doc """
  Validate that a decomposition response is adequate.

  Checks that the response actually contains decomposition, not a direct answer.
  """
  @spec validate_decomposition(String.t(), decomposition_strategy()) ::
          {:valid, [String.t()]} | {:invalid, String.t()}
  def validate_decomposition(response, strategy) do
    # Check for decomposition markers
    has_list = String.match?(response, ~r/\d+\.|[-•*]/)
    has_questions = String.match?(response, ~r/\?/)

    min_length =
      case strategy do
        :sub_questions -> 100
        :assumptions -> 80
        _ -> 60
      end

    # Comprehensive responses (300+ chars with structure) are always valid
    # This allows flexibility for different decomposition styles
    comprehensive = String.length(response) >= 300 and has_list

    cond do
      comprehensive ->
        items = extract_decomposition_items(response)
        {:valid, items}

      String.length(response) < min_length ->
        {:invalid, "Response too short. Please provide more detailed decomposition."}

      strategy == :sub_questions and not has_questions and String.length(response) < 300 ->
        {:invalid, "Please identify specific sub-questions (ending with ?)."}

      not has_list and String.length(response) < 200 ->
        {:invalid, "Please structure your decomposition as a list."}

      true ->
        items = extract_decomposition_items(response)
        {:valid, items}
    end
  end

  @doc """
  Get recommended strategies for a problem type.
  """
  @spec strategies_for_problem_type(atom()) :: [decomposition_strategy()]
  def strategies_for_problem_type(problem_type) do
    Map.get(@pattern_strategies, problem_type, [:sub_questions, :assumptions])
  end

  defp analyze_complexity(prompt) do
    # Use existing ProblemAnalyzer
    analysis = ProblemAnalyzer.analyze(prompt)
    analysis.complexity
  end

  defp should_force?(complexity, level, opts) do
    # Always force for deep/exhaustive levels
    if level.name in [:deep, :exhaustive] do
      true
    else
      # Force based on complexity
      force_threshold = Keyword.get(opts, :force_threshold, :moderate)

      complexity_order = %{
        trivial: 1,
        simple: 2,
        moderate: 3,
        complex: 4,
        very_complex: 5
      }

      threshold_value = Map.get(complexity_order, force_threshold, 3)
      complexity_value = Map.get(complexity_order, complexity, 3)

      complexity_value >= threshold_value
    end
  end

  defp select_strategies(prompt, complexity, opts) do
    # Detect problem type
    problem_type = detect_problem_type(prompt)
    base_strategies = Map.get(@pattern_strategies, problem_type, [:sub_questions])

    # Adjust count based on complexity
    count =
      case complexity do
        :simple -> 1
        :moderate -> 2
        :complex -> 3
      end

    # Override with explicit strategies if provided
    explicit = Keyword.get(opts, :strategies, [])

    if explicit != [] do
      Enum.take(explicit, count)
    else
      Enum.take(base_strategies, count)
    end
  end

  defp detect_problem_type(prompt) do
    prompt_lower = String.downcase(prompt)

    cond do
      String.match?(prompt_lower, ~r/\b(bug|error|fix|debug|issue|wrong|broken)\b/) ->
        :debugging

      String.match?(prompt_lower, ~r/\b(implement|create|build|add|write)\b/) ->
        :implementation

      String.match?(prompt_lower, ~r/\b(design|architect|structure|plan)\b/) ->
        :design

      String.match?(prompt_lower, ~r/\b(explain|what|why|how does)\b/) ->
        :explanation

      String.match?(prompt_lower, ~r/\b(optimize|improve|faster|better|efficient)\b/) ->
        :optimization

      String.match?(prompt_lower, ~r/\b(should|choose|decide|which|or)\b/) ->
        :decision

      true ->
        :implementation
    end
  end

  defp extract_decomposition_items(response) do
    # Extract numbered or bulleted items
    response
    |> String.split(~r/\n/)
    |> Enum.filter(fn line ->
      String.match?(line, ~r/^\s*(\d+[\.\):]|[-•*])/)
    end)
    |> Enum.map(fn line ->
      line
      |> String.replace(~r/^\s*(\d+[\.\):]|[-•*])\s*/, "")
      |> String.trim()
    end)
    |> Enum.reject(&(&1 == ""))
  end
end
