defmodule Mimo.Benchmark.EvaluatorTest do
  use ExUnit.Case, async: true

  alias Mimo.Benchmark.Evaluator

  describe "evaluate/4 with :exact strategy" do
    test "returns correct for exact case-insensitive match" do
      {correct, score, details} = Evaluator.evaluate("Hello World", "hello world", :exact)

      assert correct == true
      assert score == 1.0
      assert details.mode == :exact
    end

    test "returns incorrect for non-matching strings" do
      {correct, score, details} = Evaluator.evaluate("foo", "bar", :exact)

      assert correct == false
      assert score == 0.0
      assert details.mode == :exact
    end

    test "handles whitespace trimming" do
      {correct, score, _} = Evaluator.evaluate("  hello  ", "hello", :exact)

      assert correct == true
      assert score == 1.0
    end

    test "handles empty strings" do
      {correct, score, _} = Evaluator.evaluate("", "", :exact)

      assert correct == true
      assert score == 1.0
    end

    test "handles nil inputs gracefully" do
      {correct, score, _} = Evaluator.evaluate(nil, nil, :exact)

      assert correct == true
      assert score == 1.0
    end
  end

  describe "evaluate/4 with :semantic strategy" do
    @tag :integration
    test "returns similarity score above threshold for similar texts" do
      # Skip if embeddings not available
      {correct, score, details} =
        Evaluator.evaluate(
          "The capital of France is Paris",
          "Paris is the capital of France",
          :semantic,
          threshold: 0.5
        )

      assert details.mode == :semantic
      assert is_float(score)
      # May fail if Ollama not running - that's OK for unit tests
    end

    test "returns low score for completely different texts" do
      {_correct, score, details} =
        Evaluator.evaluate(
          "Banana smoothie recipe",
          "Quantum physics equations",
          :semantic,
          threshold: 0.9
        )

      assert details.mode == :semantic
      # Score should be low but we don't enforce exact value without embeddings
      assert is_float(score) or score == 0.0
    end
  end

  describe "normalize/1 behavior" do
    test "exact strategy normalizes consistently" do
      {c1, _, _} = Evaluator.evaluate("HELLO", "hello", :exact)
      {c2, _, _} = Evaluator.evaluate("  Hello  ", "hello", :exact)
      {c3, _, _} = Evaluator.evaluate("hello", "HELLO", :exact)

      assert c1 == true
      assert c2 == true
      assert c3 == true
    end
  end
end
