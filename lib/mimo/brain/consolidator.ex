defmodule Mimo.Brain.Consolidator do
  @moduledoc """
  Memory consolidation system - transfers working memory to long-term storage.

  Implements biologically-inspired memory consolidation that:
  1. Monitors working memory for consolidation candidates
  2. Scores memories based on importance, recurrence, and novelty
  3. Generates embeddings for vector search
  4. Stores consolidated memories in long-term (SQLite)
  5. Removes consolidated items from working memory

  ## Consolidation Criteria

    - Memory age exceeds TTL
    - Memory marked as consolidation candidate
    - Consolidation score above threshold
    - Periodic sweep (during quiet periods)

  ## Configuration

      config :mimo_mcp, :consolidation,
        enabled: true,
        interval_ms: 60_000,       # Check every minute
        score_threshold: 0.3,     # Consolidate above this score
        min_age_ms: 30_000        # Must be at least 30s old

  ## Examples

      # Force immediate consolidation
      {:ok, count} = Consolidator.consolidate_now()

      # Get consolidation stats
      stats = Consolidator.stats()

      # Mark memory for consolidation
      Consolidator.mark_for_consolidation(memory_id)
  """
  use GenServer
  require Logger

  alias SafeMemory
  alias Mimo.Brain.{LLM, Memory}
  alias Mimo.SafeCall

  @default_interval 60_000
  @default_score_threshold 0.3
  @default_min_age_ms 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Trigger immediate consolidation cycle.

  ## Options

    * `:force` - Consolidate all candidates regardless of score (default: false)
    * `:score_threshold` - Override config threshold

  ## Returns

    * `{:ok, count}` - Number of memories consolidated
    * `{:error, :unavailable}` - Consolidator not running
  """
  @spec consolidate_now(keyword()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def consolidate_now(opts \\ []) do
    SafeCall.genserver(__MODULE__, {:consolidate, opts},
      timeout: 120_000,
      raw: true,
      fallback: {:ok, 0}
    )
  end

  @doc """
  Get consolidation statistics.
  Returns empty stats if consolidator is unavailable.
  """
  @spec stats() :: map()
  def stats do
    SafeCall.genserver(__MODULE__, :stats,
      raw: true,
      fallback: %{status: :unavailable, consolidated: 0}
    )
  end

  @doc """
  Calculate consolidation score for a working memory item.

  Score based on:
  - Importance (40%)
  - Recurrence/access (30%)
  - Novelty (20%)
  - Age (10%)
  """
  @spec calculate_score(map()) :: float()
  def calculate_score(%{} = item) do
    importance_score = Map.get(item, :importance, 0.5) * 0.4
    access_score = min(1.0, Map.get(item, :access_count, 1) / 10) * 0.3

    # Novelty score - higher for unique content
    novelty_score = calculate_novelty(item) * 0.2

    # Age score - older is slightly more likely to consolidate
    age_score = calculate_age_score(item) * 0.1

    importance_score + access_score + novelty_score + age_score
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, get_config(:interval_ms, @default_interval))

    state = %{
      last_run: nil,
      total_consolidated: 0,
      last_batch_count: 0,
      interval: interval,
      failures: 0
    }

    if get_config(:enabled, true) do
      schedule_run(interval)
    end

    Logger.info("Consolidator initialized (interval: #{interval}ms)")
    {:ok, state}
  end

  @impl true
  def handle_call({:consolidate, opts}, _from, state) do
    {count, new_state} = run_consolidation(state, opts)
    {:reply, {:ok, count}, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats =
      Map.take(state, [:last_run, :total_consolidated, :last_batch_count, :failures])
      |> Map.put(:interval_ms, state.interval)
      |> Map.put(:enabled, get_config(:enabled, true))
      |> Map.put(:score_threshold, get_config(:score_threshold, @default_score_threshold))

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:consolidate, state) do
    {_count, new_state} = run_consolidation(state, [])
    schedule_run(state.interval)
    {:noreply, new_state}
  end

  defp run_consolidation(state, opts) do
    force = Keyword.get(opts, :force, false)
    threshold = opts[:score_threshold] || get_config(:score_threshold, @default_score_threshold)
    min_age_ms = get_config(:min_age_ms, @default_min_age_ms)

    :telemetry.execute([:mimo, :memory, :consolidation, :started], %{}, %{force: force})

    # Get candidates from working memory (via SafeMemory for resilience)
    candidates = Mimo.Brain.SafeMemory.get_consolidation_candidates()

    # Filter by age and score
    now = DateTime.utc_now()

    to_consolidate =
      candidates
      |> Enum.filter(fn item ->
        age_ms = DateTime.diff(now, item.created_at, :millisecond)
        score = calculate_score(item)

        old_enough = age_ms >= min_age_ms
        score_ok = force or score >= threshold

        old_enough and score_ok
      end)
      |> Enum.sort_by(&calculate_score/1, :desc)
      |> Enum.take(50)

    # Consolidate each memory
    {successes, failures} =
      Enum.reduce(to_consolidate, {0, 0}, fn item, {s, f} ->
        case consolidate_item(item) do
          :ok -> {s + 1, f}
          {:error, _} -> {s, f + 1}
        end
      end)

    :telemetry.execute(
      [:mimo, :memory, :consolidation, :completed],
      %{consolidated: successes, failed: failures},
      %{candidates: length(candidates), threshold: threshold}
    )

    if successes > 0 do
      Logger.info("Consolidation complete: #{successes} memories consolidated, #{failures} failed")
    end

    new_state = %{
      state
      | last_run: DateTime.utc_now(),
        total_consolidated: state.total_consolidated + successes,
        last_batch_count: successes,
        failures: state.failures + failures
    }

    {successes, new_state}
  end

  defp consolidate_item(item) do
    try do
      # Generate embedding for vector search
      embedding =
        case LLM.generate_embedding(item.content) do
          {:ok, emb} -> emb
          _ -> nil
        end

      # Prepare metadata
      metadata =
        Map.get(item, :metadata, %{})
        |> Map.put("source", "working_memory")
        |> Map.put("original_created", DateTime.to_iso8601(item.created_at))
        |> Map.put("consolidation_score", Float.round(calculate_score(item), 3))

      # Persist to long-term memory
      case Memory.persist_memory(
             item.content,
             item.category,
             item.importance,
             embedding,
             metadata
           ) do
        {:ok, _engram} ->
          # Remove from working memory (via SafeMemory for resilience)
          Mimo.Brain.SafeMemory.delete(item.id)

          :telemetry.execute(
            [:mimo, :memory, :consolidated],
            %{score: calculate_score(item)},
            %{key: item.key, category: item.category}
          )

          :ok

        error ->
          Logger.error("Failed to persist memory: #{inspect(error)}")
          error
      end
    rescue
      e in DBConnection.OwnershipError ->
        Logger.debug(
          "[Consolidator] Skipping consolidation (sandbox mode): #{Exception.message(e)}"
        )

        {:error, :sandbox_mode}

      e in DBConnection.ConnectionError ->
        Logger.debug("[Consolidator] Skipping consolidation (connection): #{Exception.message(e)}")
        {:error, :sandbox_mode}

      e ->
        Logger.error("Consolidation error: #{Exception.message(e)}")
        {:error, e}
    end
  end

  defp calculate_novelty(%{content: content}) do
    # Compare against existing memories to assess true novelty
    # Search for similar content in long-term memory
    case Memory.search_memories(content, limit: 5, min_similarity: 0.5) do
      similar_memories when is_list(similar_memories) and similar_memories != [] ->
        # Calculate novelty based on max similarity to existing memories
        max_similarity =
          similar_memories
          |> Enum.map(fn m -> Map.get(m, :similarity, 0.5) end)
          |> Enum.max(fn -> 0.0 end)

        # Higher similarity = lower novelty (inverse relationship)
        # 0.9 similarity -> 0.1 novelty, 0.5 similarity -> 0.5 novelty
        novelty = 1.0 - max_similarity

        # Also factor in unique word ratio for additional signal
        word_count = content |> String.split() |> length()

        unique_ratio =
          content |> String.split() |> Enum.uniq() |> length() |> Kernel./(max(1, word_count))

        # Blend memory-based novelty (60%) with word uniqueness (40%)
        min(1.0, novelty * 0.6 + unique_ratio * 0.4)

      _ ->
        # No similar memories found = high novelty
        # Still factor in word uniqueness
        word_count = content |> String.split() |> length()

        unique_ratio =
          content |> String.split() |> Enum.uniq() |> length() |> Kernel./(max(1, word_count))

        min(1.0, 0.8 + unique_ratio * 0.2)
    end
  rescue
    _ ->
      # Fallback to simple word uniqueness if search fails
      word_count = content |> String.split() |> length()

      unique_ratio =
        content |> String.split() |> Enum.uniq() |> length() |> Kernel./(max(1, word_count))

      min(1.0, unique_ratio * 1.2)
  end

  defp calculate_novelty(_), do: 0.5

  defp calculate_age_score(%{created_at: created_at}) do
    age_seconds = DateTime.diff(DateTime.utc_now(), created_at, :second)
    min(1.0, age_seconds / 300)
  end

  defp calculate_age_score(_), do: 0.5

  defp schedule_run(interval) do
    Process.send_after(self(), :consolidate, interval)
  end

  defp get_config(key, default) do
    Application.get_env(:mimo_mcp, :consolidation, [])
    |> Keyword.get(key, default)
  end
end
