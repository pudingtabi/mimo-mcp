defmodule Mimo.Brain.ReflectorTest do
  use ExUnit.Case, async: true

  alias Mimo.Brain.Reflector

  alias Mimo.Brain.Reflector.{
    ConfidenceEstimator,
    ConfidenceOutput,
    Config,
    ErrorDetector,
    Evaluator
  }

  describe "Evaluator" do
    test "evaluates output with all dimensions" do
      output =
        "Phoenix is a web framework for Elixir that uses the MVC pattern. It provides real-time features through channels."

      context = %{
        query: "What is Phoenix?",
        memories: [
          %{content: "Phoenix is an Elixir web framework", similarity: 0.85, importance: 0.7}
        ]
      }

      evaluation = Evaluator.evaluate(output, context)

      assert is_map(evaluation)
      assert Map.has_key?(evaluation, :scores)
      assert Map.has_key?(evaluation, :aggregate_score)
      assert Map.has_key?(evaluation, :issues)
      assert Map.has_key?(evaluation, :suggestions)
      assert Map.has_key?(evaluation, :quality_level)

      # Scores should be in valid range
      assert evaluation.aggregate_score >= 0.0
      assert evaluation.aggregate_score <= 1.0

      # Quality level should be valid
      assert evaluation.quality_level in [:excellent, :good, :acceptable, :poor]
    end

    test "quick_evaluate returns pass/fail" do
      output = "This is a clear and well-structured response."
      context = %{memories: []}

      result = Evaluator.quick_evaluate(output, context)

      assert Map.has_key?(result, :score)
      assert Map.has_key?(result, :pass)
      assert is_boolean(result.pass)
    end

    test "detects clarity issues in poorly structured output" do
      # Very short, unclear output
      output = "ok"
      context = %{query: "Explain the architecture"}

      evaluation = Evaluator.evaluate(output, context)

      # Should have low clarity and completeness
      assert evaluation.scores.clarity < 0.5
      assert evaluation.scores.completeness < 0.5
    end

    test "rewards well-grounded output" do
      output = "Phoenix uses Plug for HTTP handling and Ecto for database access."

      context = %{
        query: "How does Phoenix work?",
        memories: [
          %{content: "Phoenix uses Plug middleware", similarity: 0.9},
          %{content: "Ecto is the database layer for Phoenix", similarity: 0.85}
        ]
      }

      evaluation = Evaluator.evaluate(output, context)

      # Should have good grounding
      assert evaluation.scores.grounding >= 0.5
    end
  end

  describe "ConfidenceEstimator" do
    test "estimates confidence with all signals" do
      output = "The function handles authentication using JWT tokens."

      context = %{
        query: "How does auth work?",
        memories: [
          %{content: "JWT authentication implemented", similarity: 0.8, importance: 0.7}
        ]
      }

      result = ConfidenceEstimator.estimate(output, context)

      assert Map.has_key?(result, :score)
      assert Map.has_key?(result, :level)
      assert Map.has_key?(result, :signals)
      assert Map.has_key?(result, :explanation)

      assert result.score >= 0.0
      assert result.score <= 1.0
      assert result.level in [:very_high, :high, :medium, :low, :very_low]
    end

    test "quick_estimate returns level only" do
      result = ConfidenceEstimator.quick_estimate("output", %{memories: []})
      assert result in [:very_high, :high, :medium, :low, :very_low]
    end

    test "categorize maps scores to levels" do
      assert ConfidenceEstimator.categorize(0.95) == :very_high
      assert ConfidenceEstimator.categorize(0.80) == :high
      assert ConfidenceEstimator.categorize(0.60) == :medium
      assert ConfidenceEstimator.categorize(0.35) == :low
      assert ConfidenceEstimator.categorize(0.15) == :very_low
    end

    test "language_qualifier provides appropriate hedging" do
      assert is_nil(ConfidenceEstimator.language_qualifier(:very_high))
      assert is_binary(ConfidenceEstimator.language_qualifier(:high))
      assert is_binary(ConfidenceEstimator.language_qualifier(:medium))
      assert is_binary(ConfidenceEstimator.language_qualifier(:low))
      assert is_binary(ConfidenceEstimator.language_qualifier(:very_low))
    end

    test "more memories increase confidence" do
      output = "Test output"

      result_few =
        ConfidenceEstimator.estimate(output, %{
          memories: [%{content: "mem1", similarity: 0.7}]
        })

      result_many =
        ConfidenceEstimator.estimate(output, %{
          memories: [
            %{content: "mem1", similarity: 0.7},
            %{content: "mem2", similarity: 0.8},
            %{content: "mem3", similarity: 0.75},
            %{content: "mem4", similarity: 0.65},
            %{content: "mem5", similarity: 0.7}
          ]
        })

      assert result_many.score >= result_few.score
    end
  end

  describe "ErrorDetector" do
    test "detects potential errors" do
      output = "The system definitely always works 100% of the time guaranteed."

      context = %{
        query: "How reliable is the system?",
        memories: []
      }

      errors = ErrorDetector.detect(output, context)

      assert is_list(errors)
      # Should detect overconfident language
      assert Enum.any?(errors, &(&1.type == :confidence_mismatch))
    end

    test "quick_detect only returns high severity" do
      output = "This is fine."
      context = %{}

      errors = ErrorDetector.quick_detect(output, context)

      assert is_list(errors)
      assert Enum.all?(errors, &(&1.severity == :high))
    end

    test "has_critical_errors? returns boolean" do
      output = "Normal response"
      context = %{}

      result = ErrorDetector.has_critical_errors?(output, context)
      assert is_boolean(result)
    end

    test "error_summary counts by severity" do
      errors = [
        %{severity: :high, type: :factual_contradiction},
        %{severity: :medium, type: :unsupported_claim},
        %{severity: :medium, type: :missing_element},
        %{severity: :low, type: :format_violation}
      ]

      summary = ErrorDetector.error_summary(errors)

      assert summary.high == 1
      assert summary.medium == 2
      assert summary.low == 1
      assert summary.total == 4
    end

    test "detects missing required elements" do
      output = "Here is some general information."

      context = %{
        query: "Explain the architecture, performance, and security aspects",
        required_elements: ["architecture", "performance", "security"]
      }

      errors = ErrorDetector.detect(output, context)

      assert Enum.any?(errors, &(&1.type == :missing_element))
    end
  end

  describe "ConfidenceOutput" do
    test "formats structured output" do
      confidence = %{
        score: 0.75,
        level: :high,
        signals: %{memory_grounding: 0.8, source_reliability: 0.7},
        calibrated: true,
        explanation: "Good confidence"
      }

      result = ConfidenceOutput.format("Test output", confidence, format: :structured)

      assert result.content == "Test output"
      assert result.confidence.level == :high
      assert result.confidence.score == 0.75
      assert is_binary(result.confidence.indicator)
      assert result.metadata.format == :structured
    end

    test "formats natural output with prefix" do
      confidence = %{
        score: 0.55,
        level: :medium,
        signals: %{},
        calibrated: true,
        explanation: "Moderate confidence"
      }

      result = ConfidenceOutput.format("The answer is 42.", confidence, format: :natural)

      # Should have prefix for medium confidence
      assert String.starts_with?(result.content, "I believe")
      assert result.metadata.format == :natural
      assert result.metadata.modified == true
    end

    test "formats hidden output without visible indicators" do
      confidence = %{
        score: 0.30,
        level: :low,
        signals: %{},
        calibrated: true,
        explanation: "Low confidence"
      }

      result = ConfidenceOutput.format("Test", confidence, format: :hidden)

      assert result.content == "Test"
      assert Map.has_key?(result.metadata, :full_confidence)
      refute Map.has_key?(result.confidence, :indicator)
    end

    test "confidence_indicator creates visual display" do
      assert ConfidenceOutput.confidence_indicator(1.0) == "●●●●●"
      assert ConfidenceOutput.confidence_indicator(0.6) == "●●●○○"
      assert ConfidenceOutput.confidence_indicator(0.2) == "●○○○○"
      assert ConfidenceOutput.confidence_indicator(0.0) == "○○○○○"

      assert ConfidenceOutput.confidence_indicator(:very_high) == "●●●●●"
      assert ConfidenceOutput.confidence_indicator(:low) == "●●○○○"
    end

    test "confidence_badge returns appropriate text" do
      assert ConfidenceOutput.confidence_badge(:very_high) =~ "Verified"
      assert ConfidenceOutput.confidence_badge(:high) =~ "Confident"
      assert ConfidenceOutput.confidence_badge(:low) =~ "Uncertain"
    end
  end

  describe "Reflector (main orchestrator)" do
    test "quick_reflect returns pass/fail with issues" do
      output = "A reasonable response to the question."
      context = %{query: "What is this?", memories: []}

      result = Reflector.quick_reflect(output, context)

      assert Map.has_key?(result, :score)
      assert Map.has_key?(result, :pass)
      assert Map.has_key?(result, :issues)
      assert is_boolean(result.pass)
      assert is_list(result.issues)
    end

    test "should_reflect? returns true for complex outputs" do
      # Long output
      long_output = String.duplicate("This is content. ", 200)
      assert Reflector.should_reflect?(long_output, %{})

      # Output with tool results
      assert Reflector.should_reflect?("Short", %{tool_results: ["result"]})

      # Code-heavy output
      code_output = """
      Here is the solution:
      ```elixir
      def foo do
        :bar
      end
      ```
      And some more explanation here.
      """

      assert Reflector.should_reflect?(code_output, %{})
    end

    test "should_reflect? returns false for simple outputs" do
      short_output = "Yes, that's correct."
      refute Reflector.should_reflect?(short_output, %{})
    end

    test "format_with_confidence returns formatted output" do
      output = "The answer is 42."
      context = %{query: "What is the answer?", memories: []}

      result = Reflector.format_with_confidence(output, context)

      assert Map.has_key?(result, :content)
      assert Map.has_key?(result, :confidence)
      assert is_binary(result.content)
    end
  end

  describe "Config" do
    test "get returns configuration" do
      config = Config.get()

      assert is_map(config)
      assert Map.has_key?(config, :enabled)
      assert Map.has_key?(config, :default_threshold)
      assert Map.has_key?(config, :max_iterations)
      assert Map.has_key?(config, :weights)
    end

    test "get with key returns specific value" do
      threshold = Config.get(:default_threshold)
      assert is_float(threshold)
      assert threshold >= 0.0
      assert threshold <= 1.0
    end

    test "enabled? returns boolean" do
      result = Config.enabled?()
      assert is_boolean(result)
    end

    test "should_auto_reflect? checks tool configuration" do
      # File tool should trigger reflection
      assert Config.should_auto_reflect?(:file)

      # Memory tool should not
      refute Config.should_auto_reflect?(:memory)
    end

    test "use_fast_mode? based on output length" do
      assert Config.use_fast_mode?(100)
      refute Config.use_fast_mode?(1000)
    end

    test "weights returns dimension weights" do
      weights = Config.weights()

      assert is_map(weights)
      assert Map.has_key?(weights, :correctness)
      assert Map.has_key?(weights, :completeness)
      assert Map.has_key?(weights, :confidence)
    end
  end
end
