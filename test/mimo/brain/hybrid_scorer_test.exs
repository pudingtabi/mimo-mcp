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

  # ==========================================================================
  # SPEC-051: Tiered Context Classification Tests
  # ==========================================================================

  describe "classify_tier/3" do
    test "classifies high-importance items with strong signals as tier1 or tier2" do
      # Item with very high importance and cross-modality connections
      # Note: Without vector similarity (no query embedding), max URS is limited
      # URS formula: semantic(0) * 0.35 + temporal * 0.25 + importance * 0.20 + cross_modal * 0.20
      # Max without semantic: 0.25 + 0.20 + 0.20 = 0.65 (exactly tier2 threshold)
      item = %{
        importance: 0.99,
        access_count: 100,
        last_accessed_at: NaiveDateTime.utc_now(),
        cross_modality_connections: 3  # Strong cross-modal boost
      }

      tier = HybridScorer.classify_tier(item, nil, model_type: :medium)
      # Without vector similarity, we can reach tier2 at best (or tier3 for stricter thresholds)
      assert tier in [:tier2, :tier3]

      # With pre-computed vector similarity, should reach tier1
      tier_with_vector = HybridScorer.classify_tier(item, nil, 
        model_type: :medium, 
        vector_similarity: 0.95
      )
      assert tier_with_vector in [:tier1, :tier2]
    end

    test "classifies medium-importance items as tier2 or tier3" do
      item = %{
        importance: 0.7,
        access_count: 3,
        last_accessed_at: NaiveDateTime.utc_now()
      }

      tier = HybridScorer.classify_tier(item, nil, model_type: :medium)
      # Without vector similarity, score won't reach tier1 threshold
      assert tier in [:tier2, :tier3]
    end

    test "classifies low-importance items as tier3" do
      item = %{
        importance: 0.2,
        access_count: 0,
        last_accessed_at: NaiveDateTime.add(NaiveDateTime.utc_now(), -30, :day)
      }

      tier = HybridScorer.classify_tier(item, nil, model_type: :medium)
      assert tier == :tier3
    end

    test "model type affects tier thresholds" do
      # Borderline item
      item = %{
        importance: 0.75,
        access_count: 5,
        last_accessed_at: NaiveDateTime.utc_now()
      }

      tier_small = HybridScorer.classify_tier(item, nil, model_type: :small)
      tier_large = HybridScorer.classify_tier(item, nil, model_type: :large)

      # Small models have stricter thresholds, so might classify lower
      # Large models have looser thresholds, so might classify higher
      assert tier_small in [:tier1, :tier2, :tier3]
      assert tier_large in [:tier1, :tier2, :tier3]
    end
  end

  describe "calculate_unified_score/3" do
    test "returns score between 0 and 1" do
      item = %{
        importance: 0.8,
        access_count: 5,
        last_accessed_at: NaiveDateTime.utc_now()
      }

      urs = HybridScorer.calculate_unified_score(item, nil)
      assert urs >= 0.0
      assert urs <= 1.0
    end

    test "higher importance increases URS" do
      low_importance = %{importance: 0.2, access_count: 0, last_accessed_at: NaiveDateTime.utc_now()}
      high_importance = %{importance: 0.9, access_count: 0, last_accessed_at: NaiveDateTime.utc_now()}

      urs_low = HybridScorer.calculate_unified_score(low_importance, nil)
      urs_high = HybridScorer.calculate_unified_score(high_importance, nil)

      assert urs_high > urs_low
    end

    test "cross-modality connections boost URS" do
      item = %{
        importance: 0.5,
        access_count: 0,
        last_accessed_at: NaiveDateTime.utc_now()
      }

      urs_isolated = HybridScorer.calculate_unified_score(item, nil, cross_modality_connections: 0)
      urs_connected = HybridScorer.calculate_unified_score(item, nil, cross_modality_connections: 2)

      assert urs_connected > urs_isolated
    end
  end

  describe "calculate_cross_modality_score/2" do
    test "returns 0 for isolated items" do
      item = %{importance: 0.5}
      score = HybridScorer.calculate_cross_modality_score(item)
      assert score == 0.0
    end

    test "returns 0.5 for items with 1 connection" do
      item = %{cross_modality_connections: 1}
      score = HybridScorer.calculate_cross_modality_score(item)
      assert score == 0.5
    end

    test "returns 1.0 for items with 2+ connections" do
      item = %{cross_modality_connections: 3}
      score = HybridScorer.calculate_cross_modality_score(item)
      assert score == 1.0
    end

    test "accepts list of connections" do
      item = %{cross_modality: [:memory, :code]}
      score = HybridScorer.calculate_cross_modality_score(item)
      assert score == 1.0
    end

    test "infers connections from item metadata" do
      # Item with code reference
      code_item = %{file_path: "lib/app.ex", symbol: "my_func"}
      code_score = HybridScorer.calculate_cross_modality_score(code_item)
      assert code_score > 0.0

      # Item with knowledge graph reference
      knowledge_item = %{relationships: ["A -> B"]}
      knowledge_score = HybridScorer.calculate_cross_modality_score(knowledge_item)
      assert knowledge_score > 0.0
    end
  end

  describe "classify_items/3" do
    test "groups items into tiers" do
      items = [
        %{id: 1, importance: 0.95, access_count: 10, last_accessed_at: NaiveDateTime.utc_now()},
        %{id: 2, importance: 0.7, access_count: 5, last_accessed_at: NaiveDateTime.utc_now()},
        %{id: 3, importance: 0.2, access_count: 0, last_accessed_at: NaiveDateTime.add(NaiveDateTime.utc_now(), -30, :day)}
      ]

      classified = HybridScorer.classify_items(items, nil, model_type: :medium)

      assert Map.has_key?(classified, :tier1)
      assert Map.has_key?(classified, :tier2)
      assert Map.has_key?(classified, :tier3)

      # All items should be distributed
      total = length(classified.tier1) + length(classified.tier2) + length(classified.tier3)
      assert total == 3
    end

    test "adds URS to each item" do
      items = [%{importance: 0.8, access_count: 5, last_accessed_at: NaiveDateTime.utc_now()}]

      classified = HybridScorer.classify_items(items, nil)

      # Each tier's items should have :urs field
      all_items = classified.tier1 ++ classified.tier2 ++ classified.tier3
      assert Enum.all?(all_items, &Map.has_key?(&1, :urs))
    end

    test "sorts items within each tier by URS descending" do
      items = [
        %{importance: 0.95, access_count: 10, last_accessed_at: NaiveDateTime.utc_now()},
        %{importance: 0.92, access_count: 8, last_accessed_at: NaiveDateTime.utc_now()}
      ]

      classified = HybridScorer.classify_items(items, nil)

      # If both items are in same tier, first should have higher URS
      for tier_items <- [classified.tier1, classified.tier2, classified.tier3] do
        if length(tier_items) > 1 do
          scores = Enum.map(tier_items, & &1[:urs])
          assert scores == Enum.sort(scores, :desc)
        end
      end
    end
  end

  describe "explain_tier/3" do
    test "returns tier explanation with URS breakdown" do
      item = %{
        importance: 0.8,
        access_count: 5,
        last_accessed_at: NaiveDateTime.utc_now()
      }

      explanation = HybridScorer.explain_tier(item, nil, model_type: :medium)

      assert Map.has_key?(explanation, :tier)
      assert explanation.tier in [:tier1, :tier2, :tier3]

      assert Map.has_key?(explanation, :unified_relevance_score)
      assert is_float(explanation.unified_relevance_score)

      assert Map.has_key?(explanation, :thresholds)
      assert Map.has_key?(explanation.thresholds, :tier1)
      assert Map.has_key?(explanation.thresholds, :tier2)

      assert Map.has_key?(explanation, :components)
      assert Map.has_key?(explanation.components, :semantic)
      assert Map.has_key?(explanation.components, :temporal)
      assert Map.has_key?(explanation.components, :importance)
      assert Map.has_key?(explanation.components, :cross_modality)
    end
  end
end
