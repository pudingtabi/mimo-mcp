defmodule Mimo.Sandbox do
  alias Ecto.Adapters.SQL.Sandbox

  @moduledoc """
  Helper utilities for sandbox-aware operations in tests.

  Provides `maybe_allow/3` which calls `Sandbox.allow/3`
  when available. This is a no-op outside of tests.
  """

  @doc """
  Allow `pid` to use `repo`'s connection as `owner` if sandbox is active.
  Empty no-op otherwise.
  """
  def maybe_allow(repo, owner, pid) do
    try do
      if function_exported?(Ecto.Adapters.SQL.Sandbox, :allow, 3) do
        Sandbox.allow(repo, owner, pid)
      else
        :ok
      end
    rescue
      _ ->
        :ok
    end
  end

  @doc """
  Run a function in a new Task with proper sandbox access.

  This ensures sandbox access is granted BEFORE the function executes any DB operations.
  Uses synchronization to prevent race conditions.

  ## Example

      Mimo.Sandbox.run_async(Mimo.Repo, fn ->
        Mimo.Repo.all(SomeSchema)
      end)
  """
  @spec run_async(module(), (-> any())) :: {:ok, pid()}
  def run_async(repo, fun) do
    owner = self()
    # Capture $callers for Ecto Sandbox allowance propagation
    callers = Process.get(:"$callers", [])

    # Use a ref for synchronization
    ref = make_ref()

    {:ok, pid} =
      Task.start(fn ->
        # Propagate $callers for Ecto Sandbox allowance
        Process.put(:"$callers", [owner | callers])

        # Wait for sandbox permission before doing any DB work
        receive do
          {:sandbox_ready, ^ref} -> :ok
        after
          # Timeout fallback
          5000 -> :ok
        end

        # Now safe to run DB operations
        try do
          fun.()
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end
      end)

    # Grant sandbox access first
    maybe_allow(repo, owner, pid)

    # Then signal the task to proceed
    send(pid, {:sandbox_ready, ref})

    {:ok, pid}
  end

  @doc """
  Check if we're running in sandbox/test mode.

  This can be used to skip certain operations in tests that don't have
  proper sandbox access (like background GenServers).
  """
  @spec sandbox_mode?() :: boolean()
  def sandbox_mode? do
    try do
      # Check if sandbox module is loaded and we're in test mode
      function_exported?(Ecto.Adapters.SQL.Sandbox, :mode, 2) and
        Code.ensure_loaded?(ExUnit)
    rescue
      _ -> false
    end
  end

  @doc """
  Safely execute a database operation, catching sandbox ownership errors.

  Returns `{:ok, result}` on success, or `{:error, :sandbox_mode}` if the
  operation failed due to sandbox ownership.
  """
  @spec safe_db_call((-> result)) :: {:ok, result} | {:error, :sandbox_mode} when result: any()
  def safe_db_call(fun) do
    try do
      {:ok, fun.()}
    rescue
      e in DBConnection.OwnershipError ->
        require Logger
        Logger.debug("Sandbox ownership error (test mode): #{Exception.message(e)}")
        {:error, :sandbox_mode}

      e in DBConnection.ConnectionError ->
        require Logger
        Logger.debug("Sandbox connection error (test mode): #{Exception.message(e)}")
        {:error, :sandbox_mode}
    end
  end
end
