defmodule Mimo.Cognitive.SelfAsk do
  @moduledoc """
  SPEC-063: Self-Ask - Generate and answer sub-questions before final answer.

  Based on the Self-Ask prompting technique:
  Before answering a complex question, the model generates follow-up
  sub-questions, answers each, then synthesizes the final answer.

  ## Method

  1. Analyze the question for complexity
  2. Generate 2-4 sub-questions that would help answer the main question
  3. Answer each sub-question independently (with timeout protection)
  4. Synthesize all answers into a final response

  ## Usage

      # Decompose and answer
      {:ok, result} = SelfAsk.decompose_and_answer("Complex multi-part question...")

      # Just generate sub-questions (for inspection)
      {:ok, sub_questions} = SelfAsk.generate_sub_questions("Question...")
  """

  require Logger

  alias Mimo.Brain.LLM
  alias Mimo.Cognitive.ReasoningTelemetry
  alias Mimo.TaskHelper

  # Timeouts for sub-question answering
  # @sub_question_timeout 10_000  # 10 seconds per sub-question (reserved for future use)
  # 30 seconds total for all sub-questions
  @total_timeout 30_000

  @doc """
  Decompose a question into sub-questions, answer each, then synthesize.

  This is the main entry point for the Self-Ask technique.

  ## Returns

  A map containing:
  - `:original` - The original question
  - `:sub_questions` - List of generated sub-questions
  - `:sub_answers` - Map of sub-question to answer
  - `:synthesis` - The final synthesized answer
  - `:method` - Whether sub-questions were used or direct answer

  ## Options

  - `:max_sub_questions` - Maximum sub-questions to generate (default: 4)
  - `:parallel` - Answer sub-questions in parallel (default: true)
  - `:max_tokens` - Max tokens for final synthesis (default: 800)
  """
  @spec decompose_and_answer(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def decompose_and_answer(question, opts \\ []) do
    start_time = System.monotonic_time(:millisecond)
    max_sub_questions = Keyword.get(opts, :max_sub_questions, 4)
    parallel = Keyword.get(opts, :parallel, true)
    max_tokens = Keyword.get(opts, :max_tokens, 800)

    # Step 1: Generate sub-questions
    case generate_sub_questions(question, max_sub_questions: max_sub_questions) do
      {:ok, []} ->
        # No sub-questions needed, answer directly
        direct_answer(question, start_time, max_tokens)

      {:ok, sub_questions} ->
        # Step 2: Answer each sub-question
        sub_answers =
          if parallel do
            answer_parallel(sub_questions)
          else
            answer_sequential(sub_questions)
          end

        # Filter out failed answers
        successful_answers =
          Enum.filter(sub_answers, fn {_q, a} ->
            a != "[Failed]" and a != "[Timed out]"
          end)

        if Enum.empty?(successful_answers) do
          # All sub-questions failed, answer directly
          direct_answer(question, start_time, max_tokens)
        else
          # Step 3: Synthesize
          case synthesize(question, successful_answers, max_tokens) do
            {:ok, synthesis} ->
              duration = System.monotonic_time(:millisecond) - start_time
              ReasoningTelemetry.emit_technique_used(:self_ask, :decompose, true, duration)

              {:ok,
               %{
                 original: question,
                 sub_questions: sub_questions,
                 sub_answers: Map.new(sub_answers),
                 successful_count: length(successful_answers),
                 total_count: length(sub_questions),
                 synthesis: synthesis,
                 method: :decomposed
               }}

            {:error, reason} ->
              duration = System.monotonic_time(:millisecond) - start_time
              ReasoningTelemetry.emit_technique_used(:self_ask, :decompose, false, duration)
              {:error, reason}
          end
        end

      {:error, reason} ->
        # Sub-question generation failed, answer directly
        Logger.warning("[SelfAsk] Sub-question generation failed: #{inspect(reason)}")
        direct_answer(question, start_time, max_tokens)
    end
  end

  @doc """
  Generate sub-questions that would help answer the main question.

  Returns a list of 2-4 sub-questions.

  ## Options

  - `:max_sub_questions` - Maximum number of sub-questions (default: 4)
  """
  @spec generate_sub_questions(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def generate_sub_questions(question, opts \\ []) do
    max_questions = Keyword.get(opts, :max_sub_questions, 4)

    # Quick check: is this question simple enough to answer directly?
    if simple_question?(question) do
      {:ok, []}
    else
      prompt = """
      To answer this question well, what sub-questions need to be answered first?

      QUESTION: #{question}

      Consider:
      - What information or context is needed?
      - Are there implicit parts that need clarification?
      - What would a thorough answer need to address?

      Generate #{max_questions} or fewer sub-questions that would help answer this.
      If the question is simple and can be answered directly, respond with "NONE".

      Format your response as numbered questions:
      1. First sub-question?
      2. Second sub-question?
      """

      case LLM.complete(prompt, max_tokens: 200, raw: true) do
        {:ok, response} ->
          if String.contains?(String.downcase(response), "none") do
            {:ok, []}
          else
            questions = parse_questions(response)
            {:ok, Enum.take(questions, max_questions)}
          end

        {:error, reason} ->
          Logger.warning("[SelfAsk] Sub-question generation failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Check if a question would benefit from Self-Ask decomposition.

  Returns true for complex questions that have multiple parts or require
  multiple pieces of information.
  """
  @spec benefits_from_decomposition?(String.t()) :: boolean()
  def benefits_from_decomposition?(question) when is_binary(question) do
    question_lower = String.downcase(question)

    # Patterns suggesting complexity
    complexity_patterns = [
      # Multiple conjunctions
      ~r/\band\b.*\band\b/i,
      # Sequential steps
      ~r/\bfirst\b.*\bthen\b/i,
      # Multiple question types
      ~r/\bhow\b.*\bwhy\b/i,
      # Comparison tasks
      ~r/\bcompare\b.*\bcontrast\b/i,
      # Explanation with examples
      ~r/\bexplain\b.*\bexample\b/i,
      # Enumerate and explain
      ~r/\blist\b.*\bexplain\b/i,
      # Multiple questions
      ~r/\?.*\?/,
      # Multi-faceted
      ~r/\bwhat\b.*\bhow\b.*\bwhy\b/i
    ]

    # Length threshold (longer questions often benefit)
    length_threshold = String.length(question) > 100

    Enum.any?(complexity_patterns, &Regex.match?(&1, question_lower)) or length_threshold
  end

  def benefits_from_decomposition?(_), do: false

  defp simple_question?(question) do
    # Simple questions are short and don't have complexity markers
    length = String.length(question)
    has_simple_structure = not String.contains?(question, ["and then", "first", "after"])
    no_multiple_questions = length(String.split(question, "?")) <= 2

    length < 80 and has_simple_structure and no_multiple_questions
  end

  defp direct_answer(question, start_time, max_tokens) do
    case LLM.complete("Answer this question:\n\n#{question}", max_tokens: max_tokens, raw: true) do
      {:ok, answer} ->
        duration = System.monotonic_time(:millisecond) - start_time
        ReasoningTelemetry.emit_technique_used(:self_ask, :direct, true, duration)

        {:ok,
         %{
           original: question,
           sub_questions: [],
           sub_answers: %{},
           successful_count: 0,
           total_count: 0,
           synthesis: answer,
           method: :direct
         }}

      {:error, reason} ->
        duration = System.monotonic_time(:millisecond) - start_time
        ReasoningTelemetry.emit_technique_used(:self_ask, :direct, false, duration)
        {:error, reason}
    end
  end

  defp answer_parallel(sub_questions) do
    # Answer sub-questions in parallel with timeout protection
    tasks =
      Enum.map(sub_questions, fn sq ->
        TaskHelper.async_with_callers(fn ->
          answer_sub_question(sq)
        end)
      end)

    # Wait for all with total timeout
    results = Task.yield_many(tasks, @total_timeout)

    Enum.zip(sub_questions, results)
    |> Enum.map(fn {sq, result} ->
      case result do
        {task, {:ok, answer}} ->
          Task.shutdown(task, :brutal_kill)
          {sq, answer}

        {task, nil} ->
          Task.shutdown(task, :brutal_kill)
          {sq, "[Timed out]"}

        nil ->
          {sq, "[Timed out]"}
      end
    end)
  end

  defp answer_sequential(sub_questions) do
    Enum.map(sub_questions, fn sq ->
      {sq, answer_sub_question(sq)}
    end)
  end

  defp answer_sub_question(sub_question) do
    prompt = "Answer briefly and directly:\n\n#{sub_question}"

    case LLM.complete(prompt, max_tokens: 150, raw: true) do
      {:ok, answer} -> answer
      {:error, _reason} -> "[Failed]"
    end
  rescue
    _ -> "[Failed]"
  end

  defp synthesize(original_question, sub_answers, max_tokens) do
    context =
      Enum.map_join(sub_answers, "\n\n", fn {q, a} -> "Q: #{q}\nA: #{a}" end)

    prompt = """
    Based on these sub-questions and answers:

    #{context}

    Now synthesize a complete answer to the original question:
    #{original_question}

    Provide a thorough, well-organized answer that incorporates all the relevant information.
    """

    LLM.complete(prompt, max_tokens: max_tokens, raw: true)
  end

  defp parse_questions(response) do
    response
    |> String.split("\n")
    |> Enum.filter(fn line ->
      # Match lines starting with numbers or bullets
      Regex.match?(~r/^\s*[\d\-\*•]+[\.\)]\s*\S/, line)
    end)
    |> Enum.map(fn line ->
      # Remove numbering/bullets
      line
      |> String.replace(~r/^\s*[\d\-\*•]+[\.\)]\s*/, "")
      |> String.trim()
    end)
    # Filter out too-short entries
    |> Enum.filter(&(String.length(&1) > 5))
  end
end
