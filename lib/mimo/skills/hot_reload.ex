defmodule Mimo.Skills.HotReload do
  @moduledoc """
  Atomic hot reload with distributed locking.
  Prevents registration loss during reload.

  ## Features

  - Distributed lock ensures only one reload at a time
  - Graceful draining of in-flight requests
  - Atomic clear and reload of all skills
  - Telemetry events for monitoring

  ## Usage

      # Trigger a hot reload
      {:ok, :reloaded} = Mimo.Skills.HotReload.reload_skills()
      
      # Check if reload is in progress
      false = Mimo.Skills.HotReload.reloading?()
      
      # Force reload even if one is in progress (admin only)
      {:ok, :reloaded} = Mimo.Skills.HotReload.force_reload()
  """
  alias Catalog

  use GenServer
  require Logger

  @lock_key {:mimo_skill_reload_lock, node()}
  @drain_timeout_ms 30_000
  @reload_timeout_ms 60_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Trigger a hot reload of all skills.

  Acquires a distributed lock, drains in-flight requests,
  clears all registrations, and reloads from the catalog.

  Returns `{:ok, :reloaded}` on success or `{:error, reason}` on failure.
  """
  def reload_skills do
    GenServer.call(__MODULE__, :reload, @reload_timeout_ms)
  end

  @doc """
  Check if a reload is currently in progress.
  """
  def reloading? do
    GenServer.call(__MODULE__, :reloading?)
  end

  @doc """
  Force a reload, breaking any existing lock.
  Use with caution - only for admin recovery scenarios.
  """
  def force_reload do
    GenServer.call(__MODULE__, :force_reload, @reload_timeout_ms)
  end

  @doc """
  Get the status of the hot reload system.
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @impl true
  def init(_opts) do
    state = %{
      reloading: false,
      last_reload: nil,
      last_reload_duration_ms: nil,
      lock_holder: nil,
      reload_count: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:reload, _from, %{reloading: true} = state) do
    Logger.warning("Hot reload already in progress, skipping")
    {:reply, {:error, :reload_in_progress}, state}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    case acquire_lock() do
      {:ok, lock_token} ->
        state = %{state | reloading: true, lock_holder: lock_token}

        {result, duration_ms} = timed_reload()

        release_lock(lock_token)

        new_state = %{
          state
          | reloading: false,
            lock_holder: nil,
            last_reload: DateTime.utc_now(),
            last_reload_duration_ms: duration_ms,
            reload_count: state.reload_count + 1
        }

        {:reply, result, new_state}

      {:error, :lock_taken} ->
        Logger.warning("Could not acquire reload lock - another reload in progress")
        {:reply, {:error, :reload_in_progress}, state}
    end
  end

  @impl true
  def handle_call(:force_reload, _from, state) do
    # Force release any existing lock
    :global.del_lock(@lock_key)

    state = %{state | reloading: true, lock_holder: :forced}

    {result, duration_ms} = timed_reload()

    new_state = %{
      state
      | reloading: false,
        lock_holder: nil,
        last_reload: DateTime.utc_now(),
        last_reload_duration_ms: duration_ms,
        reload_count: state.reload_count + 1
    }

    {:reply, result, new_state}
  end

  @impl true
  def handle_call(:reloading?, _from, state) do
    {:reply, state.reloading, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      reloading: state.reloading,
      last_reload: state.last_reload,
      last_reload_duration_ms: state.last_reload_duration_ms,
      reload_count: state.reload_count,
      lock_held: state.lock_holder != nil
    }

    {:reply, status, state}
  end

  defp timed_reload do
    start_time = System.monotonic_time(:millisecond)
    result = do_reload()
    duration = System.monotonic_time(:millisecond) - start_time

    emit_reload_telemetry(result, duration)

    {result, duration}
  end

  defp do_reload do
    Logger.warning("🔄 Hot reload starting...")

    try do
      # Step 1: Signal all skills to drain
      signal_drain()

      # Step 2: Wait for in-flight requests to complete
      case await_draining() do
        :ok ->
          Logger.info("All skills drained, proceeding with reload")

        :timeout ->
          Logger.warning("Drain timeout, proceeding with reload anyway")
      end

      # Step 3: Clear all registrations
      clear_registrations()

      # Step 4: Reload catalog
      reload_catalog()

      Logger.warning("✅ Hot reload complete")
      {:ok, :reloaded}
    rescue
      e ->
        Logger.error("Hot reload failed: #{Exception.message(e)}")
        {:error, {:reload_failed, Exception.message(e)}}
    end
  end

  defp signal_drain do
    Logger.info("Signaling skills to drain...")
    Mimo.ToolRegistry.signal_drain()
  end

  defp await_draining do
    Logger.info("Waiting for skills to drain (max #{@drain_timeout_ms}ms)...")

    deadline = System.monotonic_time(:millisecond) + @drain_timeout_ms

    Stream.repeatedly(fn ->
      remaining = deadline - System.monotonic_time(:millisecond)

      cond do
        remaining <= 0 ->
          :timeout

        all_drained?() ->
          :ok

        true ->
          Process.sleep(500)
          :continue
      end
    end)
    |> Stream.drop_while(&(&1 == :continue))
    |> Enum.take(1)
    |> List.first()
  end

  defp all_drained? do
    Mimo.ToolRegistry.all_drained?()
  end

  defp clear_registrations do
    Logger.info("Clearing all registrations...")
    Mimo.ToolRegistry.clear_all()

    # Also terminate any running skill processes
    terminate_skill_processes()
  end

  defp terminate_skill_processes do
    # Get all children from the skills supervisor
    case Process.whereis(Mimo.Skills.Supervisor) do
      nil ->
        :ok

      pid when is_pid(pid) ->
        children = DynamicSupervisor.which_children(pid)

        Enum.each(children, fn {_, child_pid, _, _} ->
          if is_pid(child_pid) and Process.alive?(child_pid) do
            DynamicSupervisor.terminate_child(pid, child_pid)
          end
        end)
    end
  end

  defp reload_catalog do
    Logger.info("Reloading skill catalog...")

    if Code.ensure_loaded?(Catalog) and
         function_exported?(Catalog, :reload, 0) do
      Mimo.Skills.Catalog.reload()
    else
      Logger.warning("Catalog module not available")
    end
  end

  defp acquire_lock do
    # Use :global for distributed lock
    # Returns :ok if lock acquired, :aborted if already held
    lock_id = {@lock_key, self()}

    case :global.set_lock(lock_id, [node()], 1) do
      true ->
        {:ok, lock_id}

      false ->
        {:error, :lock_taken}
    end
  end

  defp release_lock(lock_id) do
    :global.del_lock(lock_id)
  end

  defp emit_reload_telemetry(result, duration_ms) do
    status =
      case result do
        {:ok, _} -> :success
        {:error, _} -> :failure
      end

    :telemetry.execute(
      [:mimo, :skills, :hot_reload],
      %{duration_ms: duration_ms},
      %{
        status: status,
        timestamp: DateTime.utc_now()
      }
    )

    Logger.info("Hot reload #{status} in #{duration_ms}ms")
  end
end
