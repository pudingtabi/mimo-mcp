defmodule Mimo.Cache.Classifier do
  @moduledoc """
  LRU cache for LLM classifier results.

  Caches embedding vectors and classification results to avoid
  redundant LLM calls for identical or similar queries.

  ## Configuration

      config :mimo_mcp, Mimo.Cache.Classifier,
        ttl_seconds: 3600,      # Cache TTL (1 hour default)
        max_entries: 1000,      # Max cache entries
        cleanup_interval: 60_000 # Cleanup every minute

  ## Usage

      # Cache embedding generation
      {:ok, embedding} = Classifier.get_or_compute_embedding("my query", fn ->
        Mimo.Brain.LLM.generate_embedding("my query")
      end)

      # Cache classification results
      {:ok, category} = Classifier.get_or_compute_classification("input text", fn ->
        Mimo.Brain.Classifier.classify("input text")
      end)
  """
  use GenServer
  require Logger

  @table_name :mimo_classifier_cache
  @default_ttl 3600
  @default_max_entries 1000
  @default_cleanup_interval 60_000

  # ==========================================================================
  # Client API
  # ==========================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get cached embedding or compute and cache it.

  ## Parameters
    - `text` - The text to get embedding for
    - `compute_fn` - Function that computes embedding if cache miss

  ## Returns
    - `{:ok, embedding}` - Cached or freshly computed embedding
    - `{:error, reason}` - If computation fails
  """
  @spec get_or_compute_embedding(String.t(), function()) :: {:ok, list(float())} | {:error, term()}
  def get_or_compute_embedding(text, compute_fn) when is_binary(text) do
    key = {:embedding, hash_text(text)}
    get_or_compute(key, compute_fn)
  end

  @doc """
  Get cached classification or compute and cache it.
  """
  @spec get_or_compute_classification(String.t(), function()) :: {:ok, term()} | {:error, term()}
  def get_or_compute_classification(text, compute_fn) when is_binary(text) do
    key = {:classification, hash_text(text)}
    get_or_compute(key, compute_fn)
  end

  @doc """
  Get cached query result or compute and cache it.
  """
  @spec get_or_compute_query(String.t(), map(), function()) :: {:ok, term()} | {:error, term()}
  def get_or_compute_query(query, context, compute_fn) when is_binary(query) do
    key = {:query, hash_text(query <> inspect(context))}
    get_or_compute(key, compute_fn)
  end

  @doc """
  Manually invalidate a cache entry.
  """
  @spec invalidate(term()) :: :ok
  def invalidate(key) do
    GenServer.cast(__MODULE__, {:invalidate, key})
  end

  @doc """
  Clear all cache entries.
  """
  @spec clear() :: :ok
  def clear do
    GenServer.cast(__MODULE__, :clear)
  end

  @doc """
  Get cache statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # ==========================================================================
  # GenServer Implementation
  # ==========================================================================

  @impl true
  def init(opts) do
    ttl = Keyword.get(opts, :ttl_seconds, config(:ttl_seconds, @default_ttl))
    max_entries = Keyword.get(opts, :max_entries, config(:max_entries, @default_max_entries))

    cleanup_interval =
      Keyword.get(opts, :cleanup_interval, config(:cleanup_interval, @default_cleanup_interval))

    # Create ETS table for cache
    Mimo.EtsSafe.ensure_table(@table_name, [:named_table, :public, :set, {:read_concurrency, true}])

    # Schedule periodic cleanup
    schedule_cleanup(cleanup_interval)

    state = %{
      ttl: ttl,
      max_entries: max_entries,
      cleanup_interval: cleanup_interval,
      hits: 0,
      misses: 0
    }

    Logger.info("Classifier cache started (TTL: #{ttl}s, max: #{max_entries})")
    {:ok, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    entry_count = :ets.info(@table_name, :size)
    memory_bytes = :ets.info(@table_name, :memory) * :erlang.system_info(:wordsize)

    stats = %{
      entries: entry_count,
      memory_mb: Float.round(memory_bytes / 1_048_576, 2),
      hits: state.hits,
      misses: state.misses,
      hit_rate: calculate_hit_rate(state.hits, state.misses),
      ttl_seconds: state.ttl,
      max_entries: state.max_entries
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:get_or_compute, key, compute_fn}, _from, state) do
    now = System.monotonic_time(:second)
    key_type = elem(key, 0)

    case :ets.lookup(@table_name, key) do
      [{^key, value, expires_at}] when expires_at > now ->
        # Cache hit - emit telemetry
        :telemetry.execute(
          [:mimo, :cache, :classifier, :hit],
          %{count: 1},
          %{key_type: key_type}
        )

        {:reply, {:ok, value}, %{state | hits: state.hits + 1}}

      _ ->
        # Cache miss - emit telemetry and compute value
        :telemetry.execute(
          [:mimo, :cache, :classifier, :miss],
          %{count: 1},
          %{key_type: key_type}
        )

        case compute_fn.() do
          {:ok, value} = result ->
            expires_at = now + state.ttl
            :ets.insert(@table_name, {key, value, expires_at})
            maybe_evict(state.max_entries)
            {:reply, result, %{state | misses: state.misses + 1}}

          error ->
            {:reply, error, %{state | misses: state.misses + 1}}
        end
    end
  end

  @impl true
  def handle_cast({:invalidate, key}, state) do
    :ets.delete(@table_name, key)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:clear, state) do
    :ets.delete_all_objects(@table_name)
    Logger.info("Classifier cache cleared")
    {:noreply, %{state | hits: 0, misses: 0}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    expired_count = cleanup_expired()

    if expired_count > 0 do
      Logger.debug("Classifier cache cleanup: removed #{expired_count} expired entries")
    end

    schedule_cleanup(state.cleanup_interval)
    {:noreply, state}
  end

  # ==========================================================================
  # Private Helpers
  # ==========================================================================

  defp get_or_compute(key, compute_fn) do
    # Use shorter timeout in test mode since we're using fallback embeddings
    timeout = if Application.get_env(:mimo_mcp, :skip_external_apis, false), do: 5_000, else: 30_000
    GenServer.call(__MODULE__, {:get_or_compute, key, compute_fn}, timeout)
  catch
    :exit, {:noproc, _} ->
      # Cache not started, compute directly
      compute_fn.()

    :exit, {:shutdown, _} ->
      # Cache shutting down, compute directly
      compute_fn.()

    :exit, {:timeout, _} ->
      # Timeout waiting for cache, compute directly
      compute_fn.()

    :exit, reason ->
      # Any other exit reason, log and compute directly
      require Logger
      Logger.warning("Classifier cache exited with reason: #{inspect(reason)}, computing directly")
      compute_fn.()
  end

  defp hash_text(text) do
    :crypto.hash(:sha256, text)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp schedule_cleanup(interval) do
    Process.send_after(self(), :cleanup, interval)
  end

  defp cleanup_expired do
    now = System.monotonic_time(:second)

    # Find all expired entries
    expired =
      :ets.foldl(
        fn {key, _value, expires_at}, acc ->
          if expires_at <= now, do: [key | acc], else: acc
        end,
        [],
        @table_name
      )

    # Delete expired entries
    Enum.each(expired, &:ets.delete(@table_name, &1))
    length(expired)
  end

  defp maybe_evict(max_entries) do
    current_size = :ets.info(@table_name, :size)

    if current_size > max_entries do
      # Simple eviction: remove oldest 10%
      to_remove = div(max_entries, 10)

      entries =
        :ets.tab2list(@table_name)
        |> Enum.sort_by(fn {_key, _value, expires_at} -> expires_at end)
        |> Enum.take(to_remove)

      Enum.each(entries, fn {key, _, _} -> :ets.delete(@table_name, key) end)
      Logger.debug("Classifier cache evicted #{to_remove} entries")
    end
  end

  defp calculate_hit_rate(hits, misses) when hits + misses == 0, do: 0.0

  defp calculate_hit_rate(hits, misses) do
    Float.round(hits / (hits + misses) * 100, 1)
  end

  defp config(key, default) do
    Application.get_env(:mimo_mcp, __MODULE__, [])
    |> Keyword.get(key, default)
  end
end
