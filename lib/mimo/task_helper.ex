defmodule Mimo.TaskHelper do
  @moduledoc """
  Helpers for spawning tasks with proper Ecto Sandbox allowance propagation.

  When running tests with Ecto.Adapters.SQL.Sandbox, spawned tasks don't
  automatically inherit database connection access. This module provides
  helpers that propagate the `$callers` process dictionary for sandbox allowance.

  ## Why This Matters

  The Ecto Sandbox tracks which processes are "allowed" to use database connections.
  By default, only the test process and processes it explicitly allows have access.
  When using `Task.async`, the spawned process is a new process that doesn't inherit
  this allowance.

  Ecto 3.x supports looking up `$callers` in the process dictionary to find an
  allowed ancestor process. This module ensures spawned tasks have this set.

  ## Usage

      # Instead of:
      Task.async(fn -> do_db_work() end)
      
      # Use:
      TaskHelper.async_with_callers(fn -> do_db_work() end)
      
      # Or with explicit supervisor:
      TaskHelper.async_with_callers(MySupervisor, fn -> do_db_work() end)
  """

  @doc """
  Spawn a task that propagates $callers for Ecto Sandbox allowance.

  Uses `Mimo.TaskSupervisor` for proper supervision.
  The spawned task will have access to the caller's database connections
  when running in test mode with Ecto Sandbox.

  ## Examples

      task = TaskHelper.async_with_callers(fn -> Repo.all(User) end)
      result = Task.await(task)
  """
  @spec async_with_callers((-> any())) :: Task.t()
  def async_with_callers(fun) when is_function(fun, 0) do
    async_with_callers(Mimo.TaskSupervisor, fun)
  end

  @doc """
  Spawn a task under a specific supervisor with $callers propagation.

  ## Examples

      task = TaskHelper.async_with_callers(MyApp.TaskSupervisor, fn -> 
        Repo.all(User) 
      end)
      result = Task.await(task)
  """
  @spec async_with_callers(atom() | pid(), (-> any())) :: Task.t()
  def async_with_callers(supervisor, fun) when is_function(fun, 0) do
    caller = self()
    callers = Process.get(:"$callers", [])

    Task.Supervisor.async(supervisor, fn ->
      # Propagate $callers for Ecto Sandbox allowance
      Process.put(:"$callers", [caller | callers])
      fun.()
    end)
  end

  @doc """
  Spawn a task without linking (won't crash caller on failure).

  Useful when you want to await results but don't want task crashes
  to propagate to the caller process.

  ## Examples

      task = TaskHelper.async_nolink_with_callers(fn -> risky_db_operation() end)
      case Task.yield(task, 5000) || Task.shutdown(task) do
        {:ok, result} -> result
        nil -> :timeout
        {:exit, reason} -> {:error, reason}
      end
  """
  @spec async_nolink_with_callers((-> any())) :: Task.t()
  def async_nolink_with_callers(fun) when is_function(fun, 0) do
    async_nolink_with_callers(Mimo.TaskSupervisor, fun)
  end

  @doc """
  Spawn a task under a specific supervisor without linking.
  """
  @spec async_nolink_with_callers(atom() | pid(), (-> any())) :: Task.t()
  def async_nolink_with_callers(supervisor, fun) when is_function(fun, 0) do
    caller = self()
    callers = Process.get(:"$callers", [])

    Task.Supervisor.async_nolink(supervisor, fn ->
      # Propagate $callers for Ecto Sandbox allowance
      Process.put(:"$callers", [caller | callers])
      fun.()
    end)
  end

  @doc """
  Async stream that propagates $callers for Ecto Sandbox allowance.

  This is a drop-in replacement for `Task.async_stream/3` that ensures
  spawned tasks have access to the database connection in test mode.

  ## Examples

      items
      |> TaskHelper.async_stream_with_callers(fn item -> process(item) end, max_concurrency: 4)
      |> Enum.map(fn {:ok, result} -> result end)
  """
  @spec async_stream_with_callers(Enumerable.t(), (any() -> any()), keyword()) :: Enumerable.t()
  def async_stream_with_callers(enumerable, fun, opts \\ []) when is_function(fun, 1) do
    caller = self()
    callers = Process.get(:"$callers", [])

    wrapped_fun = fn item ->
      Process.put(:"$callers", [caller | callers])
      fun.(item)
    end

    Task.Supervisor.async_stream(Mimo.TaskSupervisor, enumerable, wrapped_fun, opts)
  end

  @doc """
  Safely start a child task, returning :ok or {:error, reason} if supervisor unavailable.

  Use this when you want to fire-and-forget a task but need graceful degradation
  when the TaskSupervisor is shutting down or not started.

  ## Examples

      case TaskHelper.safe_start_child(fn -> cleanup_resources() end) do
        {:ok, _pid} -> :ok
        {:error, :supervisor_unavailable} -> 
          # Run synchronously or skip
          cleanup_resources()
      end
  """
  @spec safe_start_child((-> any())) :: {:ok, pid()} | {:error, :supervisor_unavailable | term()}
  def safe_start_child(fun) when is_function(fun, 0) do
    safe_start_child(Mimo.TaskSupervisor, fun)
  end

  @spec safe_start_child(atom() | pid(), (-> any())) ::
          {:ok, pid()} | {:error, :supervisor_unavailable | term()}
  def safe_start_child(supervisor, fun) when is_function(fun, 0) do
    caller = self()
    callers = Process.get(:"$callers", [])

    wrapped_fun = fn ->
      Process.put(:"$callers", [caller | callers])
      fun.()
    end

    case supervisor_available?(supervisor) do
      true ->
        try do
          Task.Supervisor.start_child(supervisor, wrapped_fun)
        catch
          :exit, {:noproc, _} -> {:error, :supervisor_unavailable}
          :exit, {:shutdown, _} -> {:error, :supervisor_unavailable}
          :exit, reason -> {:error, reason}
        end

      false ->
        {:error, :supervisor_unavailable}
    end
  end

  @doc """
  Check if a TaskSupervisor is available and running.
  """
  @spec supervisor_available?(atom() | pid()) :: boolean()
  def supervisor_available?(supervisor) when is_atom(supervisor) do
    case Process.whereis(supervisor) do
      nil -> false
      pid when is_pid(pid) -> Process.alive?(pid)
    end
  end

  def supervisor_available?(supervisor) when is_pid(supervisor) do
    Process.alive?(supervisor)
  end
end
