defmodule Mimo.Brain.WorkingMemoryCleaner do
  alias Mimo.Brain.WorkingMemory

  @moduledoc """
  Periodic cleanup process for expired working memory items.

  Runs on a configurable interval to remove expired items from
  the working memory ETS table.
  """
  use GenServer
  require Logger

  @default_interval 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, get_config_interval())

    # Schedule first cleanup
    if enabled?() do
      schedule_cleanup(interval)
    end

    {:ok, %{interval: interval, last_cleanup: nil, total_cleaned: 0}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    {deleted, new_state} = run_cleanup(state)

    if deleted > 0 do
      Logger.debug("Working memory cleaner: removed #{deleted} expired items")
    end

    :telemetry.execute(
      [:mimo, :working_memory, :cleanup],
      %{expired_count: deleted},
      %{}
    )

    schedule_cleanup(state.interval)
    {:noreply, new_state}
  end

  defp run_cleanup(state) do
    case WorkingMemory.clear_expired() do
      {:ok, deleted} ->
        {deleted,
         %{
           state
           | last_cleanup: DateTime.utc_now(),
             total_cleaned: state.total_cleaned + deleted
         }}

      _ ->
        {0, state}
    end
  end

  defp schedule_cleanup(interval) do
    Process.send_after(self(), :cleanup, interval)
  end

  defp enabled? do
    Application.get_env(:mimo_mcp, :working_memory, [])
    |> Keyword.get(:enabled, true)
  end

  defp get_config_interval do
    Application.get_env(:mimo_mcp, :working_memory, [])
    |> Keyword.get(:cleanup_interval_ms, @default_interval)
  end
end
