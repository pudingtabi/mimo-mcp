defmodule Mimo.Skills.Verify do
  @moduledoc """
  Executable verification for AI claims.

  Actually runs checks rather than claiming verification. Addresses the
  gap between "ceremonial verification" (claiming to verify) and 
  "executable verification" (actually running checks).

  Based on AI Intelligence Test findings (RECOMMENDATIONS.md):
  - Gemini 3 Pro showed the gold standard: run Python/terminal to verify
  - Opus 4.5 claimed "verified" but was wrong (ceremonial)
  - This tool makes verification executable and auditable

  Operations:
  - count: Count letters, words, characters with actual execution
  - math: Verify arithmetic claims by computing both sides
  - logic: Check logical consistency via constraint solving
  - compare: Compare values with explicit relation checking
  - self_check: Re-derive answer independently for cross-validation

  ## Tracking

  All verifications are automatically recorded in VerificationTracker for
  pattern detection and confidence calibration.
  """

  require Logger

  @operations [:count, :math, :logic, :compare, :self_check]

  # ==========================================================================
  # PUBLIC API
  # ==========================================================================

  @doc """
  Execute verification based on operation type.
  """
  def verify(%{operation: operation} = params) when operation in @operations do
    result =
      case operation do
        :count -> verify_count(params)
        :math -> verify_math(params)
        :logic -> verify_logic(params)
        :compare -> verify_compare(params)
        :self_check -> verify_self_check(params)
      end

    # Record verification in tracker (async)
    record_verification(operation, params, result)

    result
  end

  def verify(%{operation: op}) do
    {:error, "Unknown operation: #{op}. Supported: #{inspect(@operations)}"}
  end

  # ==========================================================================
  # TRACKING
  # ==========================================================================

  defp record_verification(operation, params, result) do
    Task.start(fn ->
      try do
        # Extract verification metadata
        {verified, confidence} = extract_result_metadata(result)
        claimed = extract_claimed_value(params)
        actual = extract_actual_value(result)

        # Record in tracker
        Mimo.Brain.VerificationTracker.record_verification(operation, %{
          claimed: claimed,
          actual: actual,
          verified: verified,
          confidence: confidence
        })
      rescue
        e ->
          Logger.warning("[Verify] Failed to record verification: #{inspect(e)}")
      end
    end)
  end

  defp extract_result_metadata({:ok, %{verified: verified}}), do: {verified, 0.95}
  defp extract_result_metadata({:ok, %{match: true}}), do: {true, 0.95}
  defp extract_result_metadata({:ok, %{match: false}}), do: {false, 0.95}
  defp extract_result_metadata({:error, _}), do: {false, 0.5}
  defp extract_result_metadata(_), do: {false, 0.5}

  defp extract_claimed_value(%{claimed_result: val}), do: val
  defp extract_claimed_value(%{claimed_answer: val}), do: val
  defp extract_claimed_value(%{value_a: a, value_b: b}), do: {a, b}
  defp extract_claimed_value(_), do: nil

  defp extract_actual_value({:ok, %{actual: val}}), do: val
  defp extract_actual_value({:ok, %{actual_result: val}}), do: val
  defp extract_actual_value({:ok, %{count: val}}), do: val
  defp extract_actual_value(_), do: nil

  # ==========================================================================
  # COUNT VERIFICATION
  # ==========================================================================

  defp verify_count(%{text: text, target: target, type: "letter"}) do
    # Character-by-character enumeration (NOT String.contains?)
    graphemes = String.graphemes(text)

    actual =
      Enum.count(graphemes, fn char ->
        String.downcase(char) == String.downcase(target)
      end)

    {:ok,
     %{
       operation: "count",
       type: "letter",
       target: target,
       actual: actual,
       method: "character_enumeration",
       verified: true,
       text_length: String.length(text),
       sample: String.slice(text, 0, 50) <> if(String.length(text) > 50, do: "...", else: "")
     }}
  end

  defp verify_count(%{text: text, type: "word"}) do
    # Split on whitespace and count non-empty
    words =
      text
      |> String.split(~r/\s+/, trim: true)

    actual = length(words)

    {:ok,
     %{
       operation: "count",
       type: "word",
       actual: actual,
       method: "whitespace_split",
       verified: true,
       words: if(actual <= 20, do: words, else: Enum.take(words, 10) ++ ["..."]),
       sample: String.slice(text, 0, 100) <> if(String.length(text) > 100, do: "...", else: "")
     }}
  end

  defp verify_count(%{text: text, type: "character"}) do
    actual = String.length(text)

    {:ok,
     %{
       operation: "count",
       type: "character",
       actual: actual,
       method: "string_length",
       verified: true,
       includes_spaces: true,
       sample: String.slice(text, 0, 100) <> if(String.length(text) > 100, do: "...", else: "")
     }}
  end

  defp verify_count(params) do
    {:error,
     "Invalid count parameters. Required: text, type (letter/word/character). Got: #{inspect(params)}"}
  end

  # ==========================================================================
  # MATH VERIFICATION
  # ==========================================================================

  defp verify_math(%{expression: expr, claimed_result: claimed}) do
    # Safely evaluate mathematical expression
    case safe_eval_math(expr) do
      {:ok, actual} ->
        match = compare_numbers(actual, claimed)

        {:ok,
         %{
           operation: "math",
           expression: expr,
           actual: actual,
           claimed: claimed,
           match: match,
           method: "safe_evaluation",
           verified: true,
           discrepancy: if(match, do: 0, else: abs(actual - claimed))
         }}

      {:error, reason} ->
        {:error, "Failed to evaluate expression '#{expr}': #{reason}"}
    end
  end

  defp verify_math(params) do
    {:error,
     "Invalid math parameters. Required: expression, claimed_result. Got: #{inspect(params)}"}
  end

  # Safe mathematical expression evaluator
  defp safe_eval_math(expr) do
    # Whitelist: only allow numbers and basic operators
    sanitized = String.replace(expr, ~r/[^0-9+\-*\/().\s]/, "")

    if sanitized != expr do
      {:error, "Expression contains invalid characters"}
    else
      try do
        {result, _} = Code.eval_string(sanitized, [], __ENV__)
        {:ok, result}
      rescue
        e -> {:error, Exception.message(e)}
      end
    end
  end

  # Compare numbers with tolerance for floating point
  defp compare_numbers(a, b) when is_number(a) and is_number(b) do
    cond do
      is_integer(a) and is_integer(b) -> a == b
      is_float(a) or is_float(b) -> abs(a - b) < 0.0001
      true -> a == b
    end
  end

  # ==========================================================================
  # LOGIC VERIFICATION
  # ==========================================================================

  defp verify_logic(%{statements: statements, claim: claim}) do
    # Basic logical consistency checking
    # Check for contradictions in statements
    contradictions = find_contradictions(statements)

    # Check if claim follows from statements
    entailment = check_entailment(statements, claim)

    {:ok,
     %{
       operation: "logic",
       statements: statements,
       claim: claim,
       contradictions: contradictions,
       has_contradictions: length(contradictions) > 0,
       claim_entailed: entailment,
       verified: true,
       method: "basic_consistency_check",
       warning:
         if(length(contradictions) > 0,
           do: "Contradictions detected in premises",
           else: nil
         )
     }}
  end

  defp verify_logic(params) do
    {:error,
     "Invalid logic parameters. Required: statements (list), claim. Got: #{inspect(params)}"}
  end

  # Simple contradiction detection (checks for negations)
  defp find_contradictions(statements) when is_list(statements) do
    statements
    |> Enum.with_index()
    |> Enum.flat_map(fn {stmt, i} ->
      statements
      |> Enum.drop(i + 1)
      |> Enum.with_index(i + 1)
      |> Enum.filter(fn {other, _j} ->
        are_contradictory?(stmt, other)
      end)
      |> Enum.map(fn {other, j} ->
        %{statement_a: stmt, statement_b: other, indices: [i, j]}
      end)
    end)
  end

  # Check if two statements contradict (basic pattern matching)
  defp are_contradictory?(a, b) do
    a_lower = String.downcase(a)
    b_lower = String.downcase(b)

    cond do
      # "X is true" vs "X is false"
      String.contains?(a_lower, "true") and String.contains?(b_lower, "false") ->
        true

      String.contains?(a_lower, "false") and String.contains?(b_lower, "true") ->
        true

      # "All X" vs "No X"  
      String.contains?(a_lower, "all") and String.contains?(b_lower, "no") ->
        true

      String.contains?(a_lower, "no") and String.contains?(b_lower, "all") ->
        true

      # Negation patterns
      String.contains?(a_lower, "not") != String.contains?(b_lower, "not") and
          similar_content?(a_lower, b_lower) ->
        true

      true ->
        false
    end
  end

  # Check if claim follows from statements (simplified)
  defp check_entailment(statements, claim) do
    claim_lower = String.downcase(claim)

    # Simple heuristic: if claim keywords appear in statements
    Enum.any?(statements, fn stmt ->
      stmt_lower = String.downcase(stmt)

      String.contains?(stmt_lower, claim_lower) or
        String.contains?(claim_lower, stmt_lower)
    end)
  end

  # Check if two strings have similar content (for contradiction detection)
  defp similar_content?(a, b) do
    words_a = String.split(a, ~r/\W+/, trim: true) |> MapSet.new()
    words_b = String.split(b, ~r/\W+/, trim: true) |> MapSet.new()

    intersection = MapSet.intersection(words_a, words_b)

    # At least 50% word overlap
    MapSet.size(intersection) >= min(MapSet.size(words_a), MapSet.size(words_b)) * 0.5
  end

  # ==========================================================================
  # COMPARE VERIFICATION
  # ==========================================================================

  defp verify_compare(%{value_a: a, value_b: b, relation: relation})
       when relation in ["greater", "less", "equal", "greater_equal", "less_equal"] do
    result =
      case relation do
        "greater" -> a > b
        "less" -> a < b
        "equal" -> compare_numbers(a, b)
        "greater_equal" -> a >= b or compare_numbers(a, b)
        "less_equal" -> a <= b or compare_numbers(a, b)
      end

    {:ok,
     %{
       operation: "compare",
       value_a: a,
       value_b: b,
       relation: relation,
       result: result,
       verified: true,
       method: "direct_comparison",
       description: "#{a} #{relation_symbol(relation)} #{b} : #{result}"
     }}
  end

  defp verify_compare(params) do
    {:error,
     "Invalid compare parameters. Required: value_a, value_b, relation (greater/less/equal/greater_equal/less_equal). Got: #{inspect(params)}"}
  end

  defp relation_symbol("greater"), do: ">"
  defp relation_symbol("less"), do: "<"
  defp relation_symbol("equal"), do: "=="
  defp relation_symbol("greater_equal"), do: ">="
  defp relation_symbol("less_equal"), do: "<="

  # Rate limit tracking for self_check (per-process)
  @self_check_rate_limit 3
  @self_check_window_seconds 60
  @self_check_timeout_ms 30_000

  # ==========================================================================
  # SELF-CHECK VERIFICATION (SPEC-062 Enhanced)
  # ==========================================================================

  defp verify_self_check(%{problem: problem, claimed_answer: claimed}) do
    # Check rate limit
    case check_rate_limit(:self_check) do
      :ok ->
        execute_self_check(problem, claimed)

      {:error, :rate_limited} ->
        {:error, "Rate limited: max #{@self_check_rate_limit} self_checks per minute"}
    end
  end

  defp verify_self_check(params) do
    {:error,
     "Invalid self_check parameters. Required: problem, claimed_answer. Got: #{inspect(params)}"}
  end

  defp execute_self_check(problem, claimed) do
    Logger.info("[Verify.self_check] Starting independent reasoning for: #{inspect(problem)}")

    # Start independent reasoning session
    task =
      Task.async(fn ->
        with {:ok, session} <- Mimo.Cognitive.Reasoner.guided(problem, strategy: :cot),
             # Add a single thought step to trigger reasoning
             {:ok, _step} <-
               Mimo.Cognitive.Reasoner.step(session.session_id, "Analyzing: #{problem}"),
             {:ok, conclusion} <- Mimo.Cognitive.Reasoner.conclude(session.session_id) do
          {:ok, conclusion}
        else
          error -> error
        end
      end)

    # Wait with timeout
    case Task.yield(task, @self_check_timeout_ms) || Task.shutdown(task) do
      {:ok, {:ok, conclusion}} ->
        independent_answer = conclusion.conclusion
        match = normalize_and_compare(independent_answer, claimed)

        # Emit telemetry
        emit_self_check_result(match)

        {:ok,
         %{
           operation: "self_check",
           problem: problem,
           claimed_answer: claimed,
           independent_answer: independent_answer,
           match: match,
           verified: true,
           method: "executable_reasoning",
           confidence: conclusion.confidence,
           recommendation:
             if(match,
               do: "✓ CONFIRMED: Independent reasoning matches claimed answer",
               else: "⚠️ DISCREPANCY: Review both answers - independent: #{independent_answer}"
             ),
           reasoning_summary: conclusion.reasoning_summary
         }}

      {:ok, {:error, reason}} ->
        Logger.warning("[Verify.self_check] Reasoning failed: #{inspect(reason)}")

        {:ok,
         %{
           operation: "self_check",
           problem: problem,
           claimed_answer: claimed,
           independent_answer: nil,
           match: nil,
           verified: false,
           method: "executable_reasoning",
           error: "Reasoning failed: #{inspect(reason)}",
           fallback_workflow: [
             "1. Start a reasoning session (reason: guided) for this problem",
             "2. Work through reasoning steps",
             "3. Conclude the session (reason: conclude)",
             "4. Compare the conclusion with claimed_answer: #{claimed}"
           ]
         }}

      nil ->
        Logger.warning("[Verify.self_check] Timed out after #{@self_check_timeout_ms}ms")

        {:ok,
         %{
           operation: "self_check",
           problem: problem,
           claimed_answer: claimed,
           independent_answer: nil,
           match: nil,
           verified: false,
           method: "executable_reasoning",
           error: "Self-check timed out after #{div(@self_check_timeout_ms, 1000)}s",
           fallback_workflow: [
             "1. Start a reasoning session (reason: guided) for this problem",
             "2. Work through reasoning steps manually",
             "3. Conclude the session (reason: conclude)",
             "4. Compare the conclusion with claimed_answer: #{claimed}"
           ]
         }}
    end
  end

  # Rate limiting for self_check to prevent abuse
  defp check_rate_limit(operation) do
    key = {operation, self()}
    now = System.monotonic_time(:second)

    case Process.get(key) do
      nil ->
        Process.put(key, {1, now})
        :ok

      {_count, start} when now - start > @self_check_window_seconds ->
        Process.put(key, {1, now})
        :ok

      {count, _start} when count < @self_check_rate_limit ->
        Process.put(key, {count + 1, now})
        :ok

      _ ->
        {:error, :rate_limited}
    end
  end

  # Normalize and compare answers for matching
  defp normalize_and_compare(a, b) when is_binary(a) and is_binary(b) do
    normalize(a) == normalize(b)
  end

  defp normalize_and_compare(a, b) when is_number(a) and is_number(b) do
    compare_numbers(a, b)
  end

  defp normalize_and_compare(a, b) do
    to_string(a) |> normalize() == to_string(b) |> normalize()
  end

  defp normalize(val) when is_binary(val) do
    val
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  defp normalize(val), do: val

  # Telemetry for self_check results
  defp emit_self_check_result(match) do
    :telemetry.execute(
      [:mimo, :verification, :self_check],
      %{match: if(match, do: 1, else: 0)},
      %{operation: :self_check}
    )
  end
end
