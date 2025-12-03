defmodule Mimo.Cognitive.Strategies.ChainOfThought do
  @moduledoc """
  Chain-of-Thought (CoT) reasoning strategy.

  Implements linear step-by-step reasoning with:
  - Explicit step prompts
  - Confidence gates between steps
  - Intermediate verification

  ## Reference

  Wei et al. (2022) - "Chain-of-Thought Prompting Elicits Reasoning
  in Large Language Models"

  ## Best For

  - Mathematical calculations
  - Logical deductions
  - Sequential processes
  - Problems with clear step-by-step solutions
  """

  alias Mimo.Cognitive.ThoughtEvaluator

  @type step_guide :: %{
          step: non_neg_integer(),
          prompt: String.t(),
          context: String.t(),
          confidence_check: boolean()
        }

  @type step_evaluation :: %{
          quality: :good | :maybe | :bad,
          feedback: String.t(),
          suggestions: [String.t()],
          should_continue: boolean()
        }

  # Standard CoT prompts for different problem types
  @general_prompts [
    "Step 1: What information do we have? What is given in the problem?",
    "Step 2: What are we trying to find or accomplish?",
    "Step 3: What approach or method should we use?",
    "Step 4: Work through the solution step by step.",
    "Step 5: Verify the result makes sense."
  ]

  @math_prompts [
    "Step 1: Identify all given values and variables.",
    "Step 2: Determine what we need to calculate.",
    "Step 3: Write down the relevant formula(s).",
    "Step 4: Substitute values and compute.",
    "Step 5: Check the answer by estimation or reverse calculation."
  ]

  @logic_prompts [
    "Step 1: List all premises and given statements.",
    "Step 2: Identify what conclusion we want to reach.",
    "Step 3: Apply logical rules to derive intermediate conclusions.",
    "Step 4: Chain the conclusions to reach the final answer.",
    "Step 5: Verify no logical fallacies were used."
  ]

  @doc """
  Generate guided prompts for a CoT step.

  ## Parameters

  - `problem` - The original problem statement
  - `step_number` - Current step (1-indexed)
  - `previous_steps` - List of completed step contents
  """
  @spec guide_step(String.t(), non_neg_integer(), [String.t()]) :: step_guide()
  def guide_step(problem, step_number, previous_steps) do
    prompts = select_prompts(problem)
    total_steps = length(prompts)

    prompt =
      if step_number <= total_steps do
        Enum.at(prompts, step_number - 1)
      else
        "Step #{step_number}: Continue the reasoning process."
      end

    context = build_context(previous_steps)

    %{
      step: step_number,
      prompt: prompt,
      context: context,
      # Start confidence checking after step 2
      confidence_check: step_number > 2
    }
  end

  @doc """
  Evaluate a CoT step for quality and consistency.
  """
  @spec evaluate_step(String.t(), [String.t()], String.t()) :: step_evaluation()
  def evaluate_step(step_content, previous_steps, problem) do
    # Use thought evaluator for comprehensive check
    evaluation =
      ThoughtEvaluator.evaluate(step_content, %{
        previous_thoughts: previous_steps,
        problem: problem,
        strategy: :cot
      })

    # CoT-specific checks
    cot_issues = check_cot_specific(step_content, previous_steps)

    # Combine issues
    _all_issues = evaluation.issues ++ cot_issues

    should_continue = evaluation.quality != :bad and length(cot_issues) < 2

    %{
      quality: evaluation.quality,
      feedback: evaluation.feedback,
      suggestions: evaluation.suggestions ++ generate_cot_suggestions(step_content, previous_steps),
      should_continue: should_continue
    }
  end

  @doc """
  Suggest the next step based on current state.
  """
  @spec suggest_next_step([String.t()], String.t()) :: String.t()
  def suggest_next_step(current_steps, problem) do
    step_number = length(current_steps) + 1

    cond do
      step_number == 1 ->
        "Begin by identifying what information is given in the problem."

      step_number == 2 ->
        "Now clarify what we need to find or determine."

      step_number <= 4 ->
        "Continue working through the solution systematically."

      detect_near_completion(current_steps, problem) ->
        "You're close to a solution. Verify your answer and summarize."

      true ->
        "Continue the reasoning. If stuck, try a different approach."
    end
  end

  @doc """
  Detect if the reasoning chain seems complete.
  """
  @spec detect_completion([String.t()], String.t()) :: boolean()
  def detect_completion([], _problem), do: false

  def detect_completion(steps, _problem) do
    last_step = List.last(steps) |> String.downcase()

    # Check for completion indicators
    completion_patterns = [
      ~r/\b(therefore|thus|so|hence|in conclusion)\b.*\b(the answer|the result|the solution)\b/i,
      ~r/\b(answer|result|solution)\s*(is|=|:)\s*\S+/i,
      ~r/\bfinal\s+(answer|result|value)\b/i,
      ~r/\bverif(y|ied|ication)\b.*\b(correct|right|works)\b/i
    ]

    has_conclusion = Enum.any?(completion_patterns, &String.match?(last_step, &1))

    # Also check step count (CoT typically completes in 3-7 steps)
    reasonable_length = length(steps) >= 3

    has_conclusion and reasonable_length
  end

  @doc """
  Get the standard number of steps for a problem type.
  """
  @spec typical_steps(String.t()) :: non_neg_integer()
  def typical_steps(problem) do
    cond do
      math_problem?(problem) -> 5
      logic_problem?(problem) -> 5
      String.length(problem) > 200 -> 6
      true -> 4
    end
  end

  @doc """
  Format the reasoning chain for output.
  """
  @spec format_chain([String.t()]) :: String.t()
  def format_chain(steps) do
    steps
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", fn {step, idx} ->
      "**Step #{idx}:** #{step}"
    end)
  end

  # Private helpers

  defp select_prompts(problem) do
    cond do
      math_problem?(problem) -> @math_prompts
      logic_problem?(problem) -> @logic_prompts
      true -> @general_prompts
    end
  end

  defp math_problem?(problem) do
    String.match?(
      problem,
      ~r/\b(calculate|compute|sum|multiply|divide|add|subtract|percentage|average|equation|formula|solve for)\b/i
    ) or
      String.match?(problem, ~r/\d+\s*[\+\-\*\/]\s*\d+/)
  end

  defp logic_problem?(problem) do
    String.match?(
      problem,
      ~r/\b(if|then|therefore|conclude|prove|given that|implies|valid|invalid|true|false)\b/i
    )
  end

  defp build_context(previous_steps) do
    if previous_steps == [] do
      "Starting fresh reasoning process."
    else
      summary =
        previous_steps
        |> Enum.take(-3)
        |> Enum.map_join(" → ", &String.slice(&1, 0..100))

      "Building on: #{summary}..."
    end
  end

  defp check_cot_specific(step_content, previous_steps) do
    issues = []

    # Check for jumping to conclusion without steps
    issues =
      if length(previous_steps) < 2 and
           String.match?(step_content, ~r/\b(therefore|thus|so the answer)\b/i) do
        ["Concluding too early - work through intermediate steps first" | issues]
      else
        issues
      end

    # Check for introducing new information late in the chain
    issues =
      if length(previous_steps) >= 3 and
           String.match?(
             step_content,
             ~r/\b(also|additionally|furthermore|moreover)\b.*\b(given|we know)\b/i
           ) do
        ["New information should be identified in earlier steps" | issues]
      else
        issues
      end

    issues
  end

  defp generate_cot_suggestions(step_content, previous_steps) do
    suggestions = []

    # Suggest showing work for calculations
    suggestions =
      if String.match?(step_content, ~r/=\s*\d+/) and
           not String.match?(step_content, ~r/=\s*\S+\s*=/) do
        ["Show intermediate calculation steps for clarity" | suggestions]
      else
        suggestions
      end

    # Suggest explaining reasoning
    suggestions =
      if length(previous_steps) > 0 and
           not String.match?(step_content, ~r/\b(because|since|therefore|thus)\b/i) do
        [
          "Connect this step to the previous one with reasoning (because, since, therefore)"
          | suggestions
        ]
      else
        suggestions
      end

    suggestions
  end

  defp detect_near_completion(steps, _problem) do
    if steps == [] do
      false
    else
      last_step = List.last(steps) |> String.downcase()

      # Check for near-completion indicators
      String.match?(
        last_step,
        ~r/\b(almost|nearly|close to|approaching|result|calculation|computed)\b/i
      ) and
        length(steps) >= 3
    end
  end
end
