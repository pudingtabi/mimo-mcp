defmodule Mimo.Cognitive.RephraseRespond do
  @moduledoc """
  SPEC-063: Rephrase and Respond (RaR) - Clarify questions before answering.

  Based on UCLA research (arXiv 2311.04205):
  Before answering, the LLM rephrases the question to clarify implicit requirements.

  ## Problem Addressed

  Many tasks fail because of ambiguous or implicit requirements:
  - "I'm going to ask you 5 trivia questions..." → Model waits for questions instead of generating them
  - Implicit sub-tasks get overlooked
  - Meta-instructions are interpreted literally

  ## Method

  1. Rephrase the question to make ALL implicit requirements explicit
  2. Identify any self-generation requirements
  3. Then respond based on the clarified interpretation

  ## Usage

      # Just rephrase (for inspection)
      {:ok, rephrased} = RephraseRespond.rephrase("I'm going to ask you 5 trivia questions...")
      
      # Full pipeline: rephrase then respond
      {:ok, result} = RephraseRespond.rephrase_and_respond(question)
  """

  require Logger

  alias Mimo.Brain.LLM
  alias Mimo.Cognitive.ReasoningTelemetry

  @doc """
  Rephrase a question to make implicit requirements explicit.

  This is the core RaR technique - before answering any question,
  first rephrase it to clarify what is actually being asked.

  ## Returns

  A map containing:
  - `:original` - The original question
  - `:rephrased` - The clarified version
  - `:implicit_requirements` - List of identified implicit requirements
  - `:is_meta_task` - Whether the task requires self-generation

  ## Options

  - `:detailed` - Return detailed analysis (default: false)
  """
  @spec rephrase(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def rephrase(question, opts \\ []) do
    start_time = System.monotonic_time(:millisecond)
    detailed = Keyword.get(opts, :detailed, false)

    prompt = """
    Rephrase this question to make ALL implicit requirements explicit.

    Consider carefully:
    1. Are there sub-tasks that need to be GENERATED (not provided)?
    2. What assumptions might be wrong if taken literally?
    3. What would a literal interpretation miss?
    4. Is this a META-TASK requiring self-generated content?

    ORIGINAL QUESTION:
    #{question}

    Provide your analysis in this JSON format:
    {
      "rephrased": "The fully clarified version of the question...",
      "implicit_requirements": ["requirement 1", "requirement 2"],
      "is_meta_task": true/false,
      "meta_task_explanation": "If meta-task, explain what must be self-generated"
    }

    Return ONLY the JSON:
    """

    case LLM.complete(prompt, max_tokens: 400, format: :json, raw: true) do
      {:ok, result} when is_map(result) ->
        duration = System.monotonic_time(:millisecond) - start_time
        ReasoningTelemetry.emit_technique_used(:rephrase, :rephrase, true, duration)

        response = %{
          original: question,
          rephrased: Map.get(result, "rephrased", question),
          implicit_requirements: Map.get(result, "implicit_requirements", []),
          is_meta_task: Map.get(result, "is_meta_task", false),
          meta_task_explanation: Map.get(result, "meta_task_explanation")
        }

        if detailed do
          {:ok, Map.put(response, :raw_analysis, result)}
        else
          {:ok, response}
        end

      {:ok, text} when is_binary(text) ->
        # Try to extract JSON from text response
        duration = System.monotonic_time(:millisecond) - start_time

        case extract_json(text) do
          {:ok, parsed} ->
            ReasoningTelemetry.emit_technique_used(:rephrase, :rephrase, true, duration)

            {:ok,
             %{
               original: question,
               rephrased: Map.get(parsed, "rephrased", text),
               implicit_requirements: Map.get(parsed, "implicit_requirements", []),
               is_meta_task: Map.get(parsed, "is_meta_task", false),
               meta_task_explanation: Map.get(parsed, "meta_task_explanation")
             }}

          :error ->
            # Use the text as the rephrased version
            ReasoningTelemetry.emit_technique_used(:rephrase, :rephrase, true, duration)

            {:ok,
             %{
               original: question,
               rephrased: text,
               implicit_requirements: [],
               is_meta_task: false,
               meta_task_explanation: nil
             }}
        end

      {:error, reason} ->
        duration = System.monotonic_time(:millisecond) - start_time
        ReasoningTelemetry.emit_technique_used(:rephrase, :rephrase, false, duration)
        Logger.warning("[RephraseRespond] Rephrase failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Full RaR pipeline: rephrase the question, then respond based on clarified interpretation.

  This is the main entry point for using RaR technique.

  ## Returns

  A map containing:
  - `:original` - The original question
  - `:rephrased` - The clarified interpretation
  - `:implicit_requirements` - Identified implicit requirements
  - `:answer` - The response based on clarified interpretation

  ## Options

  - `:max_tokens` - Max tokens for the answer (default: 800)
  - `:include_reasoning` - Include reasoning in answer (default: true)
  """
  @spec rephrase_and_respond(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def rephrase_and_respond(question, opts \\ []) do
    start_time = System.monotonic_time(:millisecond)
    max_tokens = Keyword.get(opts, :max_tokens, 800)
    include_reasoning = Keyword.get(opts, :include_reasoning, true)

    with {:ok, rephrase_result} <- rephrase(question, opts) do
      # Build the response prompt
      prompt = build_respond_prompt(question, rephrase_result, include_reasoning)

      case LLM.complete(prompt, max_tokens: max_tokens, raw: true) do
        {:ok, answer} ->
          duration = System.monotonic_time(:millisecond) - start_time
          ReasoningTelemetry.emit_technique_used(:rephrase, :respond, true, duration)

          {:ok,
           %{
             original: question,
             rephrased: rephrase_result.rephrased,
             implicit_requirements: rephrase_result.implicit_requirements,
             is_meta_task: rephrase_result.is_meta_task,
             answer: answer
           }}

        {:error, reason} ->
          duration = System.monotonic_time(:millisecond) - start_time
          ReasoningTelemetry.emit_technique_used(:rephrase, :respond, false, duration)
          Logger.warning("[RephraseRespond] Respond failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Quick check if a question likely needs rephrasing.

  Uses heuristics to detect ambiguous or meta-task patterns.
  Returns true if rephrasing would likely help.
  """
  @spec needs_rephrasing?(String.t()) :: boolean()
  def needs_rephrasing?(question) when is_binary(question) do
    question_lower = String.downcase(question)

    # Patterns that suggest implicit requirements
    patterns = [
      # Meta-task patterns
      ~r/i'm going to ask you/i,
      ~r/i'll ask you/i,
      ~r/predict whether you/i,
      ~r/before (you |answering)/i,
      ~r/for each.*first/i,

      # Self-generation patterns
      ~r/come up with/i,
      ~r/think of \d+/i,
      ~r/generate.*yourself/i,
      ~r/create your own/i,

      # Ambiguity patterns
      # Vague references
      ~r/\bthis\b.*\bthat\b/i,
      # Multiple questions
      ~r/how many.*\?.*\?/i,

      # Implicit counting/tracking
      ~r/how many (times|predictions|correct)/i,
      ~r/count (the|how many)/i
    ]

    Enum.any?(patterns, &Regex.match?(&1, question_lower))
  end

  def needs_rephrasing?(_), do: false

  defp build_respond_prompt(original, rephrase_result, include_reasoning) do
    meta_task_note =
      if rephrase_result.is_meta_task do
        """

        ⚠️ META-TASK DETECTED: #{rephrase_result.meta_task_explanation}
        You must GENERATE the required content yourself - it is NOT provided.
        """
      else
        ""
      end

    implicit_note =
      if Enum.empty?(rephrase_result.implicit_requirements) do
        ""
      else
        requirements = Enum.map_join(rephrase_result.implicit_requirements, "\n- ", & &1)

        """

        IMPLICIT REQUIREMENTS IDENTIFIED:
        - #{requirements}
        """
      end

    reasoning_instruction =
      if include_reasoning do
        "Show your reasoning, then provide the answer."
      else
        "Provide a direct answer."
      end

    """
    ORIGINAL QUESTION:
    #{original}

    CLARIFIED INTERPRETATION:
    #{rephrase_result.rephrased}
    #{implicit_note}#{meta_task_note}

    #{reasoning_instruction}
    """
  end

  defp extract_json(text) do
    # Try to find JSON in the text
    case Regex.run(~r/\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}/s, text) do
      [json_str] ->
        case Jason.decode(json_str) do
          {:ok, parsed} when is_map(parsed) -> {:ok, parsed}
          _ -> :error
        end

      _ ->
        :error
    end
  end
end
