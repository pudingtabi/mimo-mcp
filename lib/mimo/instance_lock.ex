defmodule Mimo.InstanceLock do
  @moduledoc """
  Ensures only one instance of Mimo runs at a time.

  Uses OS-level file locking via the `flock` command which automatically
  releases on process exit, even if the process crashes.

  ## Usage

  Called automatically in Application.start/2:

      case InstanceLock.acquire() do
        :ok -> proceed with startup
        {:error, :already_running} -> exit with error
      end

  ## Files

  - `priv/mimo.lock` - Lock file (held open while running)
  - `priv/mimo.pid` - PID file for debugging (shows which process holds lock)
  """

  require Logger

  @lock_file "priv/mimo.lock"
  @pid_file "priv/mimo.pid"

  @doc """
  Attempts to acquire the instance lock using flock.

  Returns:
    - `:ok` - Lock acquired successfully
    - `{:error, :already_running}` - Another instance holds the lock
    - `{:error, reason}` - Other error
  """
  @spec acquire() :: :ok | {:error, :already_running | term()}
  def acquire do
    # Ensure priv directory exists
    File.mkdir_p!(Path.dirname(@lock_file))

    # Touch the lock file to ensure it exists
    File.touch!(@lock_file)

    # Use flock command with -n (non-blocking) and -x (exclusive)
    # We keep a port open to hold the lock
    port_cmd = "flock -n -x #{@lock_file} -c 'echo LOCKED; cat'"

    port =
      Port.open({:spawn, port_cmd}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout
      ])

    receive do
      {^port, {:data, "LOCKED\n"}} ->
        # Successfully acquired lock
        :persistent_term.put({__MODULE__, :lock_port}, port)

        # Write lock info and PID file
        write_lock_info()
        write_pid_file()

        Logger.info("[InstanceLock] Lock acquired (PID: #{System.pid()})")
        :ok

      {^port, {:exit_status, 1}} ->
        # Lock acquisition failed - another instance running
        holder = read_holder_info()

        Logger.error("""
        [InstanceLock] Another Mimo instance is already running!

        Holder information:
          PID: #{holder[:pid] || "unknown"}
          Node: #{holder[:node] || "unknown"}
          Started: #{holder[:started_at] || "unknown"}

        To force restart, kill the existing process first:
          kill #{holder[:pid]}
        """)

        {:error, :already_running}

      {^port, {:exit_status, code}} ->
        Logger.error("[InstanceLock] flock failed with exit code: #{code}")
        {:error, {:flock_failed, code}}
    after
      5000 ->
        Port.close(port)
        Logger.error("[InstanceLock] Timeout acquiring lock")
        {:error, :timeout}
    end
  end

  @doc """
  Releases the instance lock.
  """
  @spec release() :: :ok
  def release do
    case :persistent_term.get({__MODULE__, :lock_port}, nil) do
      nil ->
        :ok

      port ->
        Port.close(port)
        :persistent_term.erase({__MODULE__, :lock_port})
        File.rm(@pid_file)
        Logger.info("[InstanceLock] Lock released")
        :ok
    end
  end

  @doc """
  Returns the current lock status.
  """
  @spec status() :: map()
  def status do
    we_hold_lock = :persistent_term.get({__MODULE__, :lock_port}, nil) != nil
    holder = read_holder_info()

    %{
      locked: we_hold_lock,
      lock_file: @lock_file,
      holder_pid: holder[:pid],
      holder_node: holder[:node],
      started_at: holder[:started_at]
    }
  end

  @doc """
  Reads information about the current lock holder.
  """
  @spec read_holder_info() :: map()
  def read_holder_info do
    lock_info_file = @lock_file <> ".info"

    if File.exists?(lock_info_file) do
      case File.read(lock_info_file) do
        {:ok, content} when byte_size(content) > 0 ->
          case Jason.decode(content) do
            {:ok, info} ->
              %{
                pid: info["pid"],
                node: info["node"],
                started_at: info["started_at"]
              }

            _ ->
              %{}
          end

        _ ->
          %{}
      end
    else
      %{}
    end
  end

  @doc """
  Checks if the holder process is still alive.
  """
  @spec check_holder_alive() :: {:alive | :dead, String.t()} | :unknown
  def check_holder_alive do
    case read_holder_info() do
      %{pid: pid} when is_binary(pid) ->
        case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
          {_, 0} -> {:alive, pid}
          {_, _} -> {:dead, pid}
        end

      _ ->
        :unknown
    end
  end

  # Private functions

  defp write_lock_info do
    lock_info = %{
      pid: System.pid(),
      node: to_string(node()),
      started_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    File.write!(@lock_file <> ".info", Jason.encode!(lock_info, pretty: true))
  rescue
    e ->
      Logger.warning("[InstanceLock] Failed to write lock info: #{Exception.message(e)}")
  end

  defp write_pid_file do
    File.write!(@pid_file, System.pid())
  rescue
    e ->
      Logger.warning("[InstanceLock] Failed to write PID file: #{Exception.message(e)}")
  end
end
