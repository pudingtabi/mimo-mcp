defmodule Mimo.Brain.MemoryExpiration do
  @moduledoc """
  SPEC-060 Enhancement: Background job to handle expired memories.

  Periodically scans for memories with `valid_until` in the past and marks them
  appropriately. Does NOT delete memories - preserves history while marking
  them as no longer valid.

  ## Configuration

      # In config/config.exs
      config :mimo, Mimo.Brain.MemoryExpiration,
        enabled: true,
        interval_ms: :timer.hours(1),  # Default: hourly
        batch_size: 100                # Memories per batch

  ## Behavior

  - Runs at configured interval (default: hourly)
  - Finds memories where `valid_until < now` AND `validity_source != 'expired'`
  - Updates `validity_source` to "expired" to prevent re-processing
  - Logs statistics on each run
  - Respects :protected flag (won't expire protected memories)

  ## Manual Triggering

      # Force an immediate scan
      Mimo.Brain.MemoryExpiration.scan_now()
      
      # Get current statistics
      Mimo.Brain.MemoryExpiration.stats()
  """

  use GenServer
  require Logger
  import Ecto.Query

  alias Mimo.Brain.Engram
  alias Mimo.Repo

  @default_interval_ms :timer.hours(1)
  @default_batch_size 100

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Start the MemoryExpiration GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Trigger an immediate expiration scan.

  Returns `{:ok, %{expired: count, skipped: count}}` with scan results.
  """
  @spec scan_now() :: {:ok, map()} | {:error, term()}
  def scan_now do
    GenServer.call(__MODULE__, :scan_now, :timer.minutes(5))
  end

  @doc """
  Get current statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Check if expiration service is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    config()[:enabled] || false
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, config()[:interval_ms] || @default_interval_ms),
      batch_size: Keyword.get(opts, :batch_size, config()[:batch_size] || @default_batch_size),
      enabled: Keyword.get(opts, :enabled, config()[:enabled] || false),
      last_scan_at: nil,
      total_expired: 0,
      total_scans: 0
    }

    if state.enabled do
      Logger.info("[MemoryExpiration] Started with interval #{state.interval_ms}ms")
      schedule_scan(state.interval_ms)
    else
      Logger.debug("[MemoryExpiration] Disabled via configuration")
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:scan_now, _from, state) do
    result = do_scan(state.batch_size)

    new_state = %{
      state
      | last_scan_at: DateTime.utc_now(),
        total_expired: state.total_expired + result.expired,
        total_scans: state.total_scans + 1
    }

    {:reply, {:ok, result}, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      enabled: state.enabled,
      interval_ms: state.interval_ms,
      batch_size: state.batch_size,
      last_scan_at: state.last_scan_at,
      total_expired: state.total_expired,
      total_scans: state.total_scans
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:scheduled_scan, state) do
    if state.enabled do
      result = do_scan(state.batch_size)

      Logger.info(
        "[MemoryExpiration] Scan complete: #{result.expired} expired, #{result.skipped} skipped"
      )

      schedule_scan(state.interval_ms)

      new_state = %{
        state
        | last_scan_at: DateTime.utc_now(),
          total_expired: state.total_expired + result.expired,
          total_scans: state.total_scans + 1
      }

      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  # ============================================================================
  # Private Implementation
  # ============================================================================

  defp schedule_scan(interval_ms) do
    Process.send_after(self(), :scheduled_scan, interval_ms)
  end

  defp do_scan(batch_size) do
    now = DateTime.utc_now()

    # Find memories that:
    # 1. Have valid_until in the past
    # 2. Are not already marked as expired
    # 3. Are not protected
    expired_query =
      from(e in Engram,
        where: not is_nil(e.valid_until),
        where: e.valid_until < ^now,
        where: e.validity_source != "expired" or is_nil(e.validity_source),
        where: e.protected == false or is_nil(e.protected),
        select: e.id,
        limit: ^batch_size
      )

    expired_ids = Repo.all(expired_query)

    if Enum.empty?(expired_ids) do
      %{expired: 0, skipped: 0, batch_complete: true}
    else
      # Update in batch
      {count, _} =
        from(e in Engram, where: e.id in ^expired_ids)
        |> Repo.update_all(
          set: [
            validity_source: "expired",
            updated_at: now
          ]
        )

      # Check if there might be more
      more_exist = length(expired_ids) >= batch_size

      Logger.debug("[MemoryExpiration] Marked #{count} memories as expired")

      %{
        expired: count,
        skipped: 0,
        batch_complete: not more_exist
      }
    end
  rescue
    e ->
      Logger.error("[MemoryExpiration] Scan failed: #{inspect(e)}")
      %{expired: 0, skipped: 0, error: inspect(e)}
  end

  defp config do
    Application.get_env(:mimo, __MODULE__, [])
  end
end
