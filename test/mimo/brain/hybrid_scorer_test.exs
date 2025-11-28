defmodule Mimo.Brain.HybridScorerTest do
  use ExUnit.Case, async: true

  alias Mimo.Brain.HybridScorer

  describe "score/3" do
    test "returns score between 0 and 1" do
      memory = %{
        importance: 0.5,
        access_count: 5,
        last_accessed_at: NaiveDateTime.utc_now(),
        embedding: Enum.map(1..10, fn _ -> :rand.uniform() end)
      }

      query_embedding = Enum.map(1..10, fn _ -> :rand.uniform() end)

      score = HybridScorer.score(memory, query_embedding)
      assert score >= 0.0
      assert score <= 1.0
    end

    test "works without query embedding" do
      memory = %{
        importance: 0.8,
        access_count: 10,
        last_accessed_at: NaiveDateTime.utc_now()
      }

      score = HybridScorer.score(memory, nil)
      assert score >= 0.0
      assert score <= 1.0
    end

    test "custom weights affect scoring" do
      memory = %{
        importance: 0.9,
        access_count: 0,
        last_accessed_at: NaiveDateTime.utc_now()
      }

      default_score = HybridScorer.score(memory, nil)

      # Heavy importance weight should increase score for high importance memory
      importance_heavy_score = HybridScorer.score(memory, nil, weights: %{importance: 0.8})

      assert importance_heavy_score > default_score
    end

    test "graph_score option affects result" do
      memory = %{
        importance: 0.5,
        access_count: 0,
        last_accessed_at: NaiveDateTime.utc_now()
      }

      no_graph = HybridScorer.score(memory, nil, graph_score: 0.0)
      with_graph = HybridScorer.score(memory, nil, graph_score: 1.0)

      assert with_graph > no_graph
    end
  end

  describe "rank/3" do
    test "returns memories sorted by score descending" do
      memories = [
        %{id: 1, importance: 0.2, access_count: 0, last_accessed_at: NaiveDateTime.utc_now()},
        %{id: 2, importance: 0.9, access_count: 10, last_accessed_at: NaiveDateTime.utc_now()},
        %{id: 3, importance: 0.5, access_count: 5, last_accessed_at: NaiveDateTime.utc_now()}
      ]

      ranked = HybridScorer.rank(memories, nil)

      assert length(ranked) == 3
      [{first, _}, {second, _}, {third, _}] = ranked
      assert first.id == 2
      assert third.id == 1
    end
  end

  describe "explain/3" do
    test "returns breakdown of score components" do
      memory = %{
        importance: 0.7,
        access_count: 5,
        last_accessed_at: NaiveDateTime.utc_now(),
        embedding: Enum.map(1..10, fn _ -> :rand.uniform() end)
      }

      query_embedding = Enum.map(1..10, fn _ -> :rand.uniform() end)

      explanation = HybridScorer.explain(memory, query_embedding)

      assert is_map(explanation.components)
      assert Map.has_key?(explanation.components, :vector)
      assert Map.has_key?(explanation.components, :recency)
      assert Map.has_key?(explanation.components, :access)
      assert Map.has_key?(explanation.components, :importance)
      assert Map.has_key?(explanation.components, :graph)

      assert is_float(explanation.total_score)
      assert is_map(explanation.weights)
    end
  end
end
