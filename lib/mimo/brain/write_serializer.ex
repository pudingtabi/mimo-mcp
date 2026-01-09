defmodule Mimo.Brain.WriteSerializer do
  @moduledoc """
  Serializes database write operations to prevent SQLite "Database busy" errors.

  SQLite allows concurrent reads (with WAL mode) but only one writer at a time.
  When Ecto pool_size > 1, multiple processes may try to write simultaneously,
  causing SQLITE_BUSY errors even with busy_timeout configured.

  This GenServer serializes all writes through a single process:
  - Reads: Use normal Ecto pool (concurrent, fast)
  - Writes: Go through this GenServer (serialized, safe)

  ## Usage

      # Instead of direct Repo.insert:
      WriteSerializer.insert(changeset)

      # Instead of direct Repo.update:
      WriteSerializer.update(changeset)

      # Instead of direct Repo.delete:
      WriteSerializer.delete(struct)

      # For custom write operations:
      WriteSerializer.transaction(fn -> ... end)

  ## Performance

  Under normal load, the serialization adds ~1ms latency.
  Under heavy load, it prevents failures and provides predictable queuing.
  """

  use GenServer
  require Logger

  @timeout 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Serialized insert operation"
  def insert(changeset, opts \\ []) do
    call_with_timeout({:insert, changeset, opts})
  end

  @doc "Serialized insert! operation (raises on error)"
  def insert!(changeset, opts \\ []) do
    case insert(changeset, opts) do
      {:ok, result} -> result
      {:error, changeset} -> raise Ecto.InvalidChangesetError, changeset: changeset
    end
  end

  @doc "Serialized update operation"
  def update(changeset, opts \\ []) do
    call_with_timeout({:update, changeset, opts})
  end

  @doc "Serialized update! operation (raises on error)"
  def update!(changeset, opts \\ []) do
    case update(changeset, opts) do
      {:ok, result} -> result
      {:error, changeset} -> raise Ecto.InvalidChangesetError, changeset: changeset
    end
  end

  @doc "Serialized delete operation"
  def delete(struct, opts \\ []) do
    call_with_timeout({:delete, struct, opts})
  end

  @doc "Serialized delete! operation (raises on error)"
  def delete!(struct, opts \\ []) do
    case delete(struct, opts) do
      {:ok, result} -> result
      {:error, changeset} -> raise Ecto.InvalidChangesetError, changeset: changeset
    end
  end

  @doc "Serialized insert_all operation"
  def insert_all(schema, entries, opts \\ []) do
    call_with_timeout({:insert_all, schema, entries, opts})
  end

  @doc """
  Serialized transaction with reentrant detection.

  Wraps a function in a serialized transaction.
  If already inside a WriteSerializer transaction (detected via process dictionary),
  executes the function directly to prevent calling_self deadlock.
  """
  def transaction(fun, opts \\ []) when is_function(fun) do
    # SPEC-STABILITY: Prevent calling_self deadlock from nested transactions
    if Process.get(:mimo_in_write_serializer) do
      # Already in a transaction - execute directly to avoid deadlock
      fun.()
    else
      call_with_timeout({:transaction, fun, opts})
    end
  end

  @doc "Check if the serializer is healthy and responsive"
  def health_check do
    try do
      GenServer.call(__MODULE__, :ping, 5_000)
    catch
      :exit, _ -> {:error, :not_responding}
    end
  end

  @doc "Get queue statistics"
  def stats do
    GenServer.call(__MODULE__, :stats, 5_000)
  catch
    :exit, _ -> {:error, :not_responding}
  end

  @impl true
  def init(_opts) do
    state = %{
      total_writes: 0,
      total_errors: 0,
      last_write_at: nil,
      started_at: DateTime.utc_now()
    }

    Logger.info("[WriteSerializer] Started - all writes will be serialized")
    {:ok, state}
  end

  @impl true
  def handle_call(:ping, _from, state) do
    {:reply, :pong, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      total_writes: state.total_writes,
      total_errors: state.total_errors,
      last_write_at: state.last_write_at,
      uptime_seconds: DateTime.diff(DateTime.utc_now(), state.started_at)
    }

    {:reply, {:ok, stats}, state}
  end

  @impl true
  def handle_call({:insert, changeset, opts}, _from, state) do
    {result, state} = execute_write(fn -> Mimo.Repo.insert(changeset, opts) end, state)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:update, changeset, opts}, _from, state) do
    {result, state} = execute_write(fn -> Mimo.Repo.update(changeset, opts) end, state)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:delete, struct, opts}, _from, state) do
    {result, state} = execute_write(fn -> Mimo.Repo.delete(struct, opts) end, state)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:insert_all, schema, entries, opts}, _from, state) do
    {result, state} = execute_write(fn -> Mimo.Repo.insert_all(schema, entries, opts) end, state)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:transaction, fun, opts}, _from, state) do
    # SPEC-STABILITY: Set flag so nested calls detect we are in a transaction
    # This prevents calling_self deadlock if fun() calls WriteSerializer again
    Process.put(:mimo_in_write_serializer, true)
    {result, state} = execute_write(fn -> Mimo.Repo.transaction(fun, opts) end, state)
    Process.delete(:mimo_in_write_serializer)
    {:reply, result, state}
  end

  defp call_with_timeout(request) do
    GenServer.call(__MODULE__, request, @timeout)
  catch
    :exit, {:timeout, _} ->
      Logger.warning("[WriteSerializer] Operation timed out after #{@timeout}ms")
      {:error, :write_timeout}

    :exit, {:noproc, _} ->
      Logger.error("[WriteSerializer] Process not running, falling back to direct write")
      # Fallback to direct Repo call if serializer is down
      execute_fallback(request)
  end

  defp execute_write(fun, state) do
    start_time = System.monotonic_time(:millisecond)

    result =
      try do
        fun.()
      rescue
        e ->
          Logger.error("[WriteSerializer] Write failed: #{inspect(e)}")
          {:error, e}
      end

    elapsed = System.monotonic_time(:millisecond) - start_time

    if elapsed > 1000 do
      Logger.warning("[WriteSerializer] Slow write: #{elapsed}ms")
    end

    new_state =
      case result do
        {:ok, _} ->
          %{state | total_writes: state.total_writes + 1, last_write_at: DateTime.utc_now()}

        {:error, _} ->
          %{state | total_errors: state.total_errors + 1}

        # For insert_all which returns {count, nil}
        {count, _} when is_integer(count) ->
          %{state | total_writes: state.total_writes + 1, last_write_at: DateTime.utc_now()}
      end

    {result, new_state}
  end

  # Fallback when serializer is not available
  defp execute_fallback({:insert, changeset, opts}), do: Mimo.Repo.insert(changeset, opts)
  defp execute_fallback({:update, changeset, opts}), do: Mimo.Repo.update(changeset, opts)
  defp execute_fallback({:delete, struct, opts}), do: Mimo.Repo.delete(struct, opts)

  defp execute_fallback({:insert_all, schema, entries, opts}),
    do: Mimo.Repo.insert_all(schema, entries, opts)

  defp execute_fallback({:transaction, fun, opts}), do: Mimo.Repo.transaction(fun, opts)
end
