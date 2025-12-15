defmodule Mimo.Context.Prefetcher do
  @moduledoc """
  SPEC-051 Phase 3: Background pre-fetching of predicted context.

  Uses AccessPatternTracker predictions to pre-fetch likely-needed
  context in the background, improving response times.

  ## Features

    - ETS-based cache for predicted context
    - TTL-based cache invalidation
    - Priority-based fetching (Tier 1 first)
    - Rate-limited background operations

  ## Examples

      # Pre-fetch based on current query
      Prefetcher.prefetch_for_query("implement auth feature")

      # Get cached context
      context = Prefetcher.get_cached(:memory, "auth patterns")

      # Get cache statistics
      stats = Prefetcher.stats()
  """
  use GenServer
  require Logger

  alias Mimo.Context.AccessPatternTracker

  @cache_table :mimo_prefetch_cache
  # 5 minutes
  @default_ttl_ms 300_000
  # 10 seconds
  @prefetch_interval 10_000
  @max_cache_size 1000
  @batch_size 10

  # ==========================================================================
  # Public API
  # ==========================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Pre-fetch context based on a query/task.

  Analyzes the query, predicts likely-needed context, and starts
  background fetching of that context.
  """
  @spec prefetch_for_query(String.t(), keyword()) :: :ok
  def prefetch_for_query(query, opts \\ []) do
    GenServer.cast(__MODULE__, {:prefetch, query, opts})
  end

  @doc """
  Get cached context if available.

  Returns the cached value if found and not expired, nil otherwise.
  """
  @spec get_cached(atom(), term()) :: term() | nil
  def get_cached(source_type, source_id) do
    key = {source_type, source_id}
    now = System.monotonic_time(:millisecond)

    result =
      case :ets.lookup(@cache_table, key) do
        [{^key, value, expires_at}] when expires_at > now ->
          GenServer.cast(__MODULE__, :cache_hit)
          value

        [{^key, _value, _expires_at}] ->
          # Expired, delete it
          :ets.delete(@cache_table, key)
          GenServer.cast(__MODULE__, :cache_miss)
          nil

        [] ->
          GenServer.cast(__MODULE__, :cache_miss)
          nil
      end

    result
  catch
    :error, :badarg ->
      GenServer.cast(__MODULE__, :cache_miss)
      nil
  end

  @doc """
  Store a value in the prefetch cache.
  """
  @spec cache_put(atom(), term(), term(), keyword()) :: :ok
  def cache_put(source_type, source_id, value, opts \\ []) do
    ttl = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    key = {source_type, source_id}
    expires_at = System.monotonic_time(:millisecond) + ttl

    :ets.insert(@cache_table, {key, value, expires_at})
    :ok
  catch
    :error, :badarg -> :ok
  end

  @doc """
  Invalidate a specific cache entry.
  """
  @spec invalidate(atom(), term()) :: :ok
  def invalidate(source_type, source_id) do
    key = {source_type, source_id}
    :ets.delete(@cache_table, key)
    :ok
  catch
    :error, :badarg -> :ok
  end

  @doc """
  Invalidate all cache entries for a source type.
  """
  @spec invalidate_source(atom()) :: :ok
  def invalidate_source(source_type) do
    # Get all keys for this source type and delete them
    try do
      :ets.tab2list(@cache_table)
      |> Enum.filter(fn {{type, _id}, _value, _expires} -> type == source_type end)
      |> Enum.each(fn {{type, id}, _value, _expires} ->
        :ets.delete(@cache_table, {type, id})
      end)
    catch
      :error, :badarg -> :ok
    end

    :ok
  end

  @doc """
  Clear all cached context.
  """
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@cache_table)
    :ok
  catch
    :error, :badarg -> :ok
  end

  @doc """
  Get cache statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  catch
    :exit, _ -> %{status: :unavailable}
  end

  @doc """
  Get predictive suggestions based on current query.

  Combines AccessPatternTracker predictions with cache status.
  """
  @spec suggest(String.t()) :: list()
  def suggest(query) do
    GenServer.call(__MODULE__, {:suggest, query})
  catch
    :exit, _ -> []
  end

  # ==========================================================================
  # GenServer Callbacks
  # ==========================================================================

  @impl true
  def init(_opts) do
    # Create ETS table for caching
    Mimo.EtsSafe.ensure_table(@cache_table, [:set, :public, :named_table, read_concurrency: true])

    schedule_cleanup()
    schedule_prefetch_cycle()

    state = %{
      pending_queries: [],
      prefetches_started: 0,
      cache_hits: 0,
      cache_misses: 0,
      last_prefetch: nil
    }

    Logger.info("Prefetcher initialized with ETS cache")
    {:ok, state}
  end

  @impl true
  def handle_cast({:prefetch, query, opts}, state) do
    # Queue the query for prefetching
    new_pending = [{query, opts} | Enum.take(state.pending_queries, 9)]

    new_state = %{
      state
      | pending_queries: new_pending,
        prefetches_started: state.prefetches_started + 1
    }

    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:cache_hit, state) do
    {:noreply, %{state | cache_hits: state.cache_hits + 1}}
  end

  @impl true
  def handle_cast(:cache_miss, state) do
    {:noreply, %{state | cache_misses: state.cache_misses + 1}}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    cache_size =
      try do
        :ets.info(@cache_table, :size)
      catch
        :error, :badarg -> 0
      end

    stats = %{
      cache_size: cache_size,
      prefetches_started: state.prefetches_started,
      cache_hits: state.cache_hits,
      cache_misses: state.cache_misses,
      pending_queries: length(state.pending_queries),
      last_prefetch: state.last_prefetch
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:suggest, query}, _from, state) do
    suggestions = build_suggestions(query)
    {:reply, suggestions, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    enforce_max_size()
    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def handle_info(:prefetch_cycle, state) do
    new_state = process_pending_queries(state)
    schedule_prefetch_cycle()
    {:noreply, new_state}
  end

  # ==========================================================================
  # Private Functions
  # ==========================================================================

  defp schedule_cleanup do
    # Every minute
    Process.send_after(self(), :cleanup, 60_000)
  end

  defp schedule_prefetch_cycle do
    Process.send_after(self(), :prefetch_cycle, @prefetch_interval)
  end

  defp cleanup_expired do
    now = System.monotonic_time(:millisecond)

    try do
      :ets.tab2list(@cache_table)
      |> Enum.filter(fn {_key, _value, expires_at} -> expires_at <= now end)
      |> Enum.each(fn {key, _value, _expires} -> :ets.delete(@cache_table, key) end)
    catch
      :error, :badarg -> :ok
    end
  end

  defp enforce_max_size do
    try do
      size = :ets.info(@cache_table, :size)

      if size > @max_cache_size do
        # Remove oldest entries (by expiration time)
        entries = :ets.tab2list(@cache_table)
        sorted = Enum.sort_by(entries, fn {_key, _value, expires_at} -> expires_at end)
        to_remove = Enum.take(sorted, size - @max_cache_size)

        Enum.each(to_remove, fn {key, _value, _expires} ->
          :ets.delete(@cache_table, key)
        end)
      end
    catch
      :error, :badarg -> :ok
    end
  end

  defp process_pending_queries(state) do
    case state.pending_queries do
      [] ->
        state

      queries ->
        # Process in batches
        {to_process, remaining} = Enum.split(queries, @batch_size)

        # Spawn task to do actual prefetching
        spawn(fn ->
          Enum.each(to_process, fn {query, opts} ->
            do_prefetch(query, opts)
          end)
        end)

        %{state | pending_queries: remaining, last_prefetch: DateTime.utc_now()}
    end
  end

  defp do_prefetch(query, opts) do
    sources = Keyword.get(opts, :sources, [:memory, :knowledge])
    _priority = Keyword.get(opts, :priority, :normal)

    # Get predictions from AccessPatternTracker
    predictions =
      case GenServer.whereis(AccessPatternTracker) do
        nil -> %{source_predictions: %{}}
        _pid -> AccessPatternTracker.predict(query)
      end

    # Prefetch from each source based on predictions
    Enum.each(sources, fn source ->
      prefetch_source(source, query, predictions)
    end)
  rescue
    _ -> :ok
  end

  defp prefetch_source(:memory, query, _predictions) do
    # Prefetch from memory
    case Mimo.Brain.Memory.search(query, limit: 5) do
      {:ok, results} when is_list(results) ->
        cache_put(:memory, query, results)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp prefetch_source(:knowledge, query, _predictions) do
    # Prefetch from knowledge graph
    case Mimo.SemanticStore.query_related(query, limit: 5) do
      {:ok, results} when is_list(results) ->
        cache_put(:knowledge, query, results)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp prefetch_source(_source, _query, _predictions) do
    :ok
  end

  defp build_suggestions(query) do
    # Find cached entries that match the query prefix
    try do
      query_lower = String.downcase(query)

      :ets.tab2list(@cache_table)
      |> Enum.filter(fn {{_type, cached_query}, _value, _expires} ->
        is_binary(cached_query) and String.contains?(String.downcase(cached_query), query_lower)
      end)
      |> Enum.map(fn {{type, cached_query}, _value, _expires} ->
        %{source: type, query: cached_query}
      end)
    catch
      :error, :badarg -> []
    end
  end
end
