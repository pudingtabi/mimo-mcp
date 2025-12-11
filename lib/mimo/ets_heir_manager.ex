defmodule Mimo.EtsHeirManager do
  @moduledoc """
  ETS Table Heir Manager for crash recovery.

  This GenServer acts as an heir for critical ETS tables in Mimo.
  When a GenServer that owns an ETS table crashes:
  1. The ETS table is transferred to this heir (not destroyed)
  2. When the owner GenServer restarts, it can reclaim the table

  ## How it works

  The ETS `:heir` option specifies a process that inherits the table
  when the owner dies. This manager:
  - Holds tables temporarily after owner crashes
  - Gives tables back when owners restart and call `reclaim_table/2`
  - Cleans up tables if owners never reclaim them (configurable timeout)

  ## Usage

  In your GenServer's init:

      def init(_opts) do
        table = Mimo.EtsHeirManager.create_table(
          :my_table,
          [:named_table, :set, :public],
          self()
        )
        {:ok, %{table: table}}
      end

  If you crash and restart, reclaim the table:

      def init(_opts) do
        table = case Mimo.EtsHeirManager.reclaim_table(:my_table, self()) do
          {:ok, table} ->
            Logger.info("Reclaimed ETS table after crash")
            table
          :not_found ->
            Mimo.EtsHeirManager.create_table(:my_table, [:named_table, :set, :public], self())
        end
        {:ok, %{table: table}}
      end
  """

  use GenServer
  require Logger

  @table_name :ets_heir_registry
  # How long to keep orphaned tables before cleanup (30 minutes)
  @orphan_ttl_ms 30 * 60 * 1000
  # Cleanup check interval (5 minutes)
  @cleanup_interval_ms 5 * 60 * 1000

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start the ETS Heir Manager.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Create a new ETS table with this process as heir.

  Returns the table reference. The calling process becomes the owner.
  If the owner crashes, the table is transferred to this heir manager.

  ## Options

  - `:name` - The table name (required for named tables)
  - Standard ETS options like `:set`, `:public`, etc.
  """
  @spec create_table(atom(), list(), pid()) :: :ets.tid() | atom()
  def create_table(name, ets_opts, owner_pid) do
    # Add heir option pointing to this manager
    heir_opts = [{:heir, Process.whereis(__MODULE__), name}]
    full_opts = ets_opts ++ heir_opts

    table = :ets.new(name, full_opts)

    # Register the table in our registry
    GenServer.cast(__MODULE__, {:register_table, name, owner_pid, table})

    Logger.debug("[EtsHeirManager] Created table #{name} for #{inspect(owner_pid)}")
    table
  end

  @doc """
  Reclaim an ETS table after the owner process restarts.

  Returns `{:ok, table}` if the table was held by the heir and is now
  transferred back to the caller. Returns `:not_found` if no such table
  is held (meaning it was never created or already cleaned up).
  """
  @spec reclaim_table(atom(), pid()) :: {:ok, :ets.tid() | atom()} | :not_found
  def reclaim_table(name, new_owner_pid) do
    GenServer.call(__MODULE__, {:reclaim_table, name, new_owner_pid})
  end

  @doc """
  Check if a table is currently held by the heir (owner crashed).
  """
  @spec table_orphaned?(atom()) :: boolean()
  def table_orphaned?(name) do
    GenServer.call(__MODULE__, {:is_orphaned, name})
  end

  @doc """
  Get statistics about held tables.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Registry for tracking tables: %{name => %{owner: pid, table: tid, orphaned_at: nil | DateTime}}
    :ets.new(@table_name, [:named_table, :set, :protected])

    Logger.info("✅ EtsHeirManager started")
    schedule_cleanup()

    {:ok, %{}}
  end

  @impl true
  def handle_cast({:register_table, name, owner_pid, table}, state) do
    # Monitor the owner so we know when it dies
    ref = Process.monitor(owner_pid)

    :ets.insert(
      @table_name,
      {name,
       %{
         owner: owner_pid,
         monitor_ref: ref,
         table: table,
         orphaned_at: nil,
         created_at: DateTime.utc_now()
       }}
    )

    {:noreply, state}
  end

  @impl true
  def handle_call({:reclaim_table, name, new_owner_pid}, _from, state) do
    case :ets.lookup(@table_name, name) do
      [{^name, %{table: table, orphaned_at: orphaned_at} = entry}] when not is_nil(orphaned_at) ->
        # Table is orphaned, give it to new owner
        :ets.give_away(table, new_owner_pid, name)

        # Update registry with new owner
        new_ref = Process.monitor(new_owner_pid)
        updated_entry = %{entry | owner: new_owner_pid, monitor_ref: new_ref, orphaned_at: nil}
        :ets.insert(@table_name, {name, updated_entry})

        Logger.info("[EtsHeirManager] Table #{name} reclaimed by #{inspect(new_owner_pid)}")
        {:reply, {:ok, table}, state}

      [{^name, _entry}] ->
        # Table exists but not orphaned (shouldn't happen in normal flow)
        {:reply, :not_found, state}

      [] ->
        # No such table
        {:reply, :not_found, state}
    end
  end

  def handle_call({:is_orphaned, name}, _from, state) do
    result =
      case :ets.lookup(@table_name, name) do
        [{^name, %{orphaned_at: orphaned_at}}] -> not is_nil(orphaned_at)
        [] -> false
      end

    {:reply, result, state}
  end

  def handle_call(:stats, _from, state) do
    all_entries = :ets.tab2list(@table_name)

    stats = %{
      total_tables: length(all_entries),
      active_tables: Enum.count(all_entries, fn {_, e} -> is_nil(e.orphaned_at) end),
      orphaned_tables: Enum.count(all_entries, fn {_, e} -> not is_nil(e.orphaned_at) end),
      tables:
        Enum.map(all_entries, fn {name, entry} ->
          %{
            name: name,
            owner: inspect(entry.owner),
            orphaned: not is_nil(entry.orphaned_at),
            created_at: entry.created_at
          }
        end)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    # Owner process died, mark table as orphaned
    case find_by_monitor_ref(ref) do
      {:ok, name, entry} ->
        Logger.warning(
          "[EtsHeirManager] Owner #{inspect(pid)} died (#{inspect(reason)}), holding table #{name}"
        )

        updated_entry = %{entry | orphaned_at: DateTime.utc_now(), monitor_ref: nil}
        :ets.insert(@table_name, {name, updated_entry})

      :not_found ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info({:"ETS-TRANSFER", table, from_pid, heir_data}, state) do
    # This is called when we inherit a table
    Logger.info("[EtsHeirManager] Inherited table #{inspect(heir_data)} from #{inspect(from_pid)}")

    # The table is now ours. Update the registry if needed.
    # The :DOWN message should have already marked it orphaned.
    case :ets.lookup(@table_name, heir_data) do
      [{name, entry}] ->
        # Update table reference in case it changed
        :ets.insert(@table_name, {name, %{entry | table: table}})

      [] ->
        # Unknown table, just track it
        :ets.insert(
          @table_name,
          {heir_data,
           %{
             owner: nil,
             monitor_ref: nil,
             table: table,
             orphaned_at: DateTime.utc_now(),
             created_at: DateTime.utc_now()
           }}
        )
    end

    {:noreply, state}
  end

  def handle_info(:cleanup_orphans, state) do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -@orphan_ttl_ms, :millisecond)

    # Find and delete tables orphaned for too long
    orphaned =
      :ets.tab2list(@table_name)
      |> Enum.filter(fn {_, entry} ->
        entry.orphaned_at && DateTime.compare(entry.orphaned_at, cutoff) == :lt
      end)

    Enum.each(orphaned, fn {name, _entry} ->
      Logger.warning("[EtsHeirManager] Cleaning up long-orphaned table #{name}")
      # Delete the ETS table if it still exists
      case :ets.whereis(name) do
        :undefined -> :ok
        _tid -> :ets.delete(name)
      end

      # Remove from registry
      :ets.delete(@table_name, name)
    end)

    if length(orphaned) > 0 do
      Logger.info("[EtsHeirManager] Cleaned up #{length(orphaned)} orphaned tables")
    end

    schedule_cleanup()
    {:noreply, state}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp find_by_monitor_ref(ref) do
    case :ets.tab2list(@table_name)
         |> Enum.find(fn {_, entry} -> entry.monitor_ref == ref end) do
      {name, entry} -> {:ok, name, entry}
      nil -> :not_found
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_orphans, @cleanup_interval_ms)
  end
end
