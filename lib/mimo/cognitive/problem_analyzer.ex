defmodule Mimo.Cognitive.ProblemAnalyzer do
  @moduledoc """
  Analyzes problems to select the best reasoning strategy.

  Examines problem characteristics to recommend the optimal
  reasoning approach (CoT, ToT, ReAct, Reflexion).

  ## Strategy Selection Criteria

  | Strategy   | Best For                                      |
  |------------|-----------------------------------------------|
  | CoT        | Linear multi-step, math, logic puzzles        |
  | ToT        | Multiple valid approaches, design decisions   |
  | ReAct      | Tool use, debugging, external lookups         |
  | Reflexion  | Trial-and-error, programming, learning tasks  |
  """

  @type analysis :: %{
          requires_calculation: boolean(),
          step_count: :few | :moderate | :many,
          ambiguous: boolean(),
          branching_factor: :low | :medium | :high,
          requires_lookup: boolean(),
          involves_tools: boolean(),
          trial_and_error: boolean(),
          programming_task: boolean(),
          complexity: :simple | :moderate | :complex,
          keywords: [String.t()]
        }

  @type strategy :: :cot | :tot | :react | :reflexion

  # Keyword patterns for different problem types
  @calculation_patterns ~r/\b(calculate|compute|sum|multiply|divide|add|subtract|percentage|average|total|count|how many|how much|what is \d+)\b/i
  # Logic problem patterns (reserved for future use)
  # @logic_patterns ~r/\b(if|then|therefore|conclude|deduce|infer|implies|valid|invalid|true|false|prove|given that)\b/i
  @ambiguous_patterns ~r/\b(best|should|recommend|choose|decide|compare|evaluate|design|architect|approach|strategy|option|alternative)\b/i
  @tool_patterns ~r/\b(find|search|look up|check|read|fetch|get|list|show|debug|fix|test|run|execute|compile)\b/i
  @programming_patterns ~r/\b(implement|write|code|function|class|method|module|bug|error|refactor|optimize|api|endpoint)\b/i
  @trial_patterns ~r/\b(try|attempt|experiment|test|retry|iterate|improve|fix|solve|debug|troubleshoot)\b/i
  @step_patterns ~r/\b(first|then|next|after|finally|step|stage|phase)\b/i
  @lookup_patterns ~r/\b(documentation|docs|manual|reference|api|spec|how does|what is|where is)\b/i

  @doc """
  Analyze a problem to understand its characteristics.
  """
  @spec analyze(String.t()) :: analysis()
  def analyze(problem) when is_binary(problem) do
    problem_lower = String.downcase(problem)

    %{
      requires_calculation: has_calculation?(problem_lower),
      step_count: estimate_step_count(problem_lower),
      ambiguous: ambiguous?(problem_lower),
      branching_factor: estimate_branching_factor(problem_lower),
      requires_lookup: requires_lookup?(problem_lower),
      involves_tools: involves_tools?(problem_lower),
      trial_and_error: trial_and_error?(problem_lower),
      programming_task: programming_task?(problem_lower),
      complexity: estimate_complexity(problem),
      keywords: extract_keywords(problem_lower)
    }
  end

  @doc """
  Recommend the best reasoning strategy based on analysis.
  """
  @spec recommend_strategy(analysis()) :: strategy()
  def recommend_strategy(analysis) do
    cond do
      # Reflexion: Trial-and-error or programming tasks that need learning
      analysis.trial_and_error and analysis.programming_task ->
        :reflexion

      # ReAct: Tool use or external lookups needed
      analysis.involves_tools or analysis.requires_lookup ->
        :react

      # ToT: Ambiguous problems with high branching factor
      analysis.ambiguous and analysis.branching_factor in [:medium, :high] ->
        :tot

      # CoT: Calculation or logic problems with linear steps
      analysis.requires_calculation ->
        :cot

      # CoT: Step-by-step problems
      analysis.step_count in [:moderate, :many] and not analysis.ambiguous ->
        :cot

      # ToT: Design or comparison problems
      analysis.ambiguous ->
        :tot

      # ReAct: Programming tasks often need file access
      analysis.programming_task ->
        :react

      # Default: CoT for structured reasoning
      true ->
        :cot
    end
  end

  @doc """
  Analyze problem and recommend strategy in one call.
  """
  @spec analyze_and_recommend(String.t()) :: {analysis(), strategy(), String.t()}
  def analyze_and_recommend(problem) do
    analysis = analyze(problem)
    strategy = recommend_strategy(analysis)
    reason = strategy_reason(analysis, strategy)
    {analysis, strategy, reason}
  end

  @doc """
  Estimate the complexity of a problem (simple/moderate/complex).
  """
  @spec estimate_complexity(String.t()) :: :simple | :moderate | :complex
  def estimate_complexity(problem) do
    word_count = problem |> String.split() |> length()
    question_count = problem |> String.graphemes() |> Enum.count(&(&1 == "?"))
    problem_lower = String.downcase(problem)

    # Compute analysis properties directly to avoid recursion
    branching_high = estimate_branching_factor(problem_lower) == :high
    has_tools = involves_tools?(problem_lower)
    is_programming = programming_task?(problem_lower)
    is_ambiguous = ambiguous?(problem_lower)

    complexity_score =
      0 +
        if(word_count > 50, do: 2, else: if(word_count > 20, do: 1, else: 0)) +
        if(question_count > 1, do: 1, else: 0) +
        if(branching_high, do: 2, else: 0) +
        if(has_tools, do: 1, else: 0) +
        if(is_programming, do: 1, else: 0) +
        if is_ambiguous, do: 1, else: 0

    cond do
      complexity_score >= 5 -> :complex
      complexity_score >= 2 -> :moderate
      true -> :simple
    end
  end

  @doc """
  Decompose a problem into sub-problems (linear decomposition).
  """
  @spec decompose(String.t()) :: [String.t()]
  def decompose(problem) do
    analysis = analyze(problem)

    cond do
      analysis.programming_task ->
        decompose_programming_task(problem)

      analysis.requires_calculation ->
        decompose_calculation(problem)

      analysis.ambiguous ->
        decompose_decision(problem)

      true ->
        decompose_generic(problem)
    end
  end

  @doc """
  Generate a tree of alternative approaches for ToT.
  """
  @spec generate_approaches(String.t()) :: [%{approach: String.t(), rationale: String.t()}]
  def generate_approaches(problem) do
    analysis = analyze(problem)

    cond do
      analysis.programming_task ->
        [
          %{
            approach: "Top-down design",
            rationale: "Start with high-level architecture, then implement details"
          },
          %{
            approach: "Bottom-up implementation",
            rationale: "Build small components first, then combine"
          },
          %{
            approach: "Test-driven approach",
            rationale: "Write tests first, then implement to pass them"
          }
        ]

      analysis.ambiguous ->
        [
          %{
            approach: "Evaluate trade-offs systematically",
            rationale: "List pros/cons for each option"
          },
          %{
            approach: "Prototype and compare",
            rationale: "Try quick implementations of each approach"
          },
          %{
            approach: "Research similar solutions",
            rationale: "Find how others solved similar problems"
          }
        ]

      analysis.requires_calculation ->
        [
          %{
            approach: "Work forward from givens",
            rationale: "Start with known values, derive unknowns"
          },
          %{
            approach: "Work backward from goal",
            rationale: "Start with what you need, find dependencies"
          }
        ]

      true ->
        [
          %{
            approach: "Direct approach",
            rationale: "Tackle the problem head-on with straightforward steps"
          },
          %{approach: "Simplify first", rationale: "Reduce complexity before solving"}
        ]
    end
  end

  # Private analysis functions

  defp has_calculation?(problem) do
    String.match?(problem, @calculation_patterns) or
      String.match?(problem, ~r/\d+\s*[\+\-\*\/]\s*\d+/)
  end

  defp estimate_step_count(problem) do
    step_indicators = Regex.scan(@step_patterns, problem) |> length()
    word_count = String.split(problem) |> length()

    cond do
      step_indicators >= 3 -> :many
      step_indicators >= 1 or word_count > 40 -> :moderate
      true -> :few
    end
  end

  defp ambiguous?(problem) do
    String.match?(problem, @ambiguous_patterns)
  end

  defp estimate_branching_factor(problem) do
    # Count decision-indicating words
    decision_words = ~w(or either choose between option alternative)
    decision_count = Enum.count(decision_words, &String.contains?(problem, &1))

    # Check for explicit alternatives
    has_multiple_options = String.match?(problem, ~r/\b(option\s*[a-d1-4]|choice\s*[a-d1-4])\b/i)

    cond do
      has_multiple_options or decision_count >= 2 -> :high
      String.match?(problem, @ambiguous_patterns) -> :medium
      true -> :low
    end
  end

  defp requires_lookup?(problem) do
    String.match?(problem, @lookup_patterns)
  end

  defp involves_tools?(problem) do
    String.match?(problem, @tool_patterns)
  end

  defp trial_and_error?(problem) do
    String.match?(problem, @trial_patterns)
  end

  defp programming_task?(problem) do
    String.match?(problem, @programming_patterns)
  end

  defp extract_keywords(problem) do
    # Extract significant words (not common words)
    common_words = MapSet.new(~w(
      the a an is are was were be been being have has had
      do does did will would could should may might must
      can this that these those what when where which who
      how for from with about into through
    ))

    problem
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, "")
    |> String.split()
    |> Enum.reject(fn x -> String.length(x) < 3 or MapSet.member?(common_words, x) end)
    |> Enum.uniq()
    |> Enum.take(10)
  end

  defp strategy_reason(analysis, strategy) do
    reasons = []

    reasons =
      case strategy do
        :cot ->
          cond do
            analysis.requires_calculation ->
              ["Problem involves calculation/math" | reasons]

            analysis.step_count in [:moderate, :many] ->
              ["Problem has multiple sequential steps" | reasons]

            true ->
              ["Best solved with step-by-step reasoning" | reasons]
          end

        :tot ->
          cond do
            analysis.ambiguous and analysis.branching_factor in [:medium, :high] ->
              ["Multiple valid approaches exist" | reasons]

            analysis.ambiguous ->
              ["Problem requires design decisions or comparisons" | reasons]

            true ->
              ["Exploration of alternatives needed" | reasons]
          end

        :react ->
          cond do
            analysis.involves_tools ->
              ["Problem requires tool use (file operations, searches)" | reasons]

            analysis.requires_lookup ->
              ["Problem needs external information lookup" | reasons]

            true ->
              ["Interleaved reasoning and action recommended" | reasons]
          end

        :reflexion ->
          cond do
            analysis.trial_and_error and analysis.programming_task ->
              ["Programming task that may need iteration" | reasons]

            analysis.trial_and_error ->
              ["Trial-and-error approach likely needed" | reasons]

            true ->
              ["Learning from attempts will improve results" | reasons]
          end
      end

    Enum.join(reasons, "; ")
  end

  # Decomposition helpers

  defp decompose_programming_task(_problem) do
    [
      "Understand the requirements and constraints",
      "Identify the key components or modules needed",
      "Plan the data structures and interfaces",
      "Implement core functionality",
      "Add error handling and edge cases",
      "Test and verify the implementation"
    ]
  end

  defp decompose_calculation(_problem) do
    [
      "Identify what is given (known values)",
      "Identify what we need to find (unknowns)",
      "Determine the formula or method to use",
      "Perform the calculation step by step",
      "Verify the result makes sense"
    ]
  end

  defp decompose_decision(_problem) do
    [
      "Clarify the decision criteria",
      "List the available options",
      "Evaluate each option against criteria",
      "Compare trade-offs",
      "Make and justify the recommendation"
    ]
  end

  defp decompose_generic(_problem) do
    [
      "Understand the problem fully",
      "Break into smaller parts if needed",
      "Work through each part systematically",
      "Combine results into final answer",
      "Verify the solution"
    ]
  end
end
