defmodule Mimo.Cognitive.OutcomeDetector do
  @moduledoc """
  SPEC-087: Outcome Detection for Feedback Loop Closure

  Detects success/failure signals from tool outputs to enable learning.
  This is the critical missing piece that closes the feedback loop:

    Tool Execution → OutcomeDetector → FeedbackLoop → Learning Systems

  ## Signal Types

  - Terminal: exit codes, error patterns, test results
  - Compile: error/warning counts, success messages
  - User: explicit thanks, corrections, acceptance signals
  - File: successful writes, valid syntax

  ## Integration

  Called by tool dispatchers after execution to classify outcomes.
  Feeds into FeedbackLoop.record_outcome for downstream learning.
  """

  require Logger

  @type outcome :: :success | :partial | :failure | :unknown
  @type signal_type :: :terminal | :compile | :test | :user | :file | :unknown

  @type detection_result :: %{
          outcome: outcome(),
          confidence: float(),
          signal_type: signal_type(),
          signals: [String.t()],
          details: map()
        }

  # ============================================================================
  # Terminal Output Patterns
  # ============================================================================

  @success_patterns [
    # Test success
    ~r/(\d+) (tests?|specs?|examples?),? (\d+|no) failures?/i,
    ~r/all (\d+) tests? passed/i,
    ~r/tests?: \d+, passed: \d+, failed: 0/i,
    ~r/✓|✔|PASSED|SUCCESS/,
    # Build success
    ~r/build successful/i,
    ~r/compiled \d+ files?/i,
    ~r/compilation successful/i,
    # General success
    ~r/done\.?$/i,
    ~r/completed successfully/i,
    ~r/finished in \d+/i
  ]

  @failure_patterns [
    # Test failures
    ~r/(\d+) failures?/i,
    ~r/(\d+) errors?/i,
    ~r/FAILED|FAILURE|ERROR/,
    ~r/✗|✘|×/,
    # Compile errors
    ~r/\*\* \(.*Error\)/,
    ~r/error:/i,
    ~r/cannot compile/i,
    ~r/undefined function/i,
    ~r/undefined module/i,
    # Runtime errors
    ~r/exception|traceback|panic/i,
    ~r/segmentation fault/i,
    ~r/killed|terminated/i,
    # Command errors
    ~r/command not found/i,
    ~r/permission denied/i,
    ~r/no such file/i
  ]

  @warning_patterns [
    ~r/warning:/i,
    ~r/deprecated/i,
    ~r/\d+ warnings?/i
  ]

  # ============================================================================
  # User Feedback Patterns
  # ============================================================================

  @positive_user_patterns [
    ~r/\b(thanks|thank you|thx|ty)\b/i,
    ~r/\b(perfect|great|awesome|excellent|nice|good job)\b/i,
    ~r/\b(that works|worked|it works|working now)\b/i,
    ~r/\b(exactly what i needed|that's it|that's right)\b/i,
    ~r/\b(lgtm|looks good)\b/i,
    ~r/^(yes|yep|yeah|correct|right)$/i
  ]

  @negative_user_patterns [
    ~r/\b(wrong|incorrect|no that's not)\b/i,
    ~r/\b(doesn't work|didn't work|not working)\b/i,
    ~r/\b(actually|but|however).*(should|need|want)/i,
    ~r/\b(try again|redo|fix)\b/i,
    ~r/^(no|nope)$/i
  ]

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Detect outcome from terminal command output.

  Takes exit code and output string, returns detection result.
  """
  @spec detect_terminal(integer(), String.t()) :: detection_result()
  def detect_terminal(exit_code, output) do
    output_str = to_string(output)

    # Start with exit code
    base_outcome = if exit_code == 0, do: :success, else: :failure
    base_confidence = if exit_code == 0, do: 0.7, else: 0.8

    # Analyze output patterns
    {pattern_outcome, pattern_confidence, signals} = analyze_output_patterns(output_str)

    # Combine signals
    {final_outcome, final_confidence} =
      combine_signals(base_outcome, base_confidence, pattern_outcome, pattern_confidence)

    # Extract test counts if present
    test_details = extract_test_counts(output_str)
    error_count = count_pattern_matches(output_str, @failure_patterns)
    warning_count = count_pattern_matches(output_str, @warning_patterns)

    %{
      outcome: final_outcome,
      confidence: Float.round(final_confidence, 3),
      signal_type: :terminal,
      signals: signals,
      details: %{
        exit_code: exit_code,
        error_count: error_count,
        warning_count: warning_count,
        test_results: test_details,
        output_length: String.length(output_str)
      }
    }
  end

  @doc """
  Detect outcome from compile/build output.
  """
  @spec detect_compile(String.t()) :: detection_result()
  def detect_compile(output) do
    output_str = to_string(output)

    error_count = count_errors(output_str)
    warning_count = count_warnings(output_str)

    {outcome, confidence} =
      cond do
        error_count > 0 -> {:failure, 0.95}
        warning_count > 5 -> {:partial, 0.7}
        warning_count > 0 -> {:partial, 0.8}
        has_success_pattern?(output_str) -> {:success, 0.9}
        true -> {:unknown, 0.5}
      end

    signals =
      []
      |> add_signal(error_count > 0, "#{error_count} errors detected")
      |> add_signal(warning_count > 0, "#{warning_count} warnings detected")
      |> add_signal(outcome == :success, "compilation successful")

    %{
      outcome: outcome,
      confidence: Float.round(confidence, 3),
      signal_type: :compile,
      signals: signals,
      details: %{
        error_count: error_count,
        warning_count: warning_count
      }
    }
  end

  @doc """
  Detect outcome from test runner output.
  """
  @spec detect_tests(String.t()) :: detection_result()
  def detect_tests(output) do
    output_str = to_string(output)
    test_counts = extract_test_counts(output_str)

    {outcome, confidence} =
      cond do
        test_counts[:failures] > 0 -> {:failure, 0.95}
        test_counts[:errors] > 0 -> {:failure, 0.95}
        test_counts[:passed] > 0 and test_counts[:failures] == 0 -> {:success, 0.95}
        has_success_pattern?(output_str) -> {:success, 0.8}
        has_failure_pattern?(output_str) -> {:failure, 0.8}
        true -> {:unknown, 0.5}
      end

    signals =
      if test_counts[:total] > 0 do
        ["#{test_counts[:passed]}/#{test_counts[:total]} tests passed"]
      else
        []
      end

    %{
      outcome: outcome,
      confidence: Float.round(confidence, 3),
      signal_type: :test,
      signals: signals,
      details: test_counts
    }
  end

  @doc """
  Detect outcome from user message (feedback signal).
  """
  @spec detect_user_feedback(String.t()) :: detection_result()
  def detect_user_feedback(message) do
    message_str = to_string(message)

    positive_matches = count_pattern_matches(message_str, @positive_user_patterns)
    negative_matches = count_pattern_matches(message_str, @negative_user_patterns)

    {outcome, confidence, signals} =
      cond do
        negative_matches > positive_matches ->
          {:failure, min(0.9, 0.5 + negative_matches * 0.1), ["user expressed dissatisfaction"]}

        positive_matches > 0 and negative_matches == 0 ->
          {:success, min(0.9, 0.5 + positive_matches * 0.1), ["user expressed satisfaction"]}

        positive_matches > negative_matches ->
          {:partial, 0.6, ["mixed user feedback"]}

        true ->
          {:unknown, 0.3, []}
      end

    %{
      outcome: outcome,
      confidence: Float.round(confidence, 3),
      signal_type: :user,
      signals: signals,
      details: %{
        positive_signals: positive_matches,
        negative_signals: negative_matches
      }
    }
  end

  @doc """
  Detect outcome from file operation.
  """
  @spec detect_file_operation(atom(), map()) :: detection_result()
  def detect_file_operation(operation, result) do
    case {operation, result} do
      {:write, %{success: true}} ->
        %{
          outcome: :success,
          confidence: 0.9,
          signal_type: :file,
          signals: ["file written successfully"],
          details: %{operation: :write}
        }

      {:write, %{error: _}} ->
        %{
          outcome: :failure,
          confidence: 0.95,
          signal_type: :file,
          signals: ["file write failed"],
          details: %{operation: :write}
        }

      {:read, %{content: content}} when is_binary(content) ->
        %{
          outcome: :success,
          confidence: 0.9,
          signal_type: :file,
          signals: ["file read successfully"],
          details: %{operation: :read, size: byte_size(content)}
        }

      _ ->
        %{
          outcome: :unknown,
          confidence: 0.5,
          signal_type: :file,
          signals: [],
          details: %{operation: operation}
        }
    end
  end

  @doc """
  Aggregate multiple detection results into overall session outcome.
  """
  @spec aggregate_outcomes([detection_result()]) :: detection_result()
  def aggregate_outcomes([]),
    do: %{outcome: :unknown, confidence: 0.0, signal_type: :unknown, signals: [], details: %{}}

  def aggregate_outcomes(results) do
    # Weight by confidence
    weighted_scores =
      Enum.map(results, fn r ->
        score =
          case r.outcome do
            :success -> 1.0
            :partial -> 0.5
            :failure -> 0.0
            :unknown -> 0.5
          end

        {score * r.confidence, r.confidence}
      end)

    total_weight = Enum.sum(Enum.map(weighted_scores, fn {_, w} -> w end))
    weighted_sum = Enum.sum(Enum.map(weighted_scores, fn {s, _} -> s end))

    avg_score = if total_weight > 0, do: weighted_sum / total_weight, else: 0.5

    final_outcome =
      cond do
        avg_score >= 0.7 -> :success
        avg_score >= 0.4 -> :partial
        avg_score < 0.4 -> :failure
        true -> :unknown
      end

    all_signals = Enum.flat_map(results, & &1.signals) |> Enum.uniq()

    %{
      outcome: final_outcome,
      confidence: Float.round(avg_score, 3),
      signal_type: :aggregated,
      signals: all_signals,
      details: %{
        result_count: length(results),
        outcomes: Enum.map(results, & &1.outcome)
      }
    }
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp analyze_output_patterns(output) do
    success_count = count_pattern_matches(output, @success_patterns)
    failure_count = count_pattern_matches(output, @failure_patterns)

    signals = []

    {outcome, confidence, signals} =
      cond do
        failure_count > 0 ->
          {:failure, min(0.95, 0.6 + failure_count * 0.1),
           ["#{failure_count} failure patterns detected" | signals]}

        success_count > 0 ->
          {:success, min(0.9, 0.5 + success_count * 0.1),
           ["#{success_count} success patterns detected" | signals]}

        true ->
          {:unknown, 0.5, signals}
      end

    {outcome, confidence, signals}
  end

  defp combine_signals(base_outcome, base_confidence, pattern_outcome, pattern_confidence) do
    # If both agree, high confidence
    # If they disagree, pattern analysis usually wins for content
    cond do
      base_outcome == pattern_outcome ->
        {base_outcome, max(base_confidence, pattern_confidence)}

      pattern_confidence > base_confidence ->
        {pattern_outcome, pattern_confidence * 0.9}

      true ->
        {base_outcome, base_confidence * 0.8}
    end
  end

  defp extract_test_counts(output) do
    # Try various test output formats
    counts = %{passed: 0, failures: 0, errors: 0, skipped: 0, total: 0}

    # Elixir/ExUnit format: "10 tests, 0 failures"
    counts =
      case Regex.run(~r/(\d+) tests?,\s*(\d+) failures?/i, output) do
        [_, total, failures] ->
          t = String.to_integer(total)
          f = String.to_integer(failures)
          %{counts | total: t, failures: f, passed: t - f}

        _ ->
          counts
      end

    # Check for errors separately
    counts =
      case Regex.run(~r/(\d+) errors?/i, output) do
        [_, errors] -> %{counts | errors: String.to_integer(errors)}
        _ -> counts
      end

    counts
  end

  defp count_errors(output) do
    # Count actual error lines
    error_line_count =
      output
      |> String.split("\n")
      |> Enum.count(&String.match?(&1, ~r/^\s*\*\*\s*\(|^error:/i))

    # Also check for error count in summary
    summary_count =
      case Regex.run(~r/(\d+) errors?/i, output) do
        [_, n] -> String.to_integer(n)
        _ -> 0
      end

    max(error_line_count, summary_count)
  end

  defp count_warnings(output) do
    case Regex.run(~r/(\d+) warnings?/i, output) do
      [_, n] -> String.to_integer(n)
      _ -> count_pattern_matches(output, @warning_patterns)
    end
  end

  defp count_pattern_matches(text, patterns) do
    Enum.count(patterns, &Regex.match?(&1, text))
  end

  defp has_success_pattern?(text) do
    Enum.any?(@success_patterns, &Regex.match?(&1, text))
  end

  defp has_failure_pattern?(text) do
    Enum.any?(@failure_patterns, &Regex.match?(&1, text))
  end

  defp add_signal(signals, true, message), do: [message | signals]
  defp add_signal(signals, false, _message), do: signals
end
