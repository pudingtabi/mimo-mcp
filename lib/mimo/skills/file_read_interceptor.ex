defmodule Mimo.Skills.FileReadInterceptor do
  @moduledoc """
  SPEC-064: Structural intervention for memory-first file access.

  Intercepts file read operations and checks memory/cache before
  hitting the filesystem. Returns cached content when available,
  reducing redundant reads and token usage.

  ## How It Works

  1. When a file read is requested, this interceptor checks:
     - Memory store for cached content (semantic similarity)
     - Symbol index for file structure
     - LRU cache for recent reads

  2. Based on hit quality, it returns:
     - `{:memory_hit, content, metadata}` - Content from memory, skip file read
     - `{:cache_hit, content, metadata}` - Content from LRU cache
     - `{:symbol_hit, symbols, suggestion}` - Structure available, suggest symbol read
     - `{:partial_hit, hints, :proceed}` - Some context, but read file
     - `{:miss, :proceed}` - No relevant cache, proceed with read

  ## Stats Tracking

  All interception results are tracked in ETS for monitoring:
  - `memory_hit` - Content served from memory
  - `cache_hit` - Content served from LRU cache
  - `symbol_suggestion` - Suggested symbol-based read
  - `partial_hit` - Hints provided but file still read
  - `miss` - No cached content found
  - `bypass` - Interception explicitly skipped
  """

  alias Mimo.Brain.Memory
  alias Mimo.Code.SymbolIndex

  require Logger

  # Thresholds for memory hit decisions
  @memory_similarity_threshold 0.75
  @high_confidence_threshold 0.85
  @content_recency_seconds 3_600

  # ETS table for stats tracking
  @stats_table :file_interception_stats

  # ============================================================================
  # PUBLIC API
  # ============================================================================

  @doc """
  Initialize the interception system.
  Creates ETS tables for stats tracking.
  """
  def init do
    # Create stats table if it doesn't exist
    if :ets.whereis(@stats_table) == :undefined do
      :ets.new(@stats_table, [:named_table, :set, :public, read_concurrency: true])
      :ets.insert(@stats_table, {:total, 0})
      :ets.insert(@stats_table, {:memory_hit, 0})
      :ets.insert(@stats_table, {:cache_hit, 0})
      :ets.insert(@stats_table, {:symbol_suggestion, 0})
      :ets.insert(@stats_table, {:partial_hit, 0})
      :ets.insert(@stats_table, {:miss, 0})
      :ets.insert(@stats_table, {:bypass, 0})
      :ok
    else
      :already_initialized
    end
  end

  @doc """
  Intercept a file read request.

  ## Options

  - `:skip_interception` - If true, bypass interception entirely
  - `:max_age` - Maximum age in seconds for cache hits (default: 300)

  ## Returns

  - `{:memory_hit, content, metadata}` - Content from memory, skip file read
  - `{:cache_hit, content, metadata}` - Content from LRU cache
  - `{:symbol_hit, symbols, metadata}` - Structure available, suggest symbol read
  - `{:partial_hit, hints, :proceed}` - Some context, but read file
  - `{:miss, :proceed}` - No relevant cache, proceed with read
  """
  def intercept(path, opts \\ []) do
    # Ensure stats table exists
    ensure_stats_table()

    # Skip interception if explicitly disabled
    if Keyword.get(opts, :skip_interception, false) do
      track_stat(:bypass)
      {:miss, :proceed}
    else
      do_intercept(path, opts)
    end
  end

  @doc """
  Get interception statistics.

  Returns a map with:
  - `total_intercepts` - Total interception attempts
  - `memory_hits` - Content served from memory
  - `cache_hits` - Content served from LRU cache
  - `symbol_suggestions` - Symbol-based read suggestions
  - `partial_hits` - Hints provided but file read
  - `misses` - No cached content
  - `bypasses` - Interception skipped
  - `hit_rate` - Percentage of successful cache hits
  """
  def stats do
    ensure_stats_table()

    total = get_stat(:total)

    %{
      total_intercepts: total,
      memory_hits: get_stat(:memory_hit),
      cache_hits: get_stat(:cache_hit),
      symbol_suggestions: get_stat(:symbol_suggestion),
      partial_hits: get_stat(:partial_hit),
      misses: get_stat(:miss),
      bypasses: get_stat(:bypass),
      hit_rate: calculate_hit_rate(total),
      savings_estimate: estimate_token_savings(total)
    }
  end

  @doc """
  Reset statistics to zero.
  """
  def reset_stats do
    ensure_stats_table()

    :ets.insert(@stats_table, {:total, 0})
    :ets.insert(@stats_table, {:memory_hit, 0})
    :ets.insert(@stats_table, {:cache_hit, 0})
    :ets.insert(@stats_table, {:symbol_suggestion, 0})
    :ets.insert(@stats_table, {:partial_hit, 0})
    :ets.insert(@stats_table, {:miss, 0})
    :ets.insert(@stats_table, {:bypass, 0})
    :ok
  end

  # ============================================================================
  # PRIVATE: INTERCEPTION LOGIC
  # ============================================================================

  defp do_intercept(path, opts) do
    max_age = Keyword.get(opts, :max_age, 300)

    # Run checks in parallel with timeout
    tasks = [
      Task.async(fn -> check_memory_content(path) end),
      Task.async(fn -> check_symbol_cache(path) end),
      Task.async(fn -> check_recent_reads(path, max_age) end)
    ]

    # Wait for all tasks with 5s timeout
    results =
      try do
        Task.await_many(tasks, 5000)
      rescue
        _ ->
          # On timeout, kill tasks and return misses
          Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
          [{:miss, nil}, {:miss, nil}, {:miss, nil}]
      end

    [memory_result, symbol_result, cache_result] = results

    decide(path, memory_result, symbol_result, cache_result, opts)
  end

  # Check if memory has cached content for this file
  defp check_memory_content(path) do
    filename = Path.basename(path)
    query = "file content #{filename} #{path}"

    case Memory.search(query, limit: 3, threshold: @memory_similarity_threshold) do
      {:ok, %{results: results}} when is_list(results) and length(results) > 0 ->
        # Find most relevant result with recency check
        results
        |> Enum.filter(&content_is_recent?/1)
        |> Enum.max_by(&Map.get(&1, :score, 0), fn -> nil end)
        |> case do
          nil -> {:miss, nil}
          hit -> {:hit, hit}
        end

      _ ->
        {:miss, nil}
    end
  rescue
    e ->
      Logger.debug("FileReadInterceptor memory check failed: #{inspect(e)}")
      {:miss, nil}
  end

  defp content_is_recent?(%{inserted_at: inserted_at}) when not is_nil(inserted_at) do
    age_seconds = DateTime.diff(DateTime.utc_now(), inserted_at, :second)
    age_seconds < @content_recency_seconds
  end

  defp content_is_recent?(%{created_at: created_at}) when not is_nil(created_at) do
    age_seconds = DateTime.diff(DateTime.utc_now(), created_at, :second)
    age_seconds < @content_recency_seconds
  end

  defp content_is_recent?(_), do: false

  # Check if we have symbol structure cached
  defp check_symbol_cache(path) do
    case SymbolIndex.symbols_in_file(path) do
      {:ok, symbols} when is_list(symbols) and length(symbols) > 0 ->
        {:hit, symbols}

      _ ->
        {:miss, nil}
    end
  rescue
    e ->
      Logger.debug("FileReadInterceptor symbol check failed: #{inspect(e)}")
      {:miss, nil}
  end

  # Check in-memory LRU cache of recent reads
  defp check_recent_reads(path, max_age) do
    case Mimo.Skills.FileReadCache.get(path, max_age) do
      {:ok, content, age} ->
        {:hit, %{content: content, age: age}}

      {:stale, content, age} ->
        {:stale, %{content: content, age: age}}

      {:miss, _, _} ->
        {:miss, nil}
    end
  rescue
    # Cache might not be running yet
    _ -> {:miss, nil}
  end

  # Decision engine: prioritize by quality of hit
  defp decide(_path, memory_result, symbol_result, cache_result, _opts) do
    case {memory_result, symbol_result, cache_result} do
      # Strong memory hit with high similarity → return from memory
      {{:hit, %{score: score, content: content}}, _, _} when score >= @high_confidence_threshold ->
        track_stat(:memory_hit)

        {:memory_hit, content,
         %{
           source: :memory,
           similarity: score,
           suggestion: "Content retrieved from memory (#{Float.round(score * 100, 1)}% match)."
         }}

      # Recent cache hit → return from cache
      {_, _, {:hit, %{content: content, age: age}}} ->
        track_stat(:cache_hit)

        {:cache_hit, content,
         %{
           source: :lru_cache,
           age_seconds: age,
           suggestion: "File read from cache (#{age}s old)."
         }}

      # Symbol structure available → suggest targeted read
      {_, {:hit, symbols}, _} ->
        track_stat(:symbol_suggestion)
        symbol_count = length(symbols)

        {:symbol_hit, symbols,
         %{
           symbols: symbol_count,
           suggestion:
             "File has #{symbol_count} symbols indexed. Consider `file operation=read_symbol` for specific function."
         }}

      # Partial memory hit (lower similarity) → include as hint
      {{:hit, %{score: score, content: content}}, _, _} when score >= 0.6 ->
        track_stat(:partial_hit)

        {:partial_hit,
         %{
           memory_hint: String.slice(content || "", 0..200),
           similarity: score,
           suggestion:
             "Related memory found (#{Float.round(score * 100, 1)}% match). Proceeding with file read."
         }, :proceed}

      # Stale cache → proceed but note it
      {_, _, {:stale, _}} ->
        track_stat(:miss)
        {:miss, :proceed}

      # No hits → standard file read
      _ ->
        track_stat(:miss)
        {:miss, :proceed}
    end
  end

  # ============================================================================
  # PRIVATE: STATS TRACKING
  # ============================================================================

  defp ensure_stats_table do
    if :ets.whereis(@stats_table) == :undefined do
      init()
    end
  end

  defp track_stat(type) do
    try do
      :ets.update_counter(@stats_table, type, {2, 1}, {type, 0})
      :ets.update_counter(@stats_table, :total, {2, 1}, {:total, 0})
    rescue
      ArgumentError -> :ok
    end
  end

  defp get_stat(key) do
    case :ets.lookup(@stats_table, key) do
      [{^key, count}] -> count
      _ -> 0
    end
  rescue
    _ -> 0
  end

  defp calculate_hit_rate(0), do: 0.0

  defp calculate_hit_rate(total) do
    hits = get_stat(:memory_hit) + get_stat(:cache_hit)
    Float.round(hits / total * 100, 1)
  end

  # Estimate token savings based on hit rate
  # Assume average file read costs ~1500 tokens
  defp estimate_token_savings(total) do
    hits = get_stat(:memory_hit) + get_stat(:cache_hit)
    avg_tokens_per_file = 1500
    %{
      files_avoided: hits,
      tokens_saved: hits * avg_tokens_per_file,
      total_intercepts: total
    }
  end
end
