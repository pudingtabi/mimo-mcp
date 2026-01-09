defmodule Mimo.Brain.AccessTracker do
  @moduledoc """
  Tracks memory access patterns for decay scoring and analysis.

  Updates access_count and last_accessed_at when memories are retrieved.
  Uses batched async updates to avoid impacting read performance.

  ## Neuroscience Foundation: Spacing Effect

  This module implements the **spacing effect** from memory research:
  - Each memory retrieval reduces the decay rate by 5%
  - Frequently accessed memories decay much slower than rarely accessed ones
  - This mirrors biological memory consolidation through repeated retrieval

  Reference: Ebbinghaus forgetting curve, Karpicke & Roediger (2008) spaced retrieval

  ## Neuroscience Foundation: Hebbian Co-Activation

  This module also tracks **co-activation** for Hebbian learning:
  - "Neurons that fire together, wire together" (Hebb, 1949)
  - Memories accessed together in the same session form associations
  - Co-activation data is emitted via telemetry for edge strengthening

  Reference: Hebb (1949) The Organization of Behavior

  ## Decay Rate Examples

  | Accesses | Decay Rate Factor | Effective Half-Life |
  |----------|-------------------|---------------------|
  | 0        | 1.0 (default)     | ~69 days            |
  | 10       | 0.60              | ~115 days           |
  | 50       | 0.08              | ~865 days           |
  | 100      | 0.006 (clamped)   | ~693 days (max)     |

  ## Features

    - Async access tracking (non-blocking reads)
    - Batch updates for efficiency
    - Spacing effect decay reduction
    - Hebbian co-activation tracking
    - Access pattern analytics
    - Telemetry integration

  ## Examples

      # Track single access
      AccessTracker.track(memory_id)

      # Track multiple accesses
      AccessTracker.track_many([id1, id2, id3])

      # Get access stats
      stats = AccessTracker.stats()
  """
  use GenServer
  require Logger

  import Ecto.Query
  alias Mimo.{Brain.Engram, Repo}
  alias Mimo.SafeCall

  @flush_interval 5_000
  @batch_size 100
  # Each memory retrieval reduces the decay rate, implementing the spacing effect:
  # "Memories that are retrieved more often decay more slowly"
  # Reference: Ebbinghaus forgetting curve, spaced repetition research
  # 5% reduction per access
  @decay_reduction_factor 0.95
  # Floor to prevent zero decay (693 day half-life)
  @min_decay_rate 0.0001
  # Track memories accessed together for "fire together, wire together"
  # Co-activation window: memories accessed within this time window are linked
  # 30 seconds
  @coactivation_window_ms 30_000
  # Auto-protect threshold: memories accessed this many times get protected from decay
  @auto_protect_threshold 10
  # Minimum importance for auto-protection (prevents protecting garbage)
  @auto_protect_min_importance 0.5

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Track access to a memory. Non-blocking async operation.
  """
  @spec track(integer() | String.t()) :: :ok
  def track(memory_id) do
    GenServer.cast(__MODULE__, {:track, memory_id})
  end

  @doc """
  Track access to multiple memories. Non-blocking async operation.
  """
  @spec track_many([integer() | String.t()]) :: :ok
  def track_many(memory_ids) when is_list(memory_ids) do
    Enum.each(memory_ids, &track/1)
    :ok
  end

  @doc """
  Force immediate flush of pending access updates.
  Returns :ok or :unavailable if tracker not running.
  """
  @spec flush() :: :ok | {:error, :unavailable}
  def flush do
    SafeCall.genserver(__MODULE__, :flush,
      raw: true,
      fallback: :ok
    )
  end

  @doc """
  Get tracking statistics.
  Returns empty stats if tracker unavailable.
  """
  @spec stats() :: map()
  def stats do
    SafeCall.genserver(__MODULE__, :stats,
      raw: true,
      fallback: %{status: :unavailable, total_tracked: 0}
    )
  end

  @impl true
  def init(_opts) do
    schedule_flush()

    state = %{
      pending: %{},
      total_tracked: 0,
      total_flushed: 0,
      # Hebbian co-activation: track recent accesses with timestamps
      # Format: [{memory_id, timestamp_ms}, ...]
      recent_accesses: []
    }

    Logger.info("AccessTracker initialized with Hebbian co-activation tracking")
    {:ok, state}
  end

  @impl true
  def handle_cast({:track, memory_id}, state) do
    now_ms = System.monotonic_time(:millisecond)

    # Increment pending access count for this memory
    new_pending = Map.update(state.pending, memory_id, 1, &(&1 + 1))

    # Hebbian co-activation: find memories accessed within the window
    # and emit co-activation events
    coactivated_ids = find_coactivated_memories(state.recent_accesses, memory_id, now_ms)
    emit_coactivation_events(memory_id, coactivated_ids)

    # Update recent_accesses: add current access, prune old ones
    new_recent = prune_old_accesses([{memory_id, now_ms} | state.recent_accesses], now_ms)

    new_state = %{
      state
      | pending: new_pending,
        total_tracked: state.total_tracked + 1,
        recent_accesses: new_recent
    }

    # Auto-flush if batch gets too large
    new_state =
      if map_size(new_state.pending) >= @batch_size do
        do_flush(new_state)
      else
        new_state
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    new_state = do_flush(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      pending_count: map_size(state.pending),
      pending_accesses: Enum.sum(Map.values(state.pending)),
      total_tracked: state.total_tracked,
      total_flushed: state.total_flushed
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:flush, state) do
    new_state = do_flush(state)
    schedule_flush()
    {:noreply, new_state}
  end

  defp do_flush(%{pending: pending} = state) when map_size(pending) == 0 do
    state
  end

  defp do_flush(%{pending: pending} = state) do
    now = NaiveDateTime.utc_now()
    ids = Map.keys(pending)

    # Group IDs by increment value for batched updates
    # Most accesses are +1, so this batches efficiently
    by_increment =
      pending
      |> Enum.group_by(fn {_id, increment} -> increment end, fn {id, _increment} -> id end)

    # Batch update each increment group with a single query
    # Implements spacing effect: each access reduces decay_rate
    Enum.each(by_increment, fn {increment, id_list} ->
      # Calculate decay reduction factor for this batch
      # decay_rate = decay_rate * 0.95^increment (clamped to min)
      decay_factor = :math.pow(@decay_reduction_factor, increment)

      from(e in Engram,
        where: e.id in ^id_list,
        update: [
          set: [
            access_count: coalesce(e.access_count, 0) + ^increment,
            last_accessed_at: ^now,
            # Spacing Effect: reduce decay rate on each access
            # MAX ensures we don't go below minimum decay rate
            decay_rate:
              fragment(
                "MAX(?, COALESCE(decay_rate, 0.01) * ?)",
                ^@min_decay_rate,
                ^decay_factor
              )
          ]
        ]
      )
      |> Repo.update_all([])

      # Auto-protect frequently accessed valuable memories
      # This prevents Forgetting from deleting memories users actually use
      {protected_count, _} =
        from(e in Engram,
          where: e.id in ^id_list,
          where: e.access_count >= ^@auto_protect_threshold,
          where: e.importance >= ^@auto_protect_min_importance,
          where: e.protected == false or is_nil(e.protected)
        )
        |> Repo.update_all(set: [protected: true])

      if protected_count > 0 do
        Logger.info("Auto-protected #{protected_count} frequently accessed memories")
      end
    end)

    flush_count = map_size(pending)

    :telemetry.execute(
      [:mimo, :memory, :access_tracked],
      %{count: flush_count, accesses: Enum.sum(Map.values(pending))},
      %{ids: ids}
    )

    Logger.debug("AccessTracker flushed #{flush_count} memories")

    %{state | pending: %{}, total_flushed: state.total_flushed + flush_count}
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval)
  end

  # Find memories accessed within the co-activation window (excluding self)
  defp find_coactivated_memories(recent_accesses, current_id, now_ms) do
    cutoff = now_ms - @coactivation_window_ms

    recent_accesses
    |> Enum.filter(fn {id, timestamp} ->
      id != current_id && timestamp >= cutoff
    end)
    |> Enum.map(fn {id, _} -> id end)
    |> Enum.uniq()
  end

  # Prune accesses older than the co-activation window
  defp prune_old_accesses(accesses, now_ms) do
    cutoff = now_ms - @coactivation_window_ms

    Enum.filter(accesses, fn {_id, timestamp} ->
      timestamp >= cutoff
    end)
  end

  # Emit telemetry events for co-activation (Hebbian learning)
  # These events can be consumed by edge strengthening logic
  defp emit_coactivation_events(_memory_id, []), do: :ok

  defp emit_coactivation_events(memory_id, coactivated_ids) do
    :telemetry.execute(
      [:mimo, :memory, :coactivation],
      %{count: length(coactivated_ids)},
      %{
        memory_id: memory_id,
        coactivated_ids: coactivated_ids,
        # Normalized pairs for edge strengthening (smaller id first)
        pairs:
          Enum.map(coactivated_ids, fn other_id ->
            if memory_id < other_id, do: {memory_id, other_id}, else: {other_id, memory_id}
          end)
      }
    )
  end
end
