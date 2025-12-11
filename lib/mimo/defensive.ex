defmodule Mimo.Defensive do
  @moduledoc """
  Defensive patterns for external interfaces (TASK 2 - Dec 6 2025 Incident Response)

  Provides reusable helpers for safely calling internal services from external
  entry points (MCP stdio, HTTP controllers, WebSocket handlers).

  ## Design Principles (Learned from Dec 6 2025 Incident)

  1. External entry points cannot safely make synchronous GenServer calls during 
     initialization because the supervision tree only guarantees process existence,
     not fully initialized state.

  2. The reliable pattern is defensive checks at the call site:
     - Use Process.whereis to locate the GenServer
     - Wrap calls in try/catch
     - Return graceful error responses instead of hanging

  3. When logger output is silenced for protocol compliance (e.g., MCP stdio mode),
     emit critical warnings to stderr to retain debuggability.

  ## Usage

      # In stdio.ex or HTTP controller:
      import Mimo.Defensive

      case safe_genserver_call(Mimo.ToolRegistry, {:lookup, tool_name}) do
        {:ok, result} -> handle_result(result)
        {:error, :not_ready} -> 
          warn_stderr("ToolRegistry not ready")
          handle_degraded_mode()
      end
  """

  @doc """
  Safely call a GenServer with defensive checks.

  Handles:
  - Process not started yet → {:error, :not_ready}
  - Process crashed → {:error, :not_alive}  
  - Timeout → {:error, :timeout}
  - Any other error → {:error, reason}

  This is the recommended pattern for external interfaces to call internal services.
  """
  @spec safe_genserver_call(atom() | pid(), term(), timeout()) :: {:ok, term()} | {:error, term()}
  def safe_genserver_call(server, message, timeout \\ 5000)

  def safe_genserver_call(pid, message, timeout) when is_pid(pid) do
    if Process.alive?(pid) do
      do_safe_call(pid, message, timeout)
    else
      {:error, :not_alive}
    end
  end

  def safe_genserver_call(server, message, timeout) when is_atom(server) do
    case Process.whereis(server) do
      nil -> {:error, :not_ready}
      pid -> safe_genserver_call(pid, message, timeout)
    end
  end

  defp do_safe_call(pid, message, timeout) do
    try do
      result = GenServer.call(pid, message, timeout)
      {:ok, result}
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
      :exit, {:noproc, _} -> {:error, :not_alive}
      :exit, reason -> {:error, {:exit, reason}}
    end
  end

  @doc """
  Safe cast to a GenServer - fire and forget with defensive check.
  """
  @spec safe_genserver_cast(atom() | pid(), term()) :: :ok | {:error, :not_ready | :not_alive}
  def safe_genserver_cast(server, message) when is_atom(server) do
    case Process.whereis(server) do
      nil -> {:error, :not_ready}
      pid -> safe_genserver_cast(pid, message)
    end
  end

  def safe_genserver_cast(pid, message) when is_pid(pid) do
    if Process.alive?(pid) do
      GenServer.cast(pid, message)
      :ok
    else
      {:error, :not_alive}
    end
  end

  @doc """
  Emit a warning to stderr.

  Critical for debugging when logger is silenced (e.g., MCP stdio mode with LOGGER_LEVEL=none).
  Warnings go to stderr so they don't corrupt the protocol on stdout.
  """
  @spec warn_stderr(String.t()) :: :ok
  def warn_stderr(message) do
    IO.write(:standard_error, "[MIMO WARNING] #{message}\n")
    :ok
  rescue
    # Don't let stderr writes fail the operation
    _ -> :ok
  end

  @doc """
  Emit an error to stderr.

  For critical errors that should always be visible regardless of logger settings.
  """
  @spec error_stderr(String.t()) :: :ok
  def error_stderr(message) do
    IO.write(:standard_error, "[MIMO ERROR] #{message}\n")
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Emit a debug message to stderr (only in dev/test).

  Respects MIX_ENV - won't emit in production.
  """
  @spec debug_stderr(String.t()) :: :ok
  def debug_stderr(message) do
    if Mix.env() in [:dev, :test] do
      IO.write(:standard_error, "[MIMO DEBUG] #{message}\n")
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Execute a function with timeout protection.

  Falls back to Task.await if Task.Supervisor is not available.
  """
  @spec with_timeout((-> term()), timeout()) :: {:ok, term()} | {:error, :timeout}
  def with_timeout(fun, timeout \\ 5000) when is_function(fun, 0) do
    task =
      if task_supervisor_available?() do
        Task.Supervisor.async_nolink(Mimo.TaskSupervisor, fun)
      else
        Task.async(fun)
      end

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      nil -> {:error, :timeout}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp task_supervisor_available? do
    case Process.whereis(Mimo.TaskSupervisor) do
      nil -> false
      pid when is_pid(pid) -> Process.alive?(pid)
    end
  end

  @doc """
  Check if a named process is alive and responsive.

  This is a quick non-blocking check - does NOT call the process.
  For full health check, use safe_genserver_call with a health message.
  """
  @spec process_alive?(atom()) :: boolean()
  def process_alive?(name) when is_atom(name) do
    case Process.whereis(name) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  @doc """
  Execute function with graceful degradation fallback.

  If the primary function fails or times out, executes the fallback.
  """
  @spec with_fallback((-> {:ok, term()} | {:error, term()}), (-> term()), keyword()) ::
          {:ok, term()} | {:error, term()}
  def with_fallback(primary_fn, fallback_fn, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5000)

    case with_timeout(primary_fn, timeout) do
      {:ok, {:ok, result}} ->
        {:ok, result}

      {:ok, {:error, _} = _error} ->
        warn_stderr("Primary function failed, using fallback")
        execute_fallback(fallback_fn)

      {:error, :timeout} ->
        warn_stderr("Primary function timed out, using fallback")
        execute_fallback(fallback_fn)

      {:error, _reason} ->
        execute_fallback(fallback_fn)
    end
  end

  defp execute_fallback(fallback_fn) do
    try do
      result = fallback_fn.()
      {:ok, result}
    rescue
      e -> {:error, {:fallback_failed, Exception.message(e)}}
    end
  end
end
