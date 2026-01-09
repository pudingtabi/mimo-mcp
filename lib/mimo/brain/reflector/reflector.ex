defmodule Mimo.Brain.Reflector do
  @moduledoc """
  Main reflection orchestrator for the Reflective Intelligence System.

  Part of SPEC-043: Reflective Intelligence System.

  Coordinates the evaluation, confidence estimation, error detection,
  and iterative refinement of AI outputs. Implements the "reflect before
  responding" pattern that bridges the Reflection Gap.

  ## The Reflection Loop

  ```
  Input → Generate Draft → Evaluate → Score ≥ Threshold?
                              ↓              ↓
                          Issues?        YES → Output
                              ↓
                          Refine ← NO (if iterations < max)
  ```

  ## Example

      # Reflect on an output before delivering
      case Reflector.reflect_and_refine(output, context) do
        {:ok, result} ->
          # Output passed quality threshold
          deliver(result.output, result.confidence)

        {:uncertain, result} ->
          # Couldn't meet threshold after max iterations
          deliver_with_warning(result.output, result.warning)

        {:error, reason} ->
          # Reflection failed
          handle_error(reason)
      end

  ## Configuration

  See `Mimo.Brain.Reflector.Config` for configuration options including:
  - Quality thresholds
  - Maximum iterations
  - Dimension weights
  - Auto-reflect rules
  """

  require Logger

  alias Mimo.Brain.Memory

  alias Mimo.Brain.Reflector.{
    ConfidenceEstimator,
    ConfidenceOutput,
    ErrorDetector,
    Evaluator,
    Optimizer
  }

  alias Mimo.Cognitive.Reasoner
  alias Mimo.Skills.Verify
  @default_threshold 0.70
  @max_iterations 3

  @type reflection_result :: %{
          output: String.t(),
          evaluation: map(),
          confidence: map(),
          iterations: non_neg_integer(),
          history: list(),
          refined: boolean()
        }

  @type reflect_opts :: [
          threshold: float(),
          max_iterations: pos_integer(),
          skip_refinement: boolean(),
          store_outcome: boolean(),
          fast_mode: boolean()
        ]

  @doc """
  Evaluate output quality and iteratively refine if needed.

  ## Parameters

  - `output` - The generated output to reflect on
  - `context` - Map containing:
    - `:query` - Original query/prompt
    - `:memories` - Retrieved memories
    - `:reasoning_steps` - Reasoning chain if available
    - `:tool_results` - Tool outputs used

  ## Options

  - `:threshold` - Quality score threshold (default: 0.70)
  - `:max_iterations` - Maximum refinement iterations (default: 3)
  - `:skip_refinement` - Only evaluate, don't refine (default: false)
  - `:store_outcome` - Store reflection outcome in memory (default: true)
  - `:fast_mode` - Use fast evaluation (default: false)
  """
  @spec reflect_and_refine(String.t(), map(), reflect_opts()) ::
          {:ok, reflection_result()}
          | {:uncertain, reflection_result()}
          | {:error, term()}
  def reflect_and_refine(output, context, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    max_iter = Keyword.get(opts, :max_iterations, @max_iterations)
    skip_refinement = Keyword.get(opts, :skip_refinement, false)
    store_outcome = Keyword.get(opts, :store_outcome, true)

    result =
      if skip_refinement do
        # Just evaluate, don't iterate
        evaluation = Evaluator.evaluate(output, context, opts)
        confidence = ConfidenceEstimator.estimate(output, context, opts)

        status = if evaluation.aggregate_score >= threshold, do: :ok, else: :uncertain

        {status,
         %{
           output: output,
           evaluation: evaluation,
           confidence: confidence,
           iterations: 0,
           history: [],
           refined: false
         }}
      else
        # Full iterative refinement
        iterate(output, context, threshold, max_iter, 0, [], opts)
      end

    # Store outcome in memory for learning
    if store_outcome do
      store_reflection_outcome(result, context)
    end

    case result do
      {:ok, _} = success -> success
      {:uncertain, data} -> {:uncertain, Map.put(data, :warning, generate_warning(data))}
    end
  rescue
    e in DBConnection.OwnershipError ->
      Logger.debug("[Reflector] Reflection skipped (sandbox mode): #{Exception.message(e)}")
      {:error, :sandbox_mode}

    e in DBConnection.ConnectionError ->
      Logger.debug("[Reflector] Reflection skipped (connection): #{Exception.message(e)}")
      {:error, :sandbox_mode}

    e ->
      Logger.error("Reflection failed: #{Exception.message(e)}")
      {:error, {:reflection_failed, Exception.message(e)}}
  end

  @doc """
  Quick reflection - evaluate without refinement.
  Useful for fast feedback when refinement isn't needed.
  """
  @spec quick_reflect(String.t(), map()) :: %{score: float(), pass: boolean(), issues: list()}
  def quick_reflect(output, context) do
    evaluation = Evaluator.quick_evaluate(output, context)
    errors = ErrorDetector.quick_detect(output, context)

    %{
      score: evaluation.score,
      pass: evaluation.pass and errors == [],
      issues: Enum.map(errors, & &1.description)
    }
  end

  @doc """
  Check if output should be reflected on (based on configuration).
  """
  @spec should_reflect?(String.t(), map()) :: boolean()
  def should_reflect?(output, context) do
    # Reflect on complex outputs
    output_length = String.length(output)
    has_tool_results = (context[:tool_results] || []) != []
    is_code_heavy = String.match?(output, ~r/```/)

    cond do
      # Always reflect on long outputs
      output_length > 2000 -> true
      # Reflect when using tool results (important to verify)
      has_tool_results -> true
      # Reflect on code-heavy outputs (any length with code)
      is_code_heavy -> true
      # Skip for short, simple outputs
      output_length < 200 -> false
      # Default: reflect on medium outputs
      true -> true
    end
  end

  @doc """
  Get a formatted output with confidence indicators.
  """
  @spec format_with_confidence(String.t(), map()) :: map()
  def format_with_confidence(output, context) do
    confidence = ConfidenceEstimator.estimate(output, context)
    ConfidenceOutput.format(output, confidence)
  end

  @doc """
  Analyze reflection patterns from stored outcomes.
  """
  @spec analyze_patterns(keyword()) :: map()
  def analyze_patterns(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    _time_filter = Keyword.get(opts, :time_filter, "last 30 days")

    # Search for reflection outcomes in memory
    reflections =
      Memory.search_memories("reflection outcome",
        limit: limit,
        min_similarity: 0.4
      )

    %{
      total_reflections: length(reflections),
      success_rate: calculate_success_rate(reflections),
      common_issues: extract_common_issues(reflections),
      avg_iterations: calculate_avg_iterations(reflections),
      recommendations: generate_recommendations(reflections)
    }
  end

  defp iterate(output, context, threshold, max_iter, current_iter, history, opts) do
    # Evaluate current output
    evaluation = Evaluator.evaluate(output, context, opts)
    confidence = ConfidenceEstimator.estimate(output, context, opts)

    cond do
      # Output meets quality threshold
      evaluation.aggregate_score >= threshold ->
        {:ok,
         %{
           output: output,
           evaluation: evaluation,
           confidence: confidence,
           iterations: current_iter,
           history: history,
           refined: current_iter > 0
         }}

      # Reached maximum iterations
      current_iter >= max_iter ->
        {:uncertain,
         %{
           output: output,
           evaluation: evaluation,
           confidence: confidence,
           iterations: current_iter,
           history: history,
           refined: current_iter > 0
         }}

      # Try to refine
      true ->
        Logger.debug(
          "Reflector: iteration #{current_iter + 1}, score #{evaluation.aggregate_score}"
        )

        case refine(output, evaluation, context) do
          {:ok, refined_output} ->
            new_history = [
              %{
                iteration: current_iter,
                score: evaluation.aggregate_score,
                issues: length(evaluation.issues)
              }
              | history
            ]

            iterate(
              refined_output,
              context,
              threshold,
              max_iter,
              current_iter + 1,
              new_history,
              opts
            )

          {:error, _reason} ->
            # Refinement failed - return current output as uncertain
            {:uncertain,
             %{
               output: output,
               evaluation: evaluation,
               confidence: confidence,
               iterations: current_iter,
               history: history,
               refined: false
             }}
        end
    end
  end

  defp refine(output, evaluation, context) do
    # Build refinement prompt based on issues
    refinement_prompt = build_refinement_prompt(output, evaluation, context)

    # Use reasoning engine for refinement
    case Reasoner.guided(refinement_prompt, strategy: :cot) do
      {:ok, result} ->
        # Extract the conclusion/refined output
        refined = extract_refined_output(result, output)
        {:ok, refined}

      {:error, reason} ->
        Logger.warning("Refinement failed: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.error("Refinement error: #{Exception.message(e)}")
      {:error, {:refinement_error, Exception.message(e)}}
  end

  defp build_refinement_prompt(output, evaluation, context) do
    query = context[:query] || "the original request"

    issues_text =
      evaluation.issues
      |> Enum.map_join("\n", fn issue ->
        "- #{issue.dimension}: #{issue.description}"
      end)

    suggestions_text =
      evaluation.suggestions
      |> Enum.take(3)
      |> Enum.map_join("\n", fn s -> "- #{s.action}" end)

    """
    Please improve the following response. The original query was: "#{query}"

    Current response:
    #{String.slice(output, 0, 2000)}

    Issues identified (score: #{Float.round(evaluation.aggregate_score, 2)}):
    #{issues_text}

    Suggested improvements:
    #{suggestions_text}

    Please provide an improved version that addresses these issues while maintaining the helpful parts of the original response.
    """
  end

  defp extract_refined_output(result, original) do
    # Try to get conclusion from reasoner result
    cond do
      is_map(result) and Map.has_key?(result, :conclusion) ->
        result.conclusion

      is_map(result) and Map.has_key?(result, :guidance) ->
        # Guided reasoning returns guidance - use that
        result.guidance

      is_binary(result) ->
        result

      true ->
        # Fallback to original
        original
    end
  end

  defp store_reflection_outcome({status, result}, context) do
    query = context[:query] || "unknown query"
    score = result.evaluation.aggregate_score
    iterations = result.iterations
    _issues = length(result.evaluation.issues)

    # Generate context hash for matching outcomes later
    context_hash = generate_context_hash(query, context)

    # Record prediction to Optimizer for feedback loop
    record_to_optimizer(result.evaluation, context_hash, iterations)

    content =
      case status do
        :ok ->
          "Reflection success: Query '#{String.slice(query, 0, 50)}...' passed with score #{Float.round(score, 2)} after #{iterations} iterations"

        :uncertain ->
          issue_summary =
            result.evaluation.issues
            |> Enum.map(& &1.dimension)
            |> Enum.uniq()
            |> Enum.join(", ")

          "Reflection uncertain: Query '#{String.slice(query, 0, 50)}...' reached #{iterations} iterations with score #{Float.round(score, 2)}. Issues: #{issue_summary}"
      end

    importance = if status == :ok, do: 0.5, else: 0.7

    # Store asynchronously to not block response
    Mimo.Sandbox.run_async(Mimo.Repo, fn ->
      try do
        Memory.persist_memory(content, "observation", importance)

        # WIRE 3: Adjust importance of related memories based on reflection outcome
        # When reflection succeeds, boost memories that helped. When it fails, reduce.
        adjust_related_memory_importance(query, status)
      rescue
        _ -> :ok
      end
    end)

    :ok
  rescue
    _ -> :ok
  end

  # WIRE 3: Adjust related memory importance based on reflection outcome
  defp adjust_related_memory_importance(query, status) do
    # Search for memories that were likely used in this query
    case Memory.search_memories(query, limit: 3) do
      memories when is_list(memories) and memories != [] ->
        adjustment = if status == :ok, do: 0.05, else: -0.03

        Enum.each(memories, fn memory ->
          new_importance = min(1.0, max(0.1, (memory.importance || 0.5) + adjustment))
          Memory.update_importance(memory.id, new_importance)
        end)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp generate_context_hash(query, context) do
    # Create a hash from query and key context elements for matching
    content =
      [
        query,
        context[:thread_id] || "",
        context[:tool] || ""
      ]
      |> Enum.join("::")

    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp record_to_optimizer(evaluation, context_hash, iterations) do
    Task.start(fn ->
      try do
        Optimizer.record_prediction(evaluation, context_hash, iterations: iterations)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end)
  end

  defp generate_warning(result) do
    score = result.evaluation.aggregate_score
    issues = result.evaluation.issues

    main_issues =
      issues
      |> Enum.filter(&(&1.severity == :high))
      |> Enum.map(& &1.dimension)
      |> Enum.uniq()
      |> Enum.join(", ")

    if main_issues != "" do
      "Response may have issues with: #{main_issues} (confidence: #{Float.round(score, 2)})"
    else
      "Response quality below threshold after #{result.iterations} refinement attempts (score: #{Float.round(score, 2)})"
    end
  end

  defp calculate_success_rate(reflections) do
    if reflections == [] do
      0.0
    else
      successes =
        Enum.count(reflections, fn r ->
          content = r[:content] || r["content"] || ""
          String.contains?(content, "success")
        end)

      successes / length(reflections)
    end
  end

  defp extract_common_issues(reflections) do
    reflections
    |> Enum.flat_map(fn r ->
      content = r[:content] || r["content"] || ""

      # Extract issue dimensions from stored content
      ~w(correctness completeness grounding clarity confidence error_risk)
      |> Enum.filter(&String.contains?(content, &1))
    end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_, count} -> -count end)
    |> Enum.take(5)
    |> Map.new()
  end

  defp calculate_avg_iterations(reflections) do
    if reflections == [] do
      0.0
    else
      # Extract iteration counts from stored content
      iterations =
        Enum.map(reflections, fn r ->
          content = r[:content] || r["content"] || ""

          case Regex.run(~r/(\d+) iteration/, content) do
            [_, count] -> String.to_integer(count)
            _ -> 0
          end
        end)

      Enum.sum(iterations) / length(reflections)
    end
  end

  defp generate_recommendations(reflections) do
    common_issues = extract_common_issues(reflections)

    recommendations = []

    recommendations =
      if Map.get(common_issues, "grounding", 0) > 3 do
        ["Increase memory retrieval limit to improve grounding" | recommendations]
      else
        recommendations
      end

    recommendations =
      if Map.get(common_issues, "completeness", 0) > 3 do
        ["Consider breaking complex queries into sub-questions" | recommendations]
      else
        recommendations
      end

    recommendations =
      if Map.get(common_issues, "confidence", 0) > 3 do
        ["Add more knowledge to memory for frequently-asked topics" | recommendations]
      else
        recommendations
      end

    if recommendations == [] do
      ["Reflection patterns look healthy - continue current approach"]
    else
      recommendations
    end
  end

  @doc """
  Verify a claim using executable verification methods.

  This integrates the Verify skill for actual checking instead of ceremonial claims.
  Based on SPEC-AI-TEST Recommendations for executable verification.

  ## Examples

      iex> verify_claim("Mississippi has 4 s's", %{"operation" => "count", "text" => "Mississippi", "target" => "s", "type" => "letter"})
      {:ok, %{verified: true, expected: 4, actual: 4, method: "character_enumeration"}}

      iex> verify_claim("17 * 23 = 391", %{"operation" => "math", "expression" => "17 * 23", "claimed_result" => 391})
      {:ok, %{verified: true, claimed: 391, actual: 391, method: "safe_arithmetic"}}
  """
  @spec verify_claim(String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def verify_claim(claim, verification_params) do
    case Verify.verify(verification_params) do
      {:ok, result} ->
        {:ok, Map.put(result, :claim, claim)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Enhance reflection with executable verification.

  When reflecting on outputs that make verifiable claims (counts, arithmetic, logic),
  this function runs actual verification checks.

  Returns enhanced evaluation with verification results.
  """
  @spec reflect_with_verification(String.t(), map(), keyword()) ::
          {:ok, map()} | {:uncertain, map()} | {:error, term()}
  def reflect_with_verification(output, context, opts \\ []) do
    # Extract potential verifiable claims from output
    verifiable_claims = extract_verifiable_claims(output, context)

    # Run standard reflection
    reflection_result = reflect_and_refine(output, context, opts)

    # Run verification checks on claims
    verification_results =
      Enum.map(verifiable_claims, fn claim ->
        verify_claim(claim.text, claim.params)
      end)

    # Combine results
    case reflection_result do
      {:ok, data} ->
        {:ok, Map.put(data, :verifications, verification_results)}

      {:uncertain, data} ->
        {:uncertain, Map.put(data, :verifications, verification_results)}

      error ->
        error
    end
  end

  # Extract verifiable claims from output.
  #
  # Looks for patterns that can be verified:
  # - Counting claims ("X has Y letters/items")
  # - Arithmetic claims ("X * Y = Z")
  # - Logic claims with premises
  @spec extract_verifiable_claims(String.t(), map()) :: list(map())
  defp extract_verifiable_claims(output, _context) do
    claims = []

    # Pattern 1: Counting claims (e.g., "Mississippi has 4 s's")
    claims = claims ++ extract_counting_claims(output)

    # Pattern 2: Arithmetic claims (e.g., "17 * 23 = 391")
    claims = claims ++ extract_arithmetic_claims(output)

    claims
  end

  defp extract_counting_claims(output) do
    # Look for patterns like "X has Y <letters/words/characters>"
    regex = ~r/(\w+)\s+has\s+(\d+)\s+(letter|word|character)s?\s+['"]?(\w?)['"]?/i

    Regex.scan(regex, output)
    |> Enum.map(fn [_full, text, count, type, target] ->
      %{
        text: "#{text} has #{count} #{type}#{if target != "", do: " '#{target}'", else: ""}",
        params: %{
          "operation" => "count",
          "text" => text,
          "type" => type,
          "target" => if(target != "", do: target, else: nil)
        }
      }
    end)
  end

  defp extract_arithmetic_claims(output) do
    # Look for patterns like "17 * 23 = 391"
    regex = ~r/(\d+)\s*([+\-*\/])\s*(\d+)\s*=\s*(\d+)/

    Regex.scan(regex, output)
    |> Enum.map(fn [_full, a, op, b, result] ->
      expression = "#{a} #{op} #{b}"

      %{
        text: "#{expression} = #{result}",
        params: %{
          "operation" => "math",
          "expression" => expression,
          "claimed_result" => String.to_integer(result)
        }
      }
    end)
  end

  @doc """
  Get reflector statistics from the Optimizer.
  Delegates to the Optimizer GenServer for backward compatibility.
  """
  @spec stats() :: {:ok, map()} | {:error, term()}
  def stats do
    try do
      {:ok, Optimizer.stats()}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end
end
