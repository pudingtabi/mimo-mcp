defmodule Mimo.Brain.MemoryConsolidatorTest do
  use Mimo.DataCase

  alias Mimo.Brain.MemoryConsolidator
  alias Mimo.Brain.Engram
  alias Mimo.Repo

  describe "stats/0" do
    test "returns statistics about consolidation" do
      assert {:ok, stats} = MemoryConsolidator.stats()

      assert is_integer(stats.consolidated_memories)
      assert is_integer(stats.superseded_memories)
      assert is_integer(stats.potential_candidates)
      assert is_map(stats.configuration)
      assert stats.configuration.similarity_threshold > 0
      assert stats.configuration.min_cluster_size > 0
    end
  end

  describe "find_candidates/1" do
    test "returns empty list when no clusters available" do
      # Without trained model, should return empty
      assert {:ok, candidates} = MemoryConsolidator.find_candidates()
      assert is_list(candidates)
    end

    test "respects limit option" do
      assert {:ok, candidates} = MemoryConsolidator.find_candidates(limit: 5)
      assert length(candidates) <= 5
    end

    test "respects threshold option" do
      assert {:ok, _candidates} = MemoryConsolidator.find_candidates(threshold: 0.9)
      # Higher threshold = fewer candidates
    end
  end

  describe "preview/2" do
    test "returns error for invalid cluster_id" do
      # Non-existent cluster
      assert {:error, _reason} = MemoryConsolidator.preview(999_999)
    end
  end

  describe "run/1" do
    test "dry_run returns without persisting" do
      assert {:ok, result} = MemoryConsolidator.run(dry_run: true, max_clusters: 1)

      assert result.dry_run == true
      assert is_integer(result.clusters_processed)
      assert is_integer(result.successes)
      assert is_integer(result.failures)
    end
  end

  describe "consolidate/2" do
    test "returns error for invalid cluster_id" do
      assert {:error, _reason} = MemoryConsolidator.consolidate(999_999)
    end

    test "dry_run option prevents persistence" do
      # With dry_run, should not create any memories
      before_count = Repo.aggregate(Engram, :count)

      # Even with invalid cluster, dry_run should work
      result = MemoryConsolidator.consolidate(999_999, dry_run: true)

      after_count = Repo.aggregate(Engram, :count)

      # No new memories created
      assert before_count == after_count
    end
  end

  describe "integration with dispatcher" do
    test "consolidation_stats operation works" do
      args = %{"operation" => "consolidation_stats"}
      assert {:ok, result} = Mimo.Tools.Dispatchers.Cognitive.dispatch(args)

      assert result.type == "consolidation_stats"
      assert is_map(result.stats)
      assert result.level == "SPEC-105 - Memory Consolidation"
    end

    test "consolidation_candidates operation works" do
      args = %{"operation" => "consolidation_candidates"}
      assert {:ok, result} = Mimo.Tools.Dispatchers.Cognitive.dispatch(args)

      assert result.type == "consolidation_candidates"
      assert is_list(result.candidates)
      assert is_integer(result.count)
    end

    test "consolidation_run with dry_run works" do
      args = %{"operation" => "consolidation_run", "dry_run" => true}
      assert {:ok, result} = Mimo.Tools.Dispatchers.Cognitive.dispatch(args)

      assert result.type == "consolidation_run"
      assert result.results.dry_run == true
    end
  end
end
