defmodule Mimo.Skills.FileReadCache do
  @moduledoc """
  SPEC-064: LRU cache for recent file reads.

  Maintains a bounded cache of recently read files to avoid
  redundant filesystem access within short time windows.

  ## Features

  - ETS-backed for fast concurrent reads
  - LRU eviction when cache exceeds max entries
  - Configurable TTL per entry
  - Automatic cleanup of stale entries
  - Size-aware caching (large files can be excluded)

  ## Usage

      # Cache file content after reading
      FileReadCache.put("/path/to/file.ex", content)

      # Get cached content if fresh
      case FileReadCache.get("/path/to/file.ex") do
        {:ok, content, age} -> content  # Cache hit
        {:stale, content, age} -> ...   # Stale but available
        {:miss, nil, nil} -> ...        # Not in cache
      end

  ## Configuration

  Environment variables:
  - `FILE_CACHE_MAX_ENTRIES` - Maximum entries (default: 100)
  - `FILE_CACHE_TTL_SECONDS` - Default TTL (default: 300)
  - `FILE_CACHE_MAX_SIZE_KB` - Max file size to cache (default: 500)
  """

  use GenServer
  require Logger

  @cache_table :file_read_cache
  @max_entries 100
  @default_ttl 300
  @max_file_size_kb 500

  # ============================================================================
  # CLIENT API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Cache file content after reading.

  Returns `:ok` on success, or `{:error, reason}` if caching was skipped.

  Content is not cached if:
  - It exceeds the max file size
  - The cache is not running
  """
  def put(path, content) when is_binary(path) and is_binary(content) do
    # Check file size limit
    size_kb = byte_size(content) / 1024

    if size_kb > max_file_size() do
      {:error, :file_too_large}
    else
      timestamp = System.monotonic_time(:second)
      :ets.insert(@cache_table, {path, content, timestamp})

      # Async cleanup of old entries
      GenServer.cast(__MODULE__, :cleanup)

      :ok
    end
  rescue
    ArgumentError ->
      # ETS table doesn't exist - cache not started
      {:error, :not_started}
  end

  def put(_, _), do: {:error, :invalid_args}

  @doc """
  Get cached content if fresh.

  ## Parameters

  - `path` - File path to look up
  - `max_age` - Maximum age in seconds (default: 300)

  ## Returns

  - `{:ok, content, age}` - Fresh cached content
  - `{:stale, content, age}` - Content exists but is stale
  - `{:miss, nil, nil}` - Not in cache
  """
  def get(path, max_age \\ @default_ttl) when is_binary(path) do
    case :ets.lookup(@cache_table, path) do
      [{^path, content, timestamp}] ->
        age = System.monotonic_time(:second) - timestamp

        if age < max_age do
          {:ok, content, age}
        else
          {:stale, content, age}
        end

      [] ->
        {:miss, nil, nil}
    end
  rescue
    ArgumentError ->
      # ETS table doesn't exist
      {:miss, nil, nil}
  end

  @doc """
  Invalidate cache entry for a specific path.
  Call this when a file is modified.
  """
  def invalidate(path) when is_binary(path) do
    :ets.delete(@cache_table, path)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Invalidate all entries matching a pattern.
  Useful when a directory is modified.
  """
  def invalidate_pattern(pattern) when is_binary(pattern) do
    regex = Regex.compile!(pattern)

    :ets.tab2list(@cache_table)
    |> Enum.filter(fn {path, _, _} -> Regex.match?(regex, path) end)
    |> Enum.each(fn {path, _, _} -> :ets.delete(@cache_table, path) end)

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Clear the entire cache.
  """
  def clear do
    :ets.delete_all_objects(@cache_table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Get cache statistics.
  """
  def stats do
    try do
      entries = :ets.info(@cache_table, :size)
      memory = :ets.info(@cache_table, :memory) * :erlang.system_info(:wordsize)

      %{
        entries: entries,
        memory_bytes: memory,
        memory_kb: Float.round(memory / 1024, 2),
        max_entries: max_entries(),
        utilization: Float.round(entries / max_entries() * 100, 1)
      }
    rescue
      _ ->
        %{entries: 0, memory_bytes: 0, memory_kb: 0.0, max_entries: max_entries(), utilization: 0.0}
    end
  end

  # ============================================================================
  # GENSERVER CALLBACKS
  # ============================================================================

  @impl true
  def init(_opts) do
    # Create ETS table
    :ets.new(@cache_table, [:named_table, :set, :public, read_concurrency: true])

    # Schedule periodic cleanup
    schedule_cleanup()

    Logger.info("FileReadCache started (max: #{max_entries()} entries, TTL: #{default_ttl()}s)")

    {:ok, %{}}
  end

  @impl true
  def handle_cast(:cleanup, state) do
    do_cleanup()
    {:noreply, state}
  end

  @impl true
  def handle_info(:scheduled_cleanup, state) do
    do_cleanup()
    schedule_cleanup()
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ============================================================================
  # PRIVATE
  # ============================================================================

  defp do_cleanup do
    current_size = :ets.info(@cache_table, :size)
    cutoff = System.monotonic_time(:second) - default_ttl()

    # Remove stale entries
    :ets.select_delete(@cache_table, [
      {{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}
    ])

    # If still over limit, remove oldest entries
    if current_size > max_entries() do
      entries_to_remove = current_size - max_entries() + div(max_entries(), 5)

      :ets.tab2list(@cache_table)
      |> Enum.sort_by(fn {_, _, timestamp} -> timestamp end)
      |> Enum.take(entries_to_remove)
      |> Enum.each(fn {path, _, _} -> :ets.delete(@cache_table, path) end)
    end
  rescue
    _ -> :ok
  end

  defp schedule_cleanup do
    # Cleanup every 60 seconds
    Process.send_after(self(), :scheduled_cleanup, 60_000)
  end

  # Configuration helpers with environment variable support
  defp max_entries do
    case System.get_env("FILE_CACHE_MAX_ENTRIES") do
      nil -> @max_entries
      val -> String.to_integer(val)
    end
  rescue
    _ -> @max_entries
  end

  defp default_ttl do
    case System.get_env("FILE_CACHE_TTL_SECONDS") do
      nil -> @default_ttl
      val -> String.to_integer(val)
    end
  rescue
    _ -> @default_ttl
  end

  defp max_file_size do
    case System.get_env("FILE_CACHE_MAX_SIZE_KB") do
      nil -> @max_file_size_kb
      val -> String.to_integer(val)
    end
  rescue
    _ -> @max_file_size_kb
  end
end
