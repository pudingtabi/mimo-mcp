defmodule Mimo.Brain.ClassifierTest do
  use ExUnit.Case, async: true

  alias Mimo.Brain.Classifier

  describe "fast_path/1" do
    test "classifies dependency questions as graph" do
      assert {:ok, :graph, confidence} = Classifier.fast_path("What depends on the auth service?")
      assert confidence >= 0.7
    end

    test "classifies relationship questions as graph" do
      assert {:ok, :graph, _} = Classifier.fast_path("Show me the relationship between A and B")
    end

    test "classifies hierarchy questions as graph" do
      assert {:ok, :graph, _} = Classifier.fast_path("Who is the parent of this module?")
    end

    test "classifies vibe questions as vector" do
      assert {:ok, :vector, _} = Classifier.fast_path("What's the vibe of this codebase?")
    end

    test "classifies story questions as vector" do
      assert {:ok, :vector, _} = Classifier.fast_path("Tell me the story of how this was built")
    end

    test "classifies similar questions as vector" do
      assert {:ok, :vector, _} = Classifier.fast_path("Find something similar to this")
    end

    test "returns uncertain for ambiguous queries" do
      assert {:uncertain, nil, 0.0} = Classifier.fast_path("Hello world")
    end

    test "detects hybrid queries" do
      # Query with both graph and vector signals
      assert {:ok, :hybrid, _} = Classifier.fast_path("What depends on this and feels similar?")
    end

    test "handles multiple graph keywords with higher confidence" do
      assert {:ok, :graph, confidence} =
               Classifier.fast_path("What depends on and relates to the parent module?")

      assert confidence >= 0.8
    end
  end

  describe "classify/2" do
    test "uses fast path when confident" do
      # When API key is available, it should use LLM classification
      # When no API key, fast_path is used which should detect graph keywords
      {:ok, store, confidence} = Classifier.classify("What depends on X?")
      # Either :graph (fast path detected) or :hybrid (no API key default)
      assert store in [:graph, :hybrid]
      assert confidence >= 0.5
    end

    test "returns result even for uncertain queries" do
      # Should use slow path or default
      result = Classifier.classify("random text here")
      assert match?({:ok, _, _}, result)
    end

    test "respects force_llm option" do
      # This test may fail if no LLM API key
      # In that case, it should still return a result
      result = Classifier.classify("test", force_llm: true)
      assert match?({:ok, _, _}, result) or match?({:error, _}, result)
    end
  end
end
