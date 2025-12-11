defmodule Mimo.Context.PrefetcherTest do
  use ExUnit.Case, async: true

  alias Mimo.Context.Prefetcher

  describe "cache operations" do
    setup do
      start_supervised!(Prefetcher)
      :ok
    end

    test "cache_put and get_cached work together" do
      Prefetcher.cache_put(:memory, "test_query", [%{id: 1, content: "test"}])
      Process.sleep(10)

      result = Prefetcher.get_cached(:memory, "test_query")
      assert result == [%{id: 1, content: "test"}]
    end

    test "get_cached returns nil for non-existent entries" do
      result = Prefetcher.get_cached(:memory, "non_existent")
      assert result == nil
    end

    test "cache_put with custom TTL" do
      Prefetcher.cache_put(:knowledge, "query", [%{data: "value"}], ttl_ms: 1000)
      Process.sleep(10)

      result = Prefetcher.get_cached(:knowledge, "query")
      assert result == [%{data: "value"}]
    end
  end

  describe "suggest/1" do
    setup do
      start_supervised!(Prefetcher)
      :ok
    end

    test "returns suggestions for known query" do
      Prefetcher.cache_put(:memory, "auth patterns", [%{id: 1}])
      Process.sleep(10)

      suggestions = Prefetcher.suggest("auth")
      assert is_list(suggestions)
    end

    test "returns empty list for unknown query" do
      suggestions = Prefetcher.suggest("completely_random_xyz_123")
      assert suggestions == []
    end
  end

  describe "prefetch_for_query/2" do
    setup do
      start_supervised!(Prefetcher)
      :ok
    end

    test "starts prefetching without blocking" do
      # Should return immediately
      result = Prefetcher.prefetch_for_query("test query", sources: [:memory])
      assert result == :ok
    end

    test "accepts source filter option" do
      result = Prefetcher.prefetch_for_query("auth module", sources: [:memory, :knowledge])
      assert result == :ok
    end

    test "accepts priority option" do
      result = Prefetcher.prefetch_for_query("critical query", priority: :high)
      assert result == :ok
    end
  end

  describe "invalidate/2" do
    setup do
      start_supervised!(Prefetcher)
      :ok
    end

    test "invalidates cache entry" do
      Prefetcher.cache_put(:memory, "to_invalidate", [%{id: 1}])
      Process.sleep(10)

      # Verify it exists
      assert Prefetcher.get_cached(:memory, "to_invalidate") == [%{id: 1}]

      # Invalidate
      Prefetcher.invalidate(:memory, "to_invalidate")
      Process.sleep(10)

      # Verify it's gone
      assert Prefetcher.get_cached(:memory, "to_invalidate") == nil
    end
  end

  describe "invalidate_source/1" do
    setup do
      start_supervised!(Prefetcher)
      :ok
    end

    test "invalidates all entries for a source type" do
      Prefetcher.cache_put(:memory, "query1", [%{id: 1}])
      Prefetcher.cache_put(:memory, "query2", [%{id: 2}])
      Prefetcher.cache_put(:knowledge, "query3", [%{id: 3}])
      Process.sleep(10)

      # Invalidate all memory entries
      Prefetcher.invalidate_source(:memory)
      Process.sleep(10)

      # Memory entries should be gone
      assert Prefetcher.get_cached(:memory, "query1") == nil
      assert Prefetcher.get_cached(:memory, "query2") == nil
      # Knowledge entry should remain
      assert Prefetcher.get_cached(:knowledge, "query3") == [%{id: 3}]
    end
  end

  describe "clear/0" do
    setup do
      start_supervised!(Prefetcher)
      :ok
    end

    test "clears all cache entries" do
      Prefetcher.cache_put(:memory, "q1", [%{id: 1}])
      Prefetcher.cache_put(:knowledge, "q2", [%{id: 2}])
      Process.sleep(10)

      Prefetcher.clear()
      Process.sleep(10)

      assert Prefetcher.get_cached(:memory, "q1") == nil
      assert Prefetcher.get_cached(:knowledge, "q2") == nil
    end
  end

  describe "stats/0" do
    setup do
      start_supervised!(Prefetcher)
      :ok
    end

    test "returns cache statistics" do
      stats = Prefetcher.stats()

      assert Map.has_key?(stats, :cache_size)
      assert Map.has_key?(stats, :prefetches_started)
      assert Map.has_key?(stats, :cache_hits)
      assert Map.has_key?(stats, :cache_misses)
    end

    test "tracks cache hits" do
      Prefetcher.cache_put(:memory, "tracked", [%{id: 1}])
      Process.sleep(10)

      # Access it multiple times
      Prefetcher.get_cached(:memory, "tracked")
      Prefetcher.get_cached(:memory, "tracked")
      Prefetcher.get_cached(:memory, "tracked")

      stats = Prefetcher.stats()
      assert stats.cache_hits >= 3
    end

    test "tracks cache misses" do
      Prefetcher.get_cached(:memory, "nonexistent1")
      Prefetcher.get_cached(:memory, "nonexistent2")

      stats = Prefetcher.stats()
      assert stats.cache_misses >= 2
    end
  end

  describe "TTL expiration" do
    setup do
      start_supervised!(Prefetcher)
      :ok
    end

    test "expired entries return nil" do
      # Use a very short TTL
      Prefetcher.cache_put(:memory, "short_lived", [%{id: 1}], ttl_ms: 50)
      Process.sleep(10)

      # Should exist initially
      assert Prefetcher.get_cached(:memory, "short_lived") == [%{id: 1}]

      # Wait for expiration
      Process.sleep(60)

      # Should be expired now
      assert Prefetcher.get_cached(:memory, "short_lived") == nil
    end
  end
end
