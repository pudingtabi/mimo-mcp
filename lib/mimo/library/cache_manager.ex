defmodule Mimo.Library.CacheManager do
  @moduledoc """
  Manages the tiered cache for package documentation.

  Tiers:
  - Tier 1: Project dependencies (always cached, refreshed on project scan)
  - Tier 2: Popular packages (pre-cached, refreshed weekly)
  - Tier 3: On-demand (LRU cache with size limits)
  """

  use GenServer
  require Logger

  @cache_dir "~/.mimo/library"
  # 1 week
  @default_ttl_hours 168
  @max_cache_size_mb 500
  @name __MODULE__

  # Popular packages to pre-cache
  @popular_packages %{
    hex:
      ~w(phoenix ecto plug jason req tesla oban broadway genserver absinthe guardian ex_unit mix),
    pypi: ~w(requests numpy pandas flask django fastapi pytest sqlalchemy pydantic aiohttp),
    npm: ~w(express react next lodash axios typescript jest webpack vite eslint prettier)
  }

  defstruct cache_dir: nil,
            stats: %{hits: 0, misses: 0, size_bytes: 0}

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  Get cached package data.
  """
  @spec get(String.t(), atom(), String.t() | nil) :: {:ok, map()} | {:error, :not_found | :expired}
  def get(name, ecosystem, version \\ nil) do
    GenServer.call(@name, {:get, name, ecosystem, version})
  end

  @doc """
  Store package data in cache.
  """
  @spec put(String.t(), atom(), map(), keyword()) :: :ok
  def put(name, ecosystem, data, opts \\ []) do
    GenServer.cast(@name, {:put, name, ecosystem, data, opts})
  end

  @doc """
  Check if package is cached and not expired.
  """
  @spec cached?(String.t(), atom()) :: boolean()
  def cached?(name, ecosystem) do
    GenServer.call(@name, {:cached?, name, ecosystem})
  end

  @doc """
  Invalidate cached package.
  """
  @spec invalidate(String.t(), atom()) :: :ok
  def invalidate(name, ecosystem) do
    GenServer.cast(@name, {:invalidate, name, ecosystem})
  end

  @doc """
  Get cache statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(@name, :stats)
  end

  @doc """
  Clean up expired entries and enforce size limits.
  """
  @spec cleanup() :: {:ok, non_neg_integer()}
  def cleanup do
    GenServer.call(@name, :cleanup, 60_000)
  end

  @doc """
  Get list of popular packages for pre-caching.
  """
  @spec popular_packages(atom()) :: [String.t()]
  def popular_packages(ecosystem) do
    Map.get(@popular_packages, ecosystem, [])
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    cache_dir = Path.expand(@cache_dir)
    File.mkdir_p!(cache_dir)

    # Initialize ETS tables for hot cache
    :ets.new(:library_cache_hot, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(:library_cache_meta, [:named_table, :set, :public, read_concurrency: true])

    # Schedule periodic cleanup
    schedule_cleanup()

    {:ok, %__MODULE__{cache_dir: cache_dir}}
  end

  @impl true
  def handle_call({:get, name, ecosystem, version}, _from, state) do
    key = cache_key(name, ecosystem, version)

    case :ets.lookup(:library_cache_hot, key) do
      [{^key, data, expires_at}] ->
        if DateTime.compare(DateTime.utc_now(), expires_at) == :lt do
          # Update access time
          update_access_time(key)
          new_stats = %{state.stats | hits: state.stats.hits + 1}
          {:reply, {:ok, data}, %{state | stats: new_stats}}
        else
          # Expired
          :ets.delete(:library_cache_hot, key)
          new_stats = %{state.stats | misses: state.stats.misses + 1}
          {:reply, {:error, :expired}, %{state | stats: new_stats}}
        end

      [] ->
        # Try disk cache
        case read_from_disk(state.cache_dir, key) do
          {:ok, data, expires_at} ->
            if DateTime.compare(DateTime.utc_now(), expires_at) == :lt do
              # Promote to hot cache
              :ets.insert(:library_cache_hot, {key, data, expires_at})
              update_access_time(key)
              new_stats = %{state.stats | hits: state.stats.hits + 1}
              {:reply, {:ok, data}, %{state | stats: new_stats}}
            else
              new_stats = %{state.stats | misses: state.stats.misses + 1}
              {:reply, {:error, :expired}, %{state | stats: new_stats}}
            end

          {:error, _} ->
            new_stats = %{state.stats | misses: state.stats.misses + 1}
            {:reply, {:error, :not_found}, %{state | stats: new_stats}}
        end
    end
  end

  def handle_call({:cached?, name, ecosystem}, _from, state) do
    key = cache_key(name, ecosystem, nil)

    result =
      case :ets.lookup(:library_cache_hot, key) do
        [{^key, _data, expires_at}] ->
          DateTime.compare(DateTime.utc_now(), expires_at) == :lt

        [] ->
          case read_meta_from_disk(state.cache_dir, key) do
            {:ok, meta} ->
              DateTime.compare(DateTime.utc_now(), meta.expires_at) == :lt

            _ ->
              false
          end
      end

    {:reply, result, state}
  end

  def handle_call(:stats, _from, state) do
    hot_count = :ets.info(:library_cache_hot, :size)

    stats = %{
      hot_cache_entries: hot_count,
      hits: state.stats.hits,
      misses: state.stats.misses,
      hit_rate:
        if state.stats.hits + state.stats.misses > 0 do
          state.stats.hits / (state.stats.hits + state.stats.misses) * 100
        else
          0.0
        end,
      cache_dir: state.cache_dir
    }

    {:reply, stats, state}
  end

  def handle_call(:cleanup, _from, state) do
    count = do_cleanup(state.cache_dir)
    {:reply, {:ok, count}, state}
  end

  @impl true
  def handle_cast({:put, name, ecosystem, data, opts}, state) do
    key = cache_key(name, ecosystem, opts[:version])
    ttl_hours = opts[:ttl] || @default_ttl_hours
    expires_at = DateTime.add(DateTime.utc_now(), ttl_hours * 3600, :second)
    tier = opts[:tier] || 3

    # Store in hot cache
    :ets.insert(:library_cache_hot, {key, data, expires_at})

    # Store metadata
    meta = %{
      name: name,
      ecosystem: ecosystem,
      version: opts[:version],
      tier: tier,
      expires_at: expires_at,
      cached_at: DateTime.utc_now(),
      last_accessed: DateTime.utc_now()
    }

    :ets.insert(:library_cache_meta, {key, meta})

    # Write to disk for persistence
    write_to_disk(state.cache_dir, key, data, meta)

    {:noreply, state}
  end

  def handle_cast({:invalidate, name, ecosystem}, state) do
    key = cache_key(name, ecosystem, nil)
    :ets.delete(:library_cache_hot, key)
    :ets.delete(:library_cache_meta, key)
    delete_from_disk(state.cache_dir, key)
    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    do_cleanup(state.cache_dir)
    schedule_cleanup()
    {:noreply, state}
  end

  # Private helpers

  defp cache_key(name, ecosystem, nil), do: "#{ecosystem}/#{name}"
  defp cache_key(name, ecosystem, version), do: "#{ecosystem}/#{name}@#{version}"

  defp update_access_time(key) do
    case :ets.lookup(:library_cache_meta, key) do
      [{^key, meta}] ->
        :ets.insert(:library_cache_meta, {key, %{meta | last_accessed: DateTime.utc_now()}})

      [] ->
        :ok
    end
  end

  defp read_from_disk(cache_dir, key) do
    path = Path.join(cache_dir, "#{safe_filename(key)}.json")

    with {:ok, content} <- File.read(path),
         {:ok, cached} <- Jason.decode(content),
         {:ok, expires_at, _offset} <- DateTime.from_iso8601(cached["expires_at"]) do
      {:ok, cached["data"], expires_at}
    end
  end

  defp read_meta_from_disk(cache_dir, key) do
    path = Path.join(cache_dir, "#{safe_filename(key)}.meta.json")

    with {:ok, content} <- File.read(path),
         {:ok, meta} <- Jason.decode(content),
         {:ok, expires_at, _offset} <- DateTime.from_iso8601(meta["expires_at"]) do
      {:ok, %{expires_at: expires_at}}
    end
  end

  defp write_to_disk(cache_dir, key, data, meta) do
    filename = safe_filename(key)
    data_path = Path.join(cache_dir, "#{filename}.json")
    meta_path = Path.join(cache_dir, "#{filename}.meta.json")

    # Ensure directory exists
    File.mkdir_p!(Path.dirname(data_path))

    cached = %{
      "data" => data,
      "expires_at" => DateTime.to_iso8601(meta.expires_at),
      "cached_at" => DateTime.to_iso8601(meta.cached_at)
    }

    # Convert meta to serializable format (DateTime to ISO8601 strings)
    serializable_meta = %{
      name: meta.name,
      ecosystem: meta.ecosystem,
      version: meta.version,
      tier: meta.tier,
      expires_at: DateTime.to_iso8601(meta.expires_at),
      cached_at: DateTime.to_iso8601(meta.cached_at),
      last_accessed: DateTime.to_iso8601(meta.last_accessed)
    }

    File.write!(data_path, Jason.encode!(cached))
    File.write!(meta_path, Jason.encode!(serializable_meta, pretty: true))
  rescue
    e ->
      Logger.warning("Failed to write cache to disk: #{inspect(e)}")
  end

  defp delete_from_disk(cache_dir, key) do
    filename = safe_filename(key)
    File.rm(Path.join(cache_dir, "#{filename}.json"))
    File.rm(Path.join(cache_dir, "#{filename}.meta.json"))
  end

  defp safe_filename(key) do
    key
    |> String.replace("/", "_")
    |> String.replace("@", "_at_")
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")
  end

  defp do_cleanup(cache_dir) do
    now = DateTime.utc_now()

    # Clean hot cache
    expired_hot =
      :ets.tab2list(:library_cache_hot)
      |> Enum.filter(fn {_key, _data, expires_at} ->
        DateTime.compare(now, expires_at) != :lt
      end)
      |> Enum.map(fn {key, _, _} -> key end)

    Enum.each(expired_hot, &:ets.delete(:library_cache_hot, &1))

    # Clean metadata
    Enum.each(expired_hot, &:ets.delete(:library_cache_meta, &1))

    # Clean disk cache
    Enum.each(expired_hot, &delete_from_disk(cache_dir, &1))

    # Check total size and evict LRU if needed
    enforce_size_limit(cache_dir)

    length(expired_hot)
  end

  defp enforce_size_limit(cache_dir) do
    max_size = @max_cache_size_mb * 1024 * 1024

    files =
      Path.wildcard(Path.join(cache_dir, "*.json"))
      |> Enum.map(fn path ->
        stat = File.stat!(path)
        {path, stat.size, stat.mtime}
      end)

    total_size = Enum.reduce(files, 0, fn {_, size, _}, acc -> acc + size end)

    if total_size > max_size do
      # Sort by mtime (oldest first) and delete until under limit
      files
      |> Enum.sort_by(fn {_, _, mtime} -> mtime end)
      |> Enum.reduce_while(total_size, fn {path, size, _}, current_size ->
        if current_size > max_size do
          File.rm(path)
          {:cont, current_size - size}
        else
          {:halt, current_size}
        end
      end)
    end
  end

  defp schedule_cleanup do
    # Run cleanup every hour
    Process.send_after(self(), :cleanup, 60 * 60 * 1000)
  end
end
