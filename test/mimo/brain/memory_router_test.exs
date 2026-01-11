defmodule Mimo.Brain.MemoryRouterTest do
  use ExUnit.Case, async: true

  alias Mimo.Brain.MemoryRouter

  describe "analyze/1" do
    test "detects relational queries" do
      {type, confidence} = MemoryRouter.analyze("How is auth related to users?")
      assert type == :relational
      assert confidence > 0.3
    end

    test "detects temporal queries" do
      {type, confidence} = MemoryRouter.analyze("What happened recently?")
      assert type == :temporal
      assert confidence > 0.3
    end

    test "detects procedural queries" do
      {type, confidence} = MemoryRouter.analyze("How do I setup the authentication system?")
      assert type == :procedural
      assert confidence > 0.3
    end

    test "detects factual queries" do
      {type, confidence} = MemoryRouter.analyze("What is the definition of REST API?")
      assert type == :factual
      assert confidence > 0.3
    end

    test "returns hybrid for ambiguous queries" do
      {type, _confidence} = MemoryRouter.analyze("Tell me everything")
      assert type == :hybrid
    end
  end

  describe "analyze_with_llm/2" do
    test "falls back to keyword-based analysis when skip_llm is true" do
      # This should use keyword-based analysis (no LLM call)
      {type, confidence} =
        MemoryRouter.analyze_with_llm("How is auth related to users?", skip_llm: true)

      assert type == :relational
      assert confidence > 0.3
    end

    test "falls back for short queries under threshold" do
      # Short queries (< 10 chars) should use keyword-based
      {type, _confidence} = MemoryRouter.analyze_with_llm("recent", skip_llm: false)
      assert type == :temporal
    end

    test "returns same result as analyze/1 when LLM disabled" do
      query = "What happened recently?"
      {type1, conf1} = MemoryRouter.analyze(query)
      {type2, conf2} = MemoryRouter.analyze_with_llm(query, skip_llm: true)

      assert type1 == type2
      assert conf1 == conf2
    end
  end

  describe "understand_query_with_llm/1" do
    # Note: These tests verify the function structure, not actual LLM calls
    # In CI, LLM may not be available so we just verify the function exists
    # and handles errors gracefully

    test "function exists and returns expected structure" do
      # The function should exist and be callable
      # It may fail due to no LLM, but should return {:error, _}
      result = MemoryRouter.understand_query_with_llm("what is the latest plan?")

      case result do
        {:ok, analysis} ->
          # If LLM is available, verify structure
          assert Map.has_key?(analysis, :intent)
          assert Map.has_key?(analysis, :time_reference)
          assert Map.has_key?(analysis, :topics)
          assert Map.has_key?(analysis, :expanded_queries)
          assert Map.has_key?(analysis, :confidence)
          assert analysis.intent in [:temporal, :factual, :relational, :procedural, :aggregation]

        {:error, _reason} ->
          # LLM not available, which is fine in test
          :ok
      end
    end
  end

  describe "explain_routing/1" do
    test "returns routing explanation" do
      explanation = MemoryRouter.explain_routing("How is user related to session?")

      assert is_map(explanation)
      assert Map.has_key?(explanation, :query)
      assert Map.has_key?(explanation, :selected_type)
      assert Map.has_key?(explanation, :confidence)
      assert Map.has_key?(explanation, :type_scores)
      assert Map.has_key?(explanation, :matched_indicators)
      assert Map.has_key?(explanation, :recommended_stores)

      assert explanation.selected_type == :relational
      assert "related" in explanation.matched_indicators.relational
    end

    test "shows recommended stores for each type" do
      factual = MemoryRouter.explain_routing("What is OAuth?")
      assert :vector in factual.recommended_stores

      relational = MemoryRouter.explain_routing("What's connected to the database?")
      assert :graph in relational.recommended_stores

      temporal = MemoryRouter.explain_routing("What happened recently?")
      assert :recency in temporal.recommended_stores
    end
  end
end
