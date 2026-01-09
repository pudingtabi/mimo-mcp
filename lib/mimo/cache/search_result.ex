defmodule Mimo.Cache.SearchResult do
  @moduledoc """
  SPEC-073: Short-lived cache for memory search results.

  Caches search results for a short TTL (30 seconds) to avoid redundant
  searches for identical or very similar queries within a single interaction.

  ## Performance Impact

    * Cache hit: <1ms (vs ~50-200ms for full search)
    * Expected hit rate: 20-40% for typical sessions
    * Memory usage: ~2KB per cached result

  ## Design

  Uses content-based hashing of query + options to detect duplicate searches.
  Short TTL ensures freshness while eliminating redundancy in rapid
  query-response cycles.

  ## Usage

      # Check cache before searching
      case SearchResult.get(query, opts) do
        {:ok, results} -> results
        :miss ->
          results = do_search(query, opts)
          SearchResult.put(query, opts, results)
          results
      end
  """

  use GenServer
  require Logger

  # Configuration
  @cache_size 500
  # 30 seconds - short to ensure freshness
  @ttl_ms 30_000
  @cleanup_interval_ms 10_000

  # ETS table names
  @table :mimo_search_cache
  @stats_table :mimo_search_cache_stats

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get cached search results.

  Returns `{:ok, results}` on hit, `:miss` on miss or expired entry.
  """
  @spec get(String.t(), keyword()) :: {:ok, list()} | :miss
  def get(query, opts \\ []) when is_binary(query) do
    hash = cache_key(query, opts)

    case :ets.lookup(@table, hash) do
      [{^hash, results, timestamp}] ->
        now = System.monotonic_time(:millisecond)

        if now - timestamp < @ttl_ms do
          increment_stat(:hits)
          {:ok, results}
        else
          :ets.delete(@table, hash)
          increment_stat(:expired)
          :miss
        end

      [] ->
        increment_stat(:misses)
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc """
  Store search results in cache.
  """
  @spec put(String.t(), keyword(), list()) :: :ok
  def put(query, opts, results) when is_binary(query) and is_list(results) do
    hash = cache_key(query, opts)
    timestamp = System.monotonic_time(:millisecond)

    :ets.insert(@table, {hash, results, timestamp})
    increment_stat(:writes)

    # Async eviction check
    GenServer.cast(__MODULE__, :maybe_evict)

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Get cache statistics.
  """
  @spec stats() :: map()
  def stats do
    hits = get_stat(:hits)
    misses = get_stat(:misses)
    total = hits + misses

    %{
      size: safe_ets_info(@table, :size),
      max_size: @cache_size,
      hits: hits,
      misses: misses,
      expired: get_stat(:expired),
      writes: get_stat(:writes),
      hit_rate: if(total > 0, do: Float.round(hits / total * 100, 2), else: 0.0),
      ttl_ms: @ttl_ms
    }
  end

  @doc """
  Clear all cached results.
  """
  @spec clear() :: :ok
  def clear do
    try do
      :ets.delete_all_objects(@table)
      :ets.delete_all_objects(@stats_table)
    rescue
      _ -> :ok
    end

    :ok
  end

  @impl GenServer
  def init(_opts) do
    # Create ETS tables
    Mimo.EtsSafe.ensure_table(@table, [
      :named_table,
      :public,
      :set,
      {:read_concurrency, true},
      {:write_concurrency, true}
    ])

    Mimo.EtsSafe.ensure_table(@stats_table, [
      :named_table,
      :public,
      :set,
      {:write_concurrency, true}
    ])

    # Initialize stats
    Enum.each([:hits, :misses, :expired, :writes], fn key ->
      :ets.insert(@stats_table, {key, 0})
    end)

    # Schedule periodic cleanup
    schedule_cleanup()

    Logger.info("[SearchCache] Started with max_size=#{@cache_size}, ttl=#{@ttl_ms}ms")

    {:ok, %{}}
  end

  @impl GenServer
  def handle_cast(:maybe_evict, state) do
    size = safe_ets_info(@table, :size)

    if size > @cache_size do
      evict_oldest(size - @cache_size + 50)
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

  defp cache_key(query, opts) do
    # Include relevant opts in cache key
    limit = Keyword.get(opts, :limit, 10)
    category = Keyword.get(opts, :category, nil)

    key_string = "#{query}|#{limit}|#{category}"
    :crypto.hash(:md5, key_string) |> Base.encode16(case: :lower)
  end

  defp increment_stat(key) do
    try do
      :ets.update_counter(@stats_table, key, {2, 1}, {key, 0})
    rescue
      ArgumentError -> :ok
    end
  end

  defp get_stat(key) do
    try do
      case :ets.lookup(@stats_table, key) do
        [{^key, value}] -> value
        [] -> 0
      end
    rescue
      ArgumentError -> 0
    end
  end

  defp safe_ets_info(table, key) do
    try do
      :ets.info(table, key) || 0
    rescue
      _ -> 0
    end
  end

  defp evict_oldest(count) when count > 0 do
    try do
      entries =
        :ets.tab2list(@table)
        |> Enum.sort_by(fn {_hash, _results, timestamp} -> timestamp end)
        |> Enum.take(count)

      Enum.each(entries, fn {hash, _, _} ->
        :ets.delete(@table, hash)
      end)

      Logger.debug("[SearchCache] Evicted #{length(entries)} entries")
    rescue
      _ -> :ok
    end
  end

  defp evict_oldest(_), do: :ok

  defp cleanup_expired do
    try do
      now = System.monotonic_time(:millisecond)
      cutoff = now - @ttl_ms

      expired =
        :ets.tab2list(@table)
        |> Enum.filter(fn {_hash, _results, timestamp} -> timestamp < cutoff end)

      Enum.each(expired, fn {hash, _, _} ->
        :ets.delete(@table, hash)
      end)

      unless Enum.empty?(expired) do
        increment_stat(:expired)
        Logger.debug("[SearchCache] Cleaned up #{length(expired)} expired entries")
      end
    rescue
      _ -> :ok
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
