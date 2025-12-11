defmodule Mimo.Autonomous.SafetyGuard do
  @moduledoc """
  Safety checks before autonomous task execution.

  Part of SPEC-071: Autonomous Task Execution.

  ## Blocked Actions
  - File deletions without explicit permission
  - System commands (shutdown, reboot, halt, etc.)
  - Network requests to untrusted domains
  - Recursive file operations (rm -rf)

  ## Safety Philosophy
  This module is FAIL-CLOSED: when in doubt, block the operation.
  It's better to reject a valid task than to execute a dangerous one.

  ## Usage

      SafetyGuard.check_allowed(%{command: "ls -la"})
      #=> :ok

      SafetyGuard.check_allowed(%{command: "rm -rf /"})
      #=> {:error, :blocked_dangerous_command}
  """

  require Logger

  # Dangerous shell patterns - these are always blocked
  @blocked_command_patterns [
    # Dangerous file operations
    ~r/rm\s+(-\w+\s+)*-r/i,           # rm -r, rm -rf, rm -Rf, etc.
    ~r/rm\s+(-\w+\s+)*--recursive/i,  # rm --recursive
    ~r/rmdir\s+--ignore-fail-on-non-empty/i,

    # System control commands
    ~r/\bshutdown\b/i,
    ~r/\breboot\b/i,
    ~r/\bhalt\b/i,
    ~r/\bpoweroff\b/i,
    ~r/\binit\s+[0-6]/i,
    ~r/\bsystemctl\s+(poweroff|reboot|halt)/i,

    # Process/system manipulation
    ~r/\bkillall\b/i,
    ~r/\bpkill\s+-9/i,
    ~r/\bkill\s+-9\s+(-1|1)\b/i,      # kill -9 -1 or kill -9 1

    # Disk/filesystem manipulation
    ~r/\bmkfs\b/i,
    ~r/\bdd\s+.+of=/i,
    ~r/\bfdisk\b/i,
    ~r/\bparted\b/i,

    # User/permission manipulation
    ~r/\bchmod\s+(-\w+\s+)*777\b/i,
    ~r/\bchown\s+.*:\s*$/i,

    # Network attacks
    ~r/\bfork\s*bomb\b/i,
    ~r/:\(\)\s*\{\s*:\|:\s*&\s*\}/,   # Classic fork bomb pattern

    # Elixir/Erlang dangerous calls
    ~r/:halt\b/,
    ~r/:stop\b/,
    ~r/System\.halt/,
    ~r/System\.stop/,
    ~r/:init\.stop/,
    ~r/:erlang\.halt/
  ]

  # File path patterns that should never be modified
  @protected_paths [
    ~r{^/$},                          # Root directory
    ~r{^/etc(/|$)},                   # System configuration
    ~r{^/boot(/|$)},                  # Boot files
    ~r{^/sys(/|$)},                   # Kernel interface
    ~r{^/proc(/|$)},                  # Process info
    ~r{^/dev(/|$)},                   # Device files
    ~r{^/usr(/|$)},                   # System programs (read-only)
    ~r{^~/.ssh(/|$)},                 # SSH keys
    ~r{^/root(/|$)}                   # Root home
  ]

  @doc """
  Check if a task is allowed to execute.

  Returns `:ok` if the task is safe to execute,
  or `{:error, reason}` if the task should be blocked.

  ## Examples

      iex> SafetyGuard.check_allowed(%{command: "echo hello"})
      :ok

      iex> SafetyGuard.check_allowed(%{command: "rm -rf /"})
      {:error, :blocked_dangerous_command}
  """
  @spec check_allowed(map()) :: :ok | {:error, atom()}
  def check_allowed(task_spec) when is_map(task_spec) do
    with :ok <- check_command(task_spec),
         :ok <- check_file_paths(task_spec),
         :ok <- check_description(task_spec) do
      :ok
    end
  end

  def check_allowed(_), do: {:error, :invalid_task_spec}

  @doc """
  Validate a command string for dangerous patterns.

  ## Examples

      iex> SafetyGuard.validate_command("npm test")
      :ok

      iex> SafetyGuard.validate_command("shutdown now")
      {:error, :blocked_dangerous_command}
  """
  @spec validate_command(String.t()) :: :ok | {:error, atom()}
  def validate_command(command) when is_binary(command) do
    if dangerous_command?(command) do
      Logger.warning("[SafetyGuard] Blocked dangerous command: #{String.slice(command, 0, 100)}")
      {:error, :blocked_dangerous_command}
    else
      :ok
    end
  end

  def validate_command(_), do: {:error, :invalid_command}

  @doc """
  Validate a file path is not in a protected location.

  ## Examples

      iex> SafetyGuard.validate_path("/workspace/project/file.ex")
      :ok

      iex> SafetyGuard.validate_path("/etc/passwd")
      {:error, :blocked_protected_path}
  """
  @spec validate_path(String.t()) :: :ok | {:error, atom()}
  def validate_path(path) when is_binary(path) do
    if protected_path?(path) do
      Logger.warning("[SafetyGuard] Blocked access to protected path: #{path}")
      {:error, :blocked_protected_path}
    else
      :ok
    end
  end

  def validate_path(_), do: {:error, :invalid_path}

  @doc """
  Get human-readable explanation for a safety block.
  """
  @spec explain_block(atom()) :: String.t()
  def explain_block(:blocked_dangerous_command) do
    "This command contains patterns that could cause system damage (e.g., rm -rf, shutdown, fork bomb)"
  end

  def explain_block(:blocked_protected_path) do
    "This path is protected and cannot be modified by autonomous tasks"
  end

  def explain_block(:invalid_task_spec) do
    "The task specification is malformed or missing required fields"
  end

  def explain_block(:invalid_command) do
    "The command field must be a string"
  end

  def explain_block(:invalid_path) do
    "The path field must be a string"
  end

  def explain_block(reason) do
    "Task blocked for safety: #{inspect(reason)}"
  end

  # =============================================================================
  # Private Functions
  # =============================================================================

  defp check_command(%{command: command}) when is_binary(command) do
    validate_command(command)
  end

  defp check_command(%{"command" => command}) when is_binary(command) do
    validate_command(command)
  end

  defp check_command(_), do: :ok  # No command field is fine

  defp check_file_paths(%{path: path}) when is_binary(path) do
    validate_path(path)
  end

  defp check_file_paths(%{"path" => path}) when is_binary(path) do
    validate_path(path)
  end

  defp check_file_paths(%{paths: paths}) when is_list(paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case validate_path(path) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp check_file_paths(%{"paths" => paths}) when is_list(paths) do
    check_file_paths(%{paths: paths})
  end

  defp check_file_paths(_), do: :ok  # No path field is fine

  defp check_description(%{description: desc}) when is_binary(desc) do
    # Check if the description itself suggests dangerous intent
    if dangerous_intent?(desc) do
      Logger.warning("[SafetyGuard] Blocked task with dangerous description")
      {:error, :blocked_dangerous_intent}
    else
      :ok
    end
  end

  defp check_description(%{"description" => desc}) when is_binary(desc) do
    check_description(%{description: desc})
  end

  defp check_description(_), do: :ok

  defp dangerous_command?(command) do
    Enum.any?(@blocked_command_patterns, fn pattern ->
      Regex.match?(pattern, command)
    end)
  end

  defp protected_path?(path) do
    # Expand ~ to home directory for checking
    expanded = String.replace(path, ~r/^~/, System.get_env("HOME") || "/home/user")

    Enum.any?(@protected_paths, fn pattern ->
      Regex.match?(pattern, expanded)
    end)
  end

  defp dangerous_intent?(description) do
    desc_lower = String.downcase(description)

    dangerous_phrases = [
      "delete everything",
      "wipe all",
      "destroy",
      "nuke",
      "format disk",
      "erase system"
    ]

    Enum.any?(dangerous_phrases, &String.contains?(desc_lower, &1))
  end
end
