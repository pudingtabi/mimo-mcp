defmodule Mimo.Cognitive.OutcomeDetectorTest do
  use ExUnit.Case, async: true

  alias Mimo.Cognitive.OutcomeDetector

  describe "detect_terminal/2" do
    test "detects success from exit code 0" do
      result = OutcomeDetector.detect_terminal(0, "command completed")

      assert result.outcome == :success
      assert result.confidence >= 0.5
      assert result.signal_type == :terminal
    end

    test "detects failure from exit code 1" do
      result = OutcomeDetector.detect_terminal(1, "command failed")

      assert result.outcome == :failure
      assert result.confidence >= 0.6
      assert result.signal_type == :terminal
    end

    test "detects test success pattern" do
      output = """
      Running tests...
      10 tests, 0 failures
      Finished in 1.5 seconds
      """

      result = OutcomeDetector.detect_terminal(0, output)

      assert result.outcome == :success
      assert result.confidence >= 0.5
      assert result.details.test_results[:total] == 10
      assert result.details.test_results[:failures] == 0
    end

    test "detects test failure pattern" do
      output = """
      Running tests...
      10 tests, 3 failures
      """

      result = OutcomeDetector.detect_terminal(1, output)

      assert result.outcome == :failure
      assert result.confidence >= 0.7
      assert result.details.test_results[:failures] == 3
    end

    test "detects compilation error pattern" do
      output = """
      ** (CompileError) lib/foo.ex:10: undefined function bar/1
      """

      result = OutcomeDetector.detect_terminal(1, output)

      assert result.outcome == :failure
      assert result.confidence >= 0.7
      assert result.details.error_count >= 1
    end

    test "detects build success pattern" do
      output = """
      Compiling 15 files (.ex)
      Generated mimo app
      build successful
      """

      result = OutcomeDetector.detect_terminal(0, output)

      assert result.outcome == :success
      assert result.confidence >= 0.6
    end
  end

  describe "detect_compile/1" do
    test "detects clean compilation with success pattern" do
      output = "Compiling 5 files (.ex)\nGenerated mimo app\nbuild successful"

      result = OutcomeDetector.detect_compile(output)

      assert result.outcome == :success
      assert result.signal_type == :compile
    end

    test "detects compilation with errors" do
      output = """
      ** (CompileError) lib/foo.ex:10: undefined function bar/1
      2 errors
      """

      result = OutcomeDetector.detect_compile(output)

      assert result.outcome == :failure
      assert result.details.error_count >= 1
    end

    test "detects compilation with warnings" do
      output = """
      Compiling 5 files (.ex)
      warning: unused variable
      Generated mimo app
      3 warnings
      """

      result = OutcomeDetector.detect_compile(output)

      assert result.outcome == :partial
      assert result.details.warning_count >= 1
    end
  end

  describe "detect_user_feedback/1" do
    test "detects positive feedback" do
      result = OutcomeDetector.detect_user_feedback("Thanks, that worked!")

      assert result.outcome == :success
      assert result.signal_type == :user
      assert result.details.positive_signals >= 1
    end

    test "detects negative feedback" do
      result = OutcomeDetector.detect_user_feedback("That's wrong, try again")

      assert result.outcome == :failure
      assert result.signal_type == :user
      assert result.details.negative_signals >= 1
    end

    test "handles neutral message" do
      result = OutcomeDetector.detect_user_feedback("What about the other file?")

      assert result.outcome == :unknown
      assert result.confidence <= 0.5
    end
  end

  describe "detect_file_operation/2" do
    test "detects successful write" do
      result = OutcomeDetector.detect_file_operation(:write, %{success: true})

      assert result.outcome == :success
      assert result.signal_type == :file
    end

    test "detects failed write" do
      result = OutcomeDetector.detect_file_operation(:write, %{error: "permission denied"})

      assert result.outcome == :failure
      assert result.signal_type == :file
    end

    test "detects successful read" do
      result = OutcomeDetector.detect_file_operation(:read, %{content: "file content"})

      assert result.outcome == :success
      assert result.signal_type == :file
    end
  end

  describe "aggregate_outcomes/1" do
    test "aggregates multiple success outcomes" do
      outcomes = [
        %{
          outcome: :success,
          confidence: 0.9,
          signal_type: :terminal,
          signals: ["test passed"],
          details: %{}
        },
        %{
          outcome: :success,
          confidence: 0.8,
          signal_type: :file,
          signals: ["file written"],
          details: %{}
        }
      ]

      result = OutcomeDetector.aggregate_outcomes(outcomes)

      assert result.outcome == :success
      assert result.signal_type == :aggregated
      assert length(result.signals) == 2
    end

    test "failure dominates mixed outcomes" do
      outcomes = [
        %{outcome: :success, confidence: 0.9, signal_type: :terminal, signals: [], details: %{}},
        %{
          outcome: :failure,
          confidence: 0.95,
          signal_type: :compile,
          signals: ["error"],
          details: %{}
        }
      ]

      result = OutcomeDetector.aggregate_outcomes(outcomes)

      # Weighted average should pull toward failure
      assert result.outcome in [:partial, :failure]
    end

    test "handles empty list" do
      result = OutcomeDetector.aggregate_outcomes([])

      assert result.outcome == :unknown
      assert result.confidence == 0.0
    end
  end
end
