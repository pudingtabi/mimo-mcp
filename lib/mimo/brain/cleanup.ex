defmodule Mimo.Brain.Cleanup do
  @moduledoc """
  Automatic memory cleanup service with TTL management.

  Features:
  - Hourly cleanup of old memories
  - Importance-based retention policies
  - Hard limits on total memory count
  - Manual cleanup API for operators
  - Telemetry for all cleanup events

  ## Configuration

  Configure in your config.exs:

      config :mimo_mcp, Mimo.Brain.Cleanup,
        default_ttl_days: 30,
        low_importance_ttl_days: 7,
        max_memory_count: 100_000,
        cleanup_interval_ms: 3_600_000
        
  ## Usage

  The cleanup service starts automatically with the application.
  To manually trigger cleanup:

      Mimo.Brain.Cleanup.force_cleanup()
      Mimo.Brain.Cleanup.cleanup_stats()
  """

  use GenServer
  import Ecto.Query
  require Logger
  alias Mimo.Repo
  alias Mimo.Brain.Engram
  alias Mimo.SafeCall

  # Default configuration
  @default_ttl_days 30
  @low_importance_ttl_days 7
  @high_importance_threshold 0.7
  @low_importance_threshold 0.5
  @max_memory_count 100_000
  # Hourly
  @cleanup_interval_ms 60 * 60 * 1000

  # ==========================================================================
  # Public API
  # ==========================================================================

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Force an immediate cleanup cycle.
  Returns cleanup statistics or empty stats if unavailable.
  """
  def force_cleanup do
    SafeCall.genserver(__MODULE__, :force_cleanup,
      timeout: 60_000,
      raw: true,
      fallback: %{status: :unavailable, cleaned: 0}
    )
  end

  @doc """
  Get current cleanup statistics without running cleanup.
  """
  def cleanup_stats do
    SafeCall.genserver(__MODULE__, :stats,
      raw: true,
      fallback: %{status: :unavailable, total_cleaned: 0}
    )
  end

  @doc """
  Check if cleanup is currently running.
  """
  def cleaning? do
    SafeCall.genserver(__MODULE__, :cleaning?,
      raw: true,
      fallback: false
    )
  end

  @doc """
  Update cleanup configuration at runtime.
  """
  def configure(opts) do
    SafeCall.genserver(__MODULE__, {:configure, opts},
      raw: true,
      fallback: {:error, :unavailable}
    )
  end

  # ==========================================================================
  # GenServer Callbacks
  # ==========================================================================

  @impl true
  def init(opts) do
    # Schedule first cleanup
    schedule_cleanup()

    state = %{
      config: build_config(opts),
      last_cleanup: nil,
      last_cleanup_stats: nil,
      cleaning: false
    }

    Logger.info("Memory cleanup service started (interval: #{state.config.cleanup_interval_ms}ms)")
    {:ok, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    new_state = run_cleanup(state)
    schedule_cleanup()
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:force_cleanup, _from, state) do
    new_state = run_cleanup(state)
    {:reply, new_state.last_cleanup_stats, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = calculate_stats()
    {:reply, stats, state}
  end

  @impl true
  def handle_call(:cleaning?, _from, state) do
    {:reply, state.cleaning, state}
  end

  @impl true
  def handle_call({:configure, opts}, _from, state) do
    new_config = Map.merge(state.config, Map.new(opts))
    {:reply, :ok, %{state | config: new_config}}
  end

  # ==========================================================================
  # Private Functions - Cleanup Operations
  # ==========================================================================

  defp run_cleanup(state) do
    Logger.info("Starting memory cleanup...")
    start_time = System.monotonic_time(:millisecond)

    state = %{state | cleaning: true}

    stats = %{
      old_memories_removed: 0,
      low_importance_removed: 0,
      limit_enforcement_removed: 0,
      duration_ms: 0,
      timestamp: DateTime.utc_now()
    }

    # Run cleanup operations
    stats =
      stats
      |> Map.put(:old_memories_removed, cleanup_old_memories(state.config))
      |> Map.put(:low_importance_removed, cleanup_low_importance_memories(state.config))
      |> Map.put(:limit_enforcement_removed, enforce_memory_limit(state.config))

    duration = System.monotonic_time(:millisecond) - start_time
    stats = Map.put(stats, :duration_ms, duration)

    total_removed =
      stats.old_memories_removed +
        stats.low_importance_removed +
        stats.limit_enforcement_removed

    # Emit telemetry
    emit_cleanup_telemetry(stats)

    Logger.info("Memory cleanup complete: removed #{total_removed} memories in #{duration}ms")

    %{state | cleaning: false, last_cleanup: DateTime.utc_now(), last_cleanup_stats: stats}
  end

  # Remove memories older than default TTL (except high-importance)
  defp cleanup_old_memories(config) do
    cutoff =
      DateTime.add(
        DateTime.utc_now(),
        -config.default_ttl_days * 24 * 60 * 60,
        :second
      )

    {count, _} =
      Repo.delete_all(
        from(e in Engram,
          where: e.inserted_at < ^cutoff,
          where: e.importance < ^@high_importance_threshold
        )
      )

    if count > 0 do
      Logger.info("Removed #{count} memories older than #{config.default_ttl_days} days")
    end

    count
  end

  # Remove low-importance memories after shorter TTL
  defp cleanup_low_importance_memories(config) do
    cutoff =
      DateTime.add(
        DateTime.utc_now(),
        -config.low_importance_ttl_days * 24 * 60 * 60,
        :second
      )

    {count, _} =
      Repo.delete_all(
        from(e in Engram,
          where: e.inserted_at < ^cutoff,
          where: e.importance < ^@low_importance_threshold
        )
      )

    if count > 0 do
      Logger.info(
        "Removed #{count} low-importance memories older than #{config.low_importance_ttl_days} days"
      )
    end

    count
  end

  # Enforce hard limit on total memory count
  defp enforce_memory_limit(config) do
    current_count = Repo.one(from(e in Engram, select: count(e.id)))

    if current_count > config.max_memory_count do
      to_remove = current_count - config.max_memory_count

      # Remove oldest, lowest-importance memories first
      # Get IDs to delete (can't use subquery directly with SQLite)
      ids_to_delete =
        Repo.all(
          from(e in Engram,
            select: e.id,
            order_by: [asc: e.importance, asc: e.inserted_at],
            limit: ^to_remove
          )
        )

      {count, _} = Repo.delete_all(from(e in Engram, where: e.id in ^ids_to_delete))

      Logger.warning(
        "Memory limit exceeded (#{current_count}/#{config.max_memory_count}): removed #{count} memories"
      )

      count
    else
      0
    end
  end

  # ==========================================================================
  # Private Functions - Statistics
  # ==========================================================================

  defp calculate_stats do
    total = Repo.one(from(e in Engram, select: count(e.id))) || 0

    by_category =
      Repo.all(
        from(e in Engram,
          group_by: e.category,
          select: {e.category, count(e.id)}
        )
      )
      |> Map.new()

    by_importance = %{
      high:
        Repo.one(
          from(e in Engram, where: e.importance >= ^@high_importance_threshold, select: count(e.id))
        ) || 0,
      medium:
        Repo.one(
          from(e in Engram,
            where:
              e.importance >= ^@low_importance_threshold and
                e.importance < ^@high_importance_threshold,
            select: count(e.id)
          )
        ) || 0,
      low:
        Repo.one(
          from(e in Engram, where: e.importance < ^@low_importance_threshold, select: count(e.id))
        ) || 0
    }

    oldest =
      Repo.one(from(e in Engram, order_by: [asc: e.inserted_at], limit: 1, select: e.inserted_at))

    newest =
      Repo.one(from(e in Engram, order_by: [desc: e.inserted_at], limit: 1, select: e.inserted_at))

    %{
      total_memories: total,
      by_category: by_category,
      by_importance: by_importance,
      oldest_memory: oldest,
      newest_memory: newest,
      limit: get_config(:max_memory_count),
      usage_percent:
        if(get_config(:max_memory_count) > 0,
          do: total / get_config(:max_memory_count) * 100,
          else: 0
        )
    }
  end

  # ==========================================================================
  # Private Functions - Helpers
  # ==========================================================================

  defp schedule_cleanup do
    interval = get_config(:cleanup_interval_ms)
    Process.send_after(self(), :cleanup, interval)
  end

  defp build_config(opts) do
    %{
      default_ttl_days: Keyword.get(opts, :default_ttl_days, get_config(:default_ttl_days)),
      low_importance_ttl_days:
        Keyword.get(opts, :low_importance_ttl_days, get_config(:low_importance_ttl_days)),
      max_memory_count: Keyword.get(opts, :max_memory_count, get_config(:max_memory_count)),
      cleanup_interval_ms: Keyword.get(opts, :cleanup_interval_ms, get_config(:cleanup_interval_ms))
    }
  end

  defp get_config(key) do
    config = Application.get_env(:mimo_mcp, __MODULE__, [])

    case key do
      :default_ttl_days ->
        Keyword.get(config, :default_ttl_days, @default_ttl_days)

      :low_importance_ttl_days ->
        Keyword.get(config, :low_importance_ttl_days, @low_importance_ttl_days)

      :max_memory_count ->
        Keyword.get(config, :max_memory_count, @max_memory_count)

      :cleanup_interval_ms ->
        Keyword.get(config, :cleanup_interval_ms, @cleanup_interval_ms)
    end
  end

  defp emit_cleanup_telemetry(stats) do
    :telemetry.execute(
      [:mimo, :brain, :cleanup],
      %{
        old_removed: stats.old_memories_removed,
        low_importance_removed: stats.low_importance_removed,
        limit_enforcement_removed: stats.limit_enforcement_removed,
        total_removed:
          stats.old_memories_removed + stats.low_importance_removed +
            stats.limit_enforcement_removed,
        duration_ms: stats.duration_ms
      },
      %{timestamp: stats.timestamp}
    )
  end
end
