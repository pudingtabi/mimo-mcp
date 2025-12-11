defmodule Mimo.Cache.Embedding do
  @moduledoc """
  LRU cache for embeddings to avoid redundant Ollama calls (SPEC-061).

  Significantly reduces latency for repeated or similar content by caching
  embedding vectors with content-hash keys.

  ## Features

    * LRU eviction when cache exceeds size limit
    * TTL-based expiration (default: 24 hours)
    * Content-based hashing for deduplication
    * Automatic cache statistics tracking

  ## Performance Impact

    * Cache hit: ~0.1ms (vs ~200-500ms for Ollama call)
    * Expected hit rate: 30-60% for typical workloads
    * Memory usage: ~1KB per cached embedding (768-dim float32)

  ## Usage

      # Get from cache (returns :miss if not found)
      case Mimo.Cache.Embedding.get("some content") do
        {:ok, embedding} -> embedding
        :miss -> generate_and_cache(content)
      end

      # Store in cache
      Mimo.Cache.Embedding.put("some content", embedding)

      # Get stats
      Mimo.Cache.Embedding.stats()
  """

  use GenServer
  require Logger

  # Configuration
  @cache_size 10_000
  @ttl_ms :timer.hours(24)
  @cleanup_interval_ms :timer.minutes(5)

  # ETS table name
  @table :mimo_embedding_cache
  @stats_table :mimo_embedding_cache_stats

  # ==========================================================================
  # Public API
  # ==========================================================================

  @doc """
  Start the embedding cache.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get embedding from cache.

  Returns `{:ok, embedding}` on hit, `:miss` on miss or expired entry.
  """
  def get(content) when is_binary(content) do
    hash = content_hash(content)

    case :ets.lookup(@table, hash) do
      [{^hash, embedding, timestamp}] ->
        now = System.monotonic_time(:millisecond)

        if now - timestamp < @ttl_ms do
          # Cache hit - update stats and access time
          increment_stat(:hits)
          :ets.update_element(@table, hash, {3, now})
          {:ok, embedding}
        else
          # Expired entry
          :ets.delete(@table, hash)
          increment_stat(:expired)
          :miss
        end

      [] ->
        increment_stat(:misses)
        :miss
    end
  end

  @doc """
  Store embedding in cache.

  Automatically triggers LRU eviction if cache is over size limit.
  """
  def put(content, embedding) when is_binary(content) and is_list(embedding) do
    hash = content_hash(content)
    timestamp = System.monotonic_time(:millisecond)

    :ets.insert(@table, {hash, embedding, timestamp})
    increment_stat(:writes)

    # Async eviction check
    GenServer.cast(__MODULE__, :maybe_evict)

    :ok
  end

  @doc """
  Get cache statistics.
  """
  def stats do
    hits = get_stat(:hits)
    misses = get_stat(:misses)
    total = hits + misses

    %{
      size: :ets.info(@table, :size),
      max_size: @cache_size,
      hits: hits,
      misses: misses,
      expired: get_stat(:expired),
      writes: get_stat(:writes),
      evictions: get_stat(:evictions),
      hit_rate: if(total > 0, do: Float.round(hits / total * 100, 2), else: 0.0),
      memory_bytes: :ets.info(@table, :memory) * :erlang.system_info(:wordsize)
    }
  end

  @doc """
  Clear all cached embeddings.
  """
  def clear do
    :ets.delete_all_objects(@table)
    :ets.delete_all_objects(@stats_table)
    :ok
  end

  @doc """
  Check if cache is available (table exists).
  """
  def available? do
    :ets.whereis(@table) != :undefined
  end

  # ==========================================================================
  # GenServer Callbacks
  # ==========================================================================

  @impl GenServer
  def init(_opts) do
    # Create ETS tables
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      {:read_concurrency, true},
      {:write_concurrency, true}
    ])

    :ets.new(@stats_table, [
      :named_table,
      :public,
      :set,
      {:write_concurrency, true}
    ])

    # Initialize stats
    Enum.each([:hits, :misses, :expired, :writes, :evictions], fn key ->
      :ets.insert(@stats_table, {key, 0})
    end)

    # Schedule periodic cleanup
    schedule_cleanup()

    Logger.info(
      "[EmbeddingCache] Started with max_size=#{@cache_size}, ttl=#{div(@ttl_ms, 60_000)}min"
    )

    {:ok, %{}}
  end

  @impl GenServer
  def handle_cast(:maybe_evict, state) do
    size = :ets.info(@table, :size)

    if size > @cache_size do
      evict_lru(size - @cache_size + div(@cache_size, 10))
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:cleanup, state) do
    cleanup_expired()
    schedule_cleanup()
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ==========================================================================
  # Private Helpers
  # ==========================================================================

  defp content_hash(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp increment_stat(key) do
    :ets.update_counter(@stats_table, key, {2, 1}, {key, 0})
  rescue
    ArgumentError -> :ok
  end

  defp get_stat(key) do
    case :ets.lookup(@stats_table, key) do
      [{^key, value}] -> value
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  defp evict_lru(count) when count > 0 do
    # Get all entries sorted by timestamp (oldest first)
    entries =
      :ets.tab2list(@table)
      |> Enum.sort_by(fn {_hash, _embedding, timestamp} -> timestamp end)
      |> Enum.take(count)

    # Delete oldest entries
    Enum.each(entries, fn {hash, _, _} ->
      :ets.delete(@table, hash)
    end)

    evicted = length(entries)
    :ets.update_counter(@stats_table, :evictions, {2, evicted}, {:evictions, 0})

    Logger.debug("[EmbeddingCache] Evicted #{evicted} entries")
  end

  defp evict_lru(_), do: :ok

  defp cleanup_expired do
    now = System.monotonic_time(:millisecond)
    cutoff = now - @ttl_ms

    # Find and delete expired entries
    expired =
      :ets.tab2list(@table)
      |> Enum.filter(fn {_hash, _embedding, timestamp} -> timestamp < cutoff end)

    Enum.each(expired, fn {hash, _, _} ->
      :ets.delete(@table, hash)
    end)

    if length(expired) > 0 do
      :ets.update_counter(@stats_table, :expired, {2, length(expired)}, {:expired, 0})
      Logger.debug("[EmbeddingCache] Cleaned up #{length(expired)} expired entries")
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
