defmodule Mimo.Cognitive.MetaTaskDetector do
  @moduledoc """
  SPEC-062: Meta-Task Detection for AI reasoning.

  Detects tasks that require the AI to GENERATE content rather than simply
  process provided content. This addresses a key failure mode discovered in
  AI Intelligence Testing where models literally interpret meta-instructions
  instead of recognizing they should generate sub-problems.

  ## Problem Statement

  AI models often fail meta-tasks like:
  - "I'm going to ask you 5 trivia questions" → Model waits for questions instead of generating them
  - "Predict whether you'll get this right" → Model doesn't understand self-prediction

  ## Solution

  This detector identifies meta-task patterns and provides explicit guidance
  to help models understand they need to self-generate content.

  ## Usage

      case MetaTaskDetector.detect(problem) do
        {:meta_task, guidance} ->
          # Enhance problem with guidance
          enhanced = problem <> "\\n\\n⚠️ META-TASK: " <> guidance.instruction
        {:standard, _} ->
          # Normal problem, no enhancement needed
          problem
      end
  """

  require Logger

  # Pattern definitions: {regex, task_type}
  @patterns [
    # Generate questions patterns
    {~r/I'm going to ask you \d+ .* questions/i, :generate_questions},
    {~r/I'll ask you \d+ questions/i, :generate_questions},
    {~r/answer \d+ .* questions/i, :generate_questions},
    {~r/come up with \d+/i, :generate_content},
    {~r/make up .* questions/i, :generate_questions},
    {~r/think of \d+/i, :generate_content},
    {~r/generate \d+ .* questions/i, :generate_questions},
    {~r/create \d+ .* questions/i, :generate_questions},

    # Self-prediction patterns
    {~r/predict whether you'll/i, :self_prediction},
    {~r/predict if you will/i, :self_prediction},
    {~r/guess whether you/i, :self_prediction},
    {~r/estimate your accuracy/i, :self_prediction},
    {~r/how confident are you that you'll/i, :self_prediction},

    # Iterative task patterns
    {~r/before answering each/i, :iterative_task},
    {~r/for each .*, first/i, :iterative_task},
    {~r/after each answer/i, :iterative_task},

    # Verification design patterns
    {~r/create .* that would verify/i, :verification_design},
    {~r/design .* to check/i, :verification_design},
    {~r/construct .* to validate/i, :verification_design},

    # Test generation patterns
    {~r/generate .* to test/i, :test_generation},
    {~r/create your own/i, :generate_content},
    {~r/design .* test cases/i, :test_generation},
    {~r/invent .* examples/i, :generate_content},

    # Self-reference patterns
    {~r/about yourself/i, :self_reference},
    {~r/your own .* abilities/i, :self_reference},
    {~r/evaluate your/i, :self_reference}
  ]

  # Configuration for LLM fallback
  @llm_fallback_enabled Application.compile_env(:mimo, :meta_task_llm_fallback, true)
  @llm_timeout 5_000

  @type task_type ::
          :generate_questions
          | :generate_content
          | :self_prediction
          | :iterative_task
          | :verification_design
          | :test_generation
          | :self_reference
          | :standard

  @type guidance :: %{
          type: task_type(),
          instruction: String.t(),
          example: String.t() | nil,
          confidence: float()
        }

  @type detection_result :: {:meta_task, guidance()} | {:standard, map()}

  # ============================================================================
  # PUBLIC API
  # ============================================================================

  @doc """
  Detect if a problem is a meta-task requiring self-generated content.

  Returns {:meta_task, guidance} if detected, {:standard, %{}} otherwise.

  ## Examples

      iex> MetaTaskDetector.detect("I'm going to ask you 5 trivia questions")
      {:meta_task, %{type: :generate_questions, instruction: "...", ...}}

      iex> MetaTaskDetector.detect("What is 2 + 2?")
      {:standard, %{}}
  """
  @spec detect(String.t()) :: detection_result()
  def detect(problem) when is_binary(problem) do
    case find_pattern(problem) do
      nil ->
        # No pattern matched, try LLM fallback if enabled
        if @llm_fallback_enabled do
          llm_detect(problem)
        else
          {:standard, %{method: :pattern_only}}
        end

      {_pattern, type} ->
        emit_detection(true, type, :regex)
        {:meta_task, build_guidance(type, problem)}
    end
  end

  def detect(_), do: {:standard, %{method: :invalid_input}}

  @doc """
  Check if a problem contains meta-task patterns without full detection.
  Faster than detect/1 when you just need a boolean check.
  """
  @spec meta_task?(String.t()) :: boolean()
  def meta_task?(problem) when is_binary(problem) do
    case detect(problem) do
      {:meta_task, _} -> true
      {:standard, _} -> false
    end
  end

  @doc """
  Get all detected meta-task types in a problem.
  Useful for problems that may contain multiple meta-task patterns.
  """
  @spec detect_all(String.t()) :: [task_type()]
  def detect_all(problem) when is_binary(problem) do
    @patterns
    |> Enum.filter(fn {pattern, _type} -> Regex.match?(pattern, problem) end)
    |> Enum.map(fn {_pattern, type} -> type end)
    |> Enum.uniq()
  end

  @doc """
  Enhance a problem with meta-task guidance if detected.
  Returns the original problem if not a meta-task.
  """
  @spec enhance_if_meta_task(String.t()) :: String.t()
  def enhance_if_meta_task(problem) when is_binary(problem) do
    case detect(problem) do
      {:meta_task, guidance} ->
        """
        #{problem}

        ⚠️ META-TASK DETECTED (#{guidance.type}): #{guidance.instruction}
        #{if guidance.example, do: "Example: #{guidance.example}", else: ""}
        """

      {:standard, _} ->
        problem
    end
  end

  # ============================================================================
  # GUIDANCE BUILDERS
  # ============================================================================

  defp build_guidance(:generate_questions, problem) do
    # Try to extract the number from the problem
    count = extract_question_count(problem)

    %{
      type: :generate_questions,
      instruction:
        "You must GENERATE the questions yourself - they are NOT provided. Create #{count || "the specified number of"} questions, answer each, then summarize.",
      example:
        "1. Create trivia question #1\n2. Predict if you'll get it right\n3. Answer it\n4. Check prediction\n5. Repeat for remaining questions\n6. Calculate final accuracy",
      confidence: 0.95
    }
  end

  defp build_guidance(:generate_content, _problem) do
    %{
      type: :generate_content,
      instruction:
        "You must CREATE/GENERATE the content yourself. This is not asking you to process existing content.",
      example: "Generate the items first, then work with them.",
      confidence: 0.90
    }
  end

  defp build_guidance(:self_prediction, _problem) do
    %{
      type: :self_prediction,
      instruction:
        "You must PREDICT your own performance BEFORE attempting the task. State your prediction explicitly, then complete the task, then evaluate if your prediction was correct.",
      example:
        "Step 1: 'I predict I will get this [right/wrong] because...'\nStep 2: Attempt the task\nStep 3: 'My prediction was [correct/incorrect]'",
      confidence: 0.92
    }
  end

  defp build_guidance(:iterative_task, _problem) do
    %{
      type: :iterative_task,
      instruction:
        "This requires an ITERATIVE process. For EACH item, perform the specified steps in order before moving to the next item.",
      example:
        "For item 1: [step a] → [step b] → [step c]\nFor item 2: [step a] → [step b] → [step c]",
      confidence: 0.88
    }
  end

  defp build_guidance(:verification_design, _problem) do
    %{
      type: :verification_design,
      instruction:
        "You must DESIGN a verification method or test that would confirm your answer is correct.",
      example:
        "If solving 'x = 5', create verification: 'Substitute x=5 into original equation and verify equality'",
      confidence: 0.90
    }
  end

  defp build_guidance(:test_generation, _problem) do
    %{
      type: :test_generation,
      instruction:
        "You must GENERATE test cases yourself. Create diverse tests that cover edge cases and normal cases.",
      example: "Test 1: Normal input → expected output\nTest 2: Edge case → expected behavior",
      confidence: 0.88
    }
  end

  defp build_guidance(:self_reference, _problem) do
    %{
      type: :self_reference,
      instruction:
        "This question is about YOUR OWN capabilities or nature. Reflect on your actual abilities rather than giving a generic answer.",
      example: nil,
      confidence: 0.85
    }
  end

  defp build_guidance(type, _problem) do
    %{
      type: type,
      instruction: "Self-generate the required content based on the task description.",
      example: nil,
      confidence: 0.75
    }
  end

  # ============================================================================
  # PATTERN MATCHING
  # ============================================================================

  defp find_pattern(problem) do
    Enum.find(@patterns, fn {pattern, _type} ->
      Regex.match?(pattern, problem)
    end)
  end

  defp extract_question_count(problem) do
    case Regex.run(~r/(\d+)\s*(?:trivia\s+)?questions?/i, problem) do
      [_, count] -> String.to_integer(count)
      _ -> nil
    end
  end

  # ============================================================================
  # LLM FALLBACK (for novel patterns)
  # ============================================================================

  defp llm_detect(problem) do
    # Only attempt LLM detection for longer, complex problems
    if String.length(problem) < 20 do
      {:standard, %{method: :too_short}}
    else
      prompt = build_llm_prompt(problem)

      task =
        Task.async(fn ->
          Mimo.Brain.LLM.complete(prompt, json: true, max_tokens: 200)
        end)

      case Task.yield(task, @llm_timeout) || Task.shutdown(task) do
        {:ok, {:ok, response}} ->
          parse_llm_response(response, problem)

        {:ok, {:error, reason}} ->
          Logger.debug("[MetaTaskDetector] LLM fallback failed: #{inspect(reason)}")
          {:standard, %{method: :llm_error}}

        nil ->
          Logger.debug("[MetaTaskDetector] LLM fallback timed out")
          {:standard, %{method: :llm_timeout}}
      end
    end
  rescue
    e ->
      Logger.warning("[MetaTaskDetector] LLM fallback exception: #{inspect(e)}")
      {:standard, %{method: :llm_exception}}
  end

  defp build_llm_prompt(problem) do
    """
    Analyze if this task requires the AI to GENERATE content that wasn't provided.

    TASK: #{String.slice(problem, 0, 500)}

    Meta-tasks are tasks where:
    - The AI must create questions/examples/tests rather than answer provided ones
    - The AI must predict its own performance
    - The AI must evaluate its own capabilities

    Respond with JSON only:
    {"is_meta_task": true/false, "type": "generate_questions|generate_content|self_prediction|verification_design|test_generation|self_reference|standard", "reason": "brief explanation"}
    """
  end

  defp parse_llm_response(response, problem) when is_map(response) do
    case response do
      %{"is_meta_task" => true, "type" => type_str} ->
        type = String.to_existing_atom(type_str)
        emit_detection(true, type, :llm_fallback)
        {:meta_task, build_guidance(type, problem)}

      _ ->
        emit_detection(false, :standard, :llm_fallback)
        {:standard, %{method: :llm_classified_standard}}
    end
  rescue
    ArgumentError ->
      # type_str wasn't a valid atom
      {:standard, %{method: :llm_invalid_type}}
  end

  defp parse_llm_response(_response, _problem) do
    {:standard, %{method: :llm_invalid_response}}
  end

  # ============================================================================
  # TELEMETRY
  # ============================================================================

  defp emit_detection(detected?, type, method) do
    :telemetry.execute(
      [:mimo, :meta_task, :detection],
      %{detected: if(detected?, do: 1, else: 0)},
      %{type: type, method: method}
    )
  end
end
