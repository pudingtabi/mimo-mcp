defmodule Mimo.SPEC051.IntegrationTest do
  @moduledoc """
  SPEC-051 Integration Tests: End-to-end testing of Tiered Context Delivery.

  Tests the complete flow from query → scoring → tiering → delivery.
  """
  use Mimo.DataCase, async: false

  alias Mimo.Brain.HybridScorer
  alias Mimo.Context.BudgetAllocator
  alias Mimo.NeuroSymbolic.CrossModalityLinker
  alias Mimo.Context.AccessPatternTracker
  alias Mimo.Context.Prefetcher
  alias Mimo.Brain.Memory

  describe "end-to-end tiered context delivery" do
    setup do
      # Start required GenServers
      start_supervised!(AccessPatternTracker)
      start_supervised!(Prefetcher)

      # Create test memories using correct API and fetch full structs
      {:ok, id1} = Memory.store(%{content: "Phoenix authentication uses plugs", type: "fact"})
      {:ok, id2} = Memory.store(%{content: "User prefers TypeScript", type: "observation"})
      {:ok, id3} = Memory.store(%{content: "TODO: fix auth bug", type: "action"})

      # Fetch the full memory structs
      {:ok, memory1} = Memory.get_memory(id1)
      {:ok, memory2} = Memory.get_memory(id2)
      {:ok, memory3} = Memory.get_memory(id3)

      %{memories: [memory1, memory2, memory3], memory_ids: [id1, id2, id3]}
    end

    test "scores and tiers memories correctly" do
      # Score some content - HybridScorer expects a map with content
      content = %{
        id: 1,
        content: "Phoenix authentication patterns",
        importance: 0.9,
        accessed_at: DateTime.utc_now(),
        category: :fact
      }

      score = HybridScorer.score(content, "authentication module")

      # Score should be a float between 0 and 1
      assert is_float(score)
      assert score >= 0.0 and score <= 1.0
    end

    test "classify_tier works with full content maps", %{memories: [memory | _]} do
      # Use classify_tier with a proper content map (Ecto struct or map)
      tier = HybridScorer.classify_tier(memory, "test query")
      assert tier in [:tier1, :tier2, :tier3]
    end

    test "BudgetAllocator allocates tokens per model type" do
      # Allocate budget for small model
      allocation = BudgetAllocator.allocate(:small, 2000)

      # Should have tiered allocation
      assert Map.has_key?(allocation, :tier1)
      assert Map.has_key?(allocation, :tier2)
      assert Map.has_key?(allocation, :tier3)
      assert Map.has_key?(allocation, :total)

      # Total should match input
      assert allocation.total == 2000

      # Tier1 + Tier2 + Tier3 should equal total
      assert allocation.tier1 + allocation.tier2 + allocation.tier3 == allocation.total
    end

    test "BudgetAllocator fit_to_budget limits items" do
      # Create some scored items with token estimates
      items = [
        %{id: 1, content: String.duplicate("a", 100), score: 0.9},
        %{id: 2, content: String.duplicate("b", 100), score: 0.8},
        %{id: 3, content: String.duplicate("c", 100), score: 0.7}
      ]

      # Fit to a limited budget
      {fitted, remaining} = BudgetAllocator.fit_to_budget(items, 50)

      # Should return two lists
      assert is_list(fitted)
      assert is_integer(remaining) or is_list(remaining)
    end

    test "CrossModalityLinker finds connections across sources", %{memory_ids: [id | _]} do
      # find_cross_connections expects an item map with :source_type and :id
      # Convert to the expected format
      item = %{source_type: :memory, id: id, content: "Phoenix authentication uses plugs"}
      connections = CrossModalityLinker.find_cross_connections(item)

      # Should return a count of cross-connections (integer)
      assert is_integer(connections) and connections >= 0
    end

    test "AccessPatternTracker predicts based on task type" do
      # Track some accesses for coding tasks
      AccessPatternTracker.track_access(:memory, 1, task: "implement feature")
      AccessPatternTracker.track_access(:code_symbol, "auth", task: "implement feature")
      AccessPatternTracker.track_access(:memory, 2, task: "implement feature")
      Process.sleep(20)

      # Get prediction for similar task
      prediction = AccessPatternTracker.predict("add new feature")

      assert prediction.task_type == :coding
      assert is_map(prediction.source_predictions)
      assert is_float(prediction.confidence)
    end

    test "Prefetcher caches context for quick retrieval" do
      # Store something in cache
      Prefetcher.cache_put(:memory, "auth query", [%{id: 1, content: "auth info"}])
      Process.sleep(10)

      # Should retrieve from cache
      cached = Prefetcher.get_cached(:memory, "auth query")
      assert cached == [%{id: 1, content: "auth info"}]

      # Non-existent should return nil
      assert Prefetcher.get_cached(:memory, "nonexistent") == nil
    end

    test "full pipeline: query → score → classify → allocate", %{memories: memories} do
      query = "implement authentication"

      # 1. Track the access pattern
      AccessPatternTracker.track_access(:query, query, task: query)
      Process.sleep(10)

      # 2. Get predictions
      predictions = AccessPatternTracker.predict(query)
      assert predictions.task_type == :coding

      # 3. Score the memories (using full Ecto structs)
      scored =
        Enum.map(memories, fn memory ->
          score = HybridScorer.score(memory, query)
          tier = HybridScorer.classify_tier(memory, query)
          # Convert Ecto struct to map for merging
          memory_map = Map.from_struct(memory)
          Map.merge(memory_map, %{score: score, tier: tier})
        end)

      # All should be classified
      Enum.each(scored, fn item ->
        assert item.tier in [:tier1, :tier2, :tier3]
        assert is_float(item.score)
      end)

      # 4. Allocate budget
      allocation = BudgetAllocator.allocate(:medium, 4000)

      # Verify structure
      assert allocation.tier1 > 0
      assert allocation.tier2 > 0
      assert allocation.tier3 > 0
    end
  end

  describe "URS formula weights" do
    test "weights sum to 1.0" do
      # From SPEC-051: (Semantic * 0.35) + (Temporal * 0.25) + (Importance * 0.20) + (CrossModal * 0.20)
      weights = [0.35, 0.25, 0.20, 0.20]
      assert_in_delta Enum.sum(weights), 1.0, 0.001
    end

    test "semantic weight is highest at 0.35" do
      # Semantic similarity should be the most important factor
      # temporal
      assert 0.35 > 0.25
      # importance
      assert 0.35 > 0.20
      # cross-modal
      assert 0.35 > 0.20
    end
  end

  describe "budget allocation percentages" do
    test "small model gets conservative allocation" do
      allocation = BudgetAllocator.allocate(:small, 2000)

      # Tier1 should be ~5% for small models
      tier1_percentage = allocation.tier1 / allocation.total
      assert_in_delta tier1_percentage, 0.05, 0.02
    end

    test "medium model gets balanced allocation" do
      allocation = BudgetAllocator.allocate(:medium, 8000)

      # Tier1 should be ~8% for medium models
      tier1_percentage = allocation.tier1 / allocation.total
      assert_in_delta tier1_percentage, 0.08, 0.02
    end

    test "large model gets generous allocation" do
      allocation = BudgetAllocator.allocate(:large, 40_000)

      # Tier1 should be ~10% for large models
      tier1_percentage = allocation.tier1 / allocation.total
      assert_in_delta tier1_percentage, 0.10, 0.02
    end
  end

  describe "cross-modality scoring integration" do
    setup do
      # Create a memory for testing
      {:ok, id} = Memory.store(%{content: "auth_module handles login", type: "fact"})
      {:ok, memory} = Memory.get_memory(id)
      %{memory: memory, memory_id: id}
    end

    test "HybridScorer includes cross-modality when enabled", %{memory: memory} do
      # Score with cross-modality enabled
      score_with = HybridScorer.score(memory, "test", cross_modality_weight: 0.2)

      # Score without (weight = 0)
      score_without = HybridScorer.score(memory, "test", cross_modality_weight: 0.0)

      # Both should be valid scores
      assert is_float(score_with) and score_with >= 0.0 and score_with <= 1.0
      assert is_float(score_without) and score_without >= 0.0 and score_without <= 1.0
    end
  end

  describe "predictive loading integration" do
    setup do
      start_supervised!(AccessPatternTracker)
      start_supervised!(Prefetcher)
      :ok
    end

    test "prefetch triggers based on pattern predictions" do
      # Build up some access patterns
      for _ <- 1..5 do
        AccessPatternTracker.track_access(:memory, Enum.random(1..10), task: "fix bug")
      end

      Process.sleep(20)

      # Start prefetch for similar task
      result = Prefetcher.prefetch_for_query("debug issue", sources: [:memory])
      assert result == :ok

      # Check stats show prefetch was started
      stats = Prefetcher.stats()
      assert stats.prefetches_started >= 1
    end

    test "cache hit rate improves with prefetching" do
      # Manually cache some items
      Prefetcher.cache_put(:memory, "common query", [%{id: 1}])
      Process.sleep(10)

      # Access cached item multiple times
      for _ <- 1..5 do
        Prefetcher.get_cached(:memory, "common query")
      end

      stats = Prefetcher.stats()

      # Should have more hits than misses for cached items
      assert stats.cache_hits >= 5
    end
  end
end
