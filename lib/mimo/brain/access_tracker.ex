defmodule Mimo.Brain.AccessTracker do
  @moduledoc """
  Tracks memory access patterns for decay scoring and analysis.

  Updates access_count and last_accessed_at when memories are retrieved.
  Uses batched async updates to avoid impacting read performance.

  ## Features

    - Async access tracking (non-blocking reads)
    - Batch updates for efficiency
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
  alias Mimo.{Repo, Brain.Engram}

  @flush_interval 5_000
  @batch_size 100

  # ==========================================================================
  # Public API
  # ==========================================================================

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
  """
  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @doc """
  Get tracking statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # ==========================================================================
  # GenServer Callbacks
  # ==========================================================================

  @impl true
  def init(_opts) do
    schedule_flush()

    state = %{
      pending: %{},
      total_tracked: 0,
      total_flushed: 0
    }

    Logger.info("AccessTracker initialized")
    {:ok, state}
  end

  @impl true
  def handle_cast({:track, memory_id}, state) do
    # Increment pending access count for this memory
    new_pending = Map.update(state.pending, memory_id, 1, &(&1 + 1))

    new_state = %{
      state
      | pending: new_pending,
        total_tracked: state.total_tracked + 1
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

  # ==========================================================================
  # Private Implementation
  # ==========================================================================

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
    Enum.each(by_increment, fn {increment, id_list} ->
      from(e in Engram,
        where: e.id in ^id_list,
        update: [
          set: [
            access_count: coalesce(e.access_count, 0) + ^increment,
            last_accessed_at: ^now
          ]
        ]
      )
      |> Repo.update_all([])
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
end
