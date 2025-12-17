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
