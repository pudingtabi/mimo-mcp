defmodule Mimo.Skills.Terminal do
  @moduledoc """
  Non-blocking, secure command executor using Exile.

  Native replacement for desktop_commander terminal/process operations.
  """
  require Logger

  @default_timeout 30_000

  # Destructive commands that require confirmation (unless yolo: true)
  @destructive_commands MapSet.new(~w[
    rm rmdir shred dd mkfs fdisk parted
    chmod chown chgrp chattr
    kill pkill killall
  ])

  # Dangerous patterns that require confirmation (checked via regex)
  @dangerous_patterns [
    # rm with absolute path
    ~r/rm\s+(-[rf]+\s+)*\//,
    # rm with wildcard
    ~r/rm\s+-[rf]*\s+\*/,
    # write to device
    ~r/>\s*\/dev\//,
    # format filesystem
    ~r/mkfs/,
    # dd write operations
    ~r/dd\s+.*of=/
  ]

  # YOLO mode: all commands allowed, only block interactive TUI commands
  # that can't work over stdio
  @blocked_tui_commands MapSet.new(~w[
    vim nvim nano emacs micro ed ex vi
    top htop bashtop bpytop gotop ytop
    less more most mostty
    screen tmux byobu
    ssh sshd telnet
  ])

  # ==========================================================================
  # Process Registry (for tracking running processes)
  # ==========================================================================

  defmodule Registry do
    use Agent

    def start_link(_opts) do
      Agent.start_link(fn -> %{} end, name: __MODULE__)
    end

    def register(pid, info) do
      Agent.update(__MODULE__, &Map.put(&1, pid, info))
    end

    def unregister(pid) do
      Agent.update(__MODULE__, &Map.delete(&1, pid))
    end

    def get(pid) do
      Agent.get(__MODULE__, &Map.get(&1, pid))
    end

    def list_all do
      Agent.get(__MODULE__, & &1)
    end
  end

  # ==========================================================================
  # Public API - Single Command Execution
  # ==========================================================================

  def execute(cmd_str, opts \\ []) when is_binary(cmd_str) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    yolo = Keyword.get(opts, :yolo, false)
    confirmed = Keyword.get(opts, :confirm, false) || yolo

    # YOLO mode: bypass ALL safety checks (including TUI block)
    if yolo do
      execute_safe(cmd_str, timeout)
    else
      case validate_cmd(cmd_str, false) do
        :ok ->
          case check_destructive(cmd_str, confirmed) do
            :ok ->
              execute_safe(cmd_str, timeout)

            {:needs_confirmation, warning} ->
              %{status: 0, output: warning, needs_confirmation: true}
          end

        {:error, reason} ->
          %{status: 1, output: "Security error: #{reason}"}
      end
    end
  end

  # ==========================================================================
  # Process Management (replaces desktop_commander process tools)
  # ==========================================================================

  @doc """
  Start a background process with smart output detection.
  Returns PID for later interaction.
  """
  def start_process(cmd_str, opts \\ []) when is_binary(cmd_str) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 5000)

    case validate_cmd(cmd_str, false) do
      :ok ->
        try do
          [cmd | args] = String.split(cmd_str)

          # Start process with Exile
          {:ok, process} = Exile.Process.start_link([cmd | args])
          pid = Exile.Process.os_pid(process)

          # Register for tracking
          ensure_registry_started()

          Registry.register(pid, %{
            command: cmd_str,
            started_at: DateTime.utc_now(),
            process: process,
            output: ""
          })

          # Collect initial output
          initial_output = collect_output(process, timeout_ms)

          {:ok,
           %{
             pid: pid,
             command: cmd_str,
             initial_output: initial_output
           }}
        rescue
          e -> {:error, "Failed to start process: #{Exception.message(e)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Read output from a running process.
  """
  def read_process_output(pid, opts \\ []) when is_integer(pid) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 1000)

    ensure_registry_started()

    case Registry.get(pid) do
      nil ->
        {:error, :process_not_found}

      %{process: process} ->
        output = collect_output(process, timeout_ms)
        {:ok, %{pid: pid, output: output}}
    end
  end

  @doc """
  Send input to a running process.
  """
  def interact_with_process(pid, input) when is_integer(pid) and is_binary(input) do
    ensure_registry_started()

    case Registry.get(pid) do
      nil ->
        {:error, :process_not_found}

      %{process: process} ->
        Exile.Process.write(process, input <> "\n")
        # Give time for response
        Process.sleep(100)
        output = collect_output(process, 1000)
        {:ok, %{pid: pid, output: output}}
    end
  end

  @doc """
  Kill a running process.
  """
  def kill_process(pid) when is_integer(pid) do
    ensure_registry_started()

    case Registry.get(pid) do
      nil ->
        {:error, :process_not_found}

      %{process: process} ->
        Exile.Process.kill(process, :sigterm)
        Registry.unregister(pid)
        {:ok, %{pid: pid, status: :killed}}
    end
  end

  @doc """
  Force terminate a process.
  """
  def force_terminate(pid) when is_integer(pid) do
    System.cmd("kill", ["-9", Integer.to_string(pid)])
    ensure_registry_started()
    Registry.unregister(pid)
    {:ok, %{pid: pid, status: :force_terminated}}
  end

  @doc """
  List all active terminal sessions.
  """
  def list_sessions do
    ensure_registry_started()
    sessions = Registry.list_all()

    active =
      Enum.map(sessions, fn {pid, info} ->
        %{
          pid: pid,
          command: info.command,
          started_at: info.started_at,
          runtime_seconds: DateTime.diff(DateTime.utc_now(), info.started_at)
        }
      end)

    {:ok, active}
  end

  @doc """
  List all running processes on the system.
  """
  def list_processes do
    case System.cmd("ps", ["aux"]) do
      {output, 0} ->
        lines = String.split(output, "\n", trim: true)
        processes = parse_ps_output(lines)
        {:ok, processes}

      {_, _} ->
        {:error, :failed_to_list_processes}
    end
  end

  defp parse_ps_output([_header | lines]) do
    Enum.map(lines, fn line ->
      parts = String.split(line, ~r/\s+/, parts: 11)

      case parts do
        [user, pid, cpu, mem, _vsz, _rss, _tty, _stat, _start, _time | cmd_parts] ->
          %{
            user: user,
            pid: String.to_integer(pid),
            cpu: cpu,
            mem: mem,
            command: Enum.join(cmd_parts, " ")
          }

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_ps_output(_), do: []

  # ==========================================================================
  # Private Helpers
  # ==========================================================================

  # YOLO mode: minimal validation, only block interactive TUI commands
  defp validate_cmd(cmd_str, _restricted) do
    parts = String.split(cmd_str)
    base_cmd = List.first(parts)

    cond do
      is_nil(base_cmd) or base_cmd == "" ->
        {:error, "Empty command"}

      MapSet.member?(@blocked_tui_commands, base_cmd) ->
        {:error, "Interactive command '#{base_cmd}' is prohibited (use native terminal)"}

      true ->
        :ok
    end
  end

  # Check if command is destructive and needs confirmation
  defp check_destructive(cmd_str, confirmed) do
    if confirmed do
      :ok
    else
      parts = String.split(cmd_str)
      base_cmd = List.first(parts)

      is_destructive_cmd = MapSet.member?(@destructive_commands, base_cmd)
      is_dangerous_pattern = Enum.any?(@dangerous_patterns, &Regex.match?(&1, cmd_str))

      if is_destructive_cmd or is_dangerous_pattern do
        warning = """
        ⚠️  DESTRUCTIVE COMMAND DETECTED

        Command: #{cmd_str}

        This command may cause data loss or system changes.
        To execute, call again with confirm: true

        Example: terminal(command: "#{cmd_str}", confirm: true)
        """

        {:needs_confirmation, warning}
      else
        :ok
      end
    end
  end

  defp execute_safe(cmd_str, timeout) do
    task =
      Task.async(fn ->
        try do
          [cmd | args] = String.split(cmd_str)

          # Use System.cmd for simpler commands - more reliable in stdio context
          case System.cmd(cmd, args, stderr_to_stdout: true) do
            {output, 0} -> %{status: 0, output: output}
            {output, status} -> %{status: status, output: output}
          end
        rescue
          e -> %{status: 1, output: "Execution error: #{Exception.message(e)}"}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> %{status: 1, output: "Command timed out after #{timeout}ms"}
    end
  end

  defp collect_output(process, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect_output_loop(process, "", deadline)
  end

  defp collect_output_loop(process, acc, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      acc
    else
      case Exile.Process.read(process, min(100, remaining)) do
        {:ok, data} -> collect_output_loop(process, acc <> data, deadline)
        {:eof, _} -> acc
        _ -> acc
      end
    end
  end

  defp ensure_registry_started do
    case Process.whereis(Registry) do
      nil -> Registry.start_link([])
      _ -> :ok
    end
  end
end
