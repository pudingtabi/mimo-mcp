defmodule Mimo.Skills.Terminal do
  @moduledoc """
  Non-blocking, secure command executor using Exile.

  Native replacement for desktop_commander terminal/process operations.

  ## Features
  - Working directory (cwd) support
  - Environment variables (env) support  
  - Output truncation (60KB max like VS Code)
  - Named process tracking
  - Shell selection (bash, sh, zsh, powershell)
  """
  require Logger

  @default_timeout 30_000
  # 60KB like VS Code
  @max_output_size 60_000

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

  @doc """
  Execute a command with optional cwd, env, and shell options.

  ## Options
    - `:timeout` - Timeout in milliseconds (default: 30_000)
    - `:yolo` - Skip confirmation prompts (default: false)
    - `:confirm` - Confirm destructive commands (default: false)
    - `:cwd` - Working directory for command (default: current directory)
    - `:env` - Environment variables as map or keyword list
    - `:shell` - Shell to use: "bash", "sh", "zsh", "powershell" (default: direct execution)

  ## Examples
      execute("npm test", cwd: "/app/frontend")
      execute("echo $MY_VAR", env: %{"MY_VAR" => "hello"}, shell: "bash")
  """
  def execute(cmd_str, opts \\ []) when is_binary(cmd_str) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    yolo = Keyword.get(opts, :yolo, false)
    confirmed = Keyword.get(opts, :confirm, false) || yolo
    cwd = Keyword.get(opts, :cwd)
    env = Keyword.get(opts, :env, %{})
    shell = Keyword.get(opts, :shell)

    # YOLO mode: skip confirmation prompts for advanced users
    if yolo do
      execute_safe(cmd_str, timeout, cwd: cwd, env: env, shell: shell)
    else
      case validate_cmd(cmd_str, false) do
        :ok ->
          case check_destructive(cmd_str, confirmed) do
            :ok ->
              execute_safe(cmd_str, timeout, cwd: cwd, env: env, shell: shell)

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
          # Use proper shell argument parsing to handle quoted strings
          cmd_args =
            case parse_shell_args(cmd_str) do
              {:ok, args} -> args
              # Fallback
              {:error, _} -> String.split(cmd_str)
            end

          # Start process with Exile
          {:ok, process} = Exile.Process.start_link(cmd_args)
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
          # Safely parse PID - malformed ps output shouldn't crash
          case Integer.parse(pid) do
            {pid_int, ""} ->
              %{
                user: user,
                pid: pid_int,
                cpu: cpu,
                mem: mem,
                command: Enum.join(cmd_parts, " ")
              }

            _ ->
              # Invalid PID format - skip this line
              nil
          end

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

  defp execute_safe(cmd_str, timeout, opts) do
    cwd = Keyword.get(opts, :cwd)
    env = Keyword.get(opts, :env, %{})
    shell = Keyword.get(opts, :shell)

    task =
      Task.async(fn ->
        try do
          # Build command and args based on shell option
          {cmd, args} = build_command(cmd_str, shell)

          # Build System.cmd options
          cmd_opts = [stderr_to_stdout: true]
          cmd_opts = if cwd && cwd != "", do: Keyword.put(cmd_opts, :cd, cwd), else: cmd_opts
          cmd_opts = Keyword.put(cmd_opts, :env, normalize_env(env))

          # Execute
          case System.cmd(cmd, args, cmd_opts) do
            {output, 0} -> %{status: 0, output: truncate_output(output)}
            {output, status} -> %{status: status, output: truncate_output(output)}
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

  # Build command based on shell selection
  defp build_command(cmd_str, nil) do
    # Direct execution - use proper shell argument parsing
    case parse_shell_args(cmd_str) do
      {:ok, [cmd | args]} ->
        {cmd, args}

      {:ok, []} ->
        {"", []}

      {:error, _reason} ->
        # Fallback to simple split if parsing fails
        [cmd | args] = String.split(cmd_str)
        {cmd, args}
    end
  end

  defp build_command(cmd_str, "bash"), do: {"/usr/bin/bash", ["-c", cmd_str]}
  defp build_command(cmd_str, "sh"), do: {"/usr/bin/sh", ["-c", cmd_str]}
  defp build_command(cmd_str, "zsh"), do: {"/usr/bin/zsh", ["-c", cmd_str]}
  defp build_command(cmd_str, "powershell"), do: {"powershell", ["-Command", cmd_str]}
  defp build_command(cmd_str, shell) when is_binary(shell), do: {shell, ["-c", cmd_str]}
  defp build_command(cmd_str, _), do: build_command(cmd_str, nil)

  @doc """
  Parse a shell command string into a list of arguments, respecting quotes.

  Handles:
  - Double quotes: "hello world" -> single arg
  - Single quotes: 'hello world' -> single arg  
  - Escaped quotes: "say \\"hello\\"" -> preserves inner quotes
  - Mixed: echo "hello" 'world' -> ["echo", "hello", "world"]

  ## Examples

      iex> parse_shell_args(~s(echo "hello world"))
      {:ok, ["echo", "hello world"]}
      
      iex> parse_shell_args(~s(git commit -m "fix: bug"))
      {:ok, ["git", "commit", "-m", "fix: bug"]}
  """
  def parse_shell_args(cmd_str) when is_binary(cmd_str) do
    cmd_str
    |> String.trim()
    |> do_parse_args([], "", nil)
  end

  # Finished parsing
  defp do_parse_args("", acc, "", _quote) do
    {:ok, Enum.reverse(acc)}
  end

  defp do_parse_args("", acc, current, nil) do
    {:ok, Enum.reverse([current | acc])}
  end

  defp do_parse_args("", _acc, _current, quote) do
    {:error, "Unclosed #{if quote == ?", do: "double", else: "single"} quote"}
  end

  # Handle escape sequences inside quotes
  defp do_parse_args(<<?\\, char, rest::binary>>, acc, current, quote) when quote != nil do
    do_parse_args(rest, acc, current <> <<char>>, quote)
  end

  # Handle opening/closing double quotes
  defp do_parse_args(<<?", rest::binary>>, acc, current, nil) do
    do_parse_args(rest, acc, current, ?")
  end

  defp do_parse_args(<<?", rest::binary>>, acc, current, ?") do
    do_parse_args(rest, acc, current, nil)
  end

  # Handle opening/closing single quotes
  defp do_parse_args(<<?', rest::binary>>, acc, current, nil) do
    do_parse_args(rest, acc, current, ?')
  end

  defp do_parse_args(<<?', rest::binary>>, acc, current, ?') do
    do_parse_args(rest, acc, current, nil)
  end

  # Space outside quotes = end of argument
  defp do_parse_args(<<" ", rest::binary>>, acc, "", nil) do
    # Skip consecutive spaces
    do_parse_args(rest, acc, "", nil)
  end

  defp do_parse_args(<<" ", rest::binary>>, acc, current, nil) do
    do_parse_args(rest, [current | acc], "", nil)
  end

  # Space inside quotes = part of argument
  defp do_parse_args(<<" ", rest::binary>>, acc, current, quote) when quote != nil do
    do_parse_args(rest, acc, current <> " ", quote)
  end

  # Regular character
  defp do_parse_args(<<char, rest::binary>>, acc, current, quote) do
    do_parse_args(rest, acc, current <> <<char>>, quote)
  end

  # Normalize environment variables to list of tuples
  defp normalize_env(env) when is_map(env) do
    Enum.map(env, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp normalize_env(env) when is_list(env) do
    Enum.map(env, fn
      {k, v} -> {to_string(k), to_string(v)}
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_env(_), do: []

  # Truncate output to prevent context overflow
  defp truncate_output(output) when byte_size(output) > @max_output_size do
    truncated = binary_part(output, 0, @max_output_size)
    omitted = byte_size(output) - @max_output_size
    truncated <> "\n\n... [OUTPUT TRUNCATED - #{omitted} bytes omitted]"
  end

  defp truncate_output(output), do: output

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
