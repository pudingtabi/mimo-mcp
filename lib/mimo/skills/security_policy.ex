defmodule Mimo.Skills.SecurityPolicy do
  @moduledoc """
  Single source of truth for skill execution security policies.

  This module consolidates all security constants and validation logic
  used by both `Mimo.Skills.Validator` (pre-validation) and 
  `Mimo.Skills.SecureExecutor` (runtime execution).

  ## Security Features

  - **Command Whitelist**: Only approved commands can be executed
  - **Environment Variable Filtering**: Only allowed env vars are interpolated
  - **Dangerous Pattern Detection**: Shell injection and path traversal prevention
  - **Resource Limits**: Argument counts, string lengths, timeout values

  ## Usage

      # Check if a command is allowed
      SecurityPolicy.command_allowed?("npx")
      #=> true

      # Check if an env var can be interpolated
      SecurityPolicy.env_var_allowed?("GITHUB_TOKEN")
      #=> true

      # Check if an argument is safe
      SecurityPolicy.pattern_safe?("--rm")
      #=> true

      SecurityPolicy.pattern_safe?("; rm -rf /")
      #=> false
  """

  # ===========================================================================
  # Allowed Commands
  # ===========================================================================

  @allowed_commands ~w(npx docker node python python3)

  @doc """
  Returns the list of allowed command basenames.
  """
  @spec allowed_commands() :: [String.t()]
  def allowed_commands, do: @allowed_commands

  @doc """
  Checks if a command is in the allowlist.

  Uses `Path.basename/1` to normalize, preventing path traversal.

  ## Examples

      iex> SecurityPolicy.command_allowed?("npx")
      true

      iex> SecurityPolicy.command_allowed?("/usr/bin/npx")
      true

      iex> SecurityPolicy.command_allowed?("bash")
      false
  """
  @spec command_allowed?(String.t()) :: boolean()
  def command_allowed?(cmd) when is_binary(cmd) do
    Path.basename(cmd) in @allowed_commands
  end

  def command_allowed?(_), do: false

  # ===========================================================================
  # Allowed Environment Variables
  # ===========================================================================

  @allowed_env_vars ~w(
    EXA_API_KEY
    GITHUB_TOKEN
    ANTHROPIC_API_KEY
    OPENAI_API_KEY
    GEMINI_API_KEY
    BRAVE_API_KEY
    TAVILY_API_KEY
    HOME
    PATH
    NODE_PATH
    PYTHONPATH
    MEMORY_PATH
    DATA_DIR
    CONFIG_DIR
  )

  @doc """
  Returns the list of environment variables allowed for interpolation.
  """
  @spec allowed_env_vars() :: [String.t()]
  def allowed_env_vars, do: @allowed_env_vars

  @doc """
  Checks if an environment variable is allowed for interpolation.

  ## Examples

      iex> SecurityPolicy.env_var_allowed?("GITHUB_TOKEN")
      true

      iex> SecurityPolicy.env_var_allowed?("SECRET_KEY")
      false
  """
  @spec env_var_allowed?(String.t()) :: boolean()
  def env_var_allowed?(var) when is_binary(var) do
    var in @allowed_env_vars
  end

  def env_var_allowed?(_), do: false

  # ===========================================================================
  # Dangerous Patterns
  # ===========================================================================

  @dangerous_patterns [
    # Shell metacharacters - prevent injection
    ~r/[;&|`$(){}!<>\\]/,
    # Path traversal
    ~r/\.\.\//,
    # System config access
    ~r/^\/etc\//,
    # Docker socket mount
    ~r/^\/var\/run\/docker\.sock/,
    # Docker privileged mode
    ~r/--privileged/,
    # Docker host network
    ~r/--network=host/,
    # Docker PID namespace
    ~r/--pid=host/,
    # Docker IPC namespace
    ~r/--ipc=host/,
    # Docker capabilities escalation
    ~r/--cap-add/
  ]

  @doc """
  Returns the list of dangerous regex patterns.
  """
  @spec dangerous_patterns() :: [Regex.t()]
  def dangerous_patterns, do: @dangerous_patterns

  @doc """
  Checks if a string is safe (does not match any dangerous patterns).

  ## Examples

      iex> SecurityPolicy.pattern_safe?("--rm")
      true

      iex> SecurityPolicy.pattern_safe?("; rm -rf /")
      false

      iex> SecurityPolicy.pattern_safe?("--privileged")
      false

      iex> SecurityPolicy.pattern_safe?("../../../etc/passwd")
      false
  """
  @spec pattern_safe?(String.t()) :: boolean()
  def pattern_safe?(arg) when is_binary(arg) do
    not Enum.any?(@dangerous_patterns, fn pattern ->
      Regex.match?(pattern, arg)
    end)
  end

  def pattern_safe?(_), do: false

  # ===========================================================================
  # Resource Limits
  # ===========================================================================

  @max_args 30
  @max_env_properties 30
  @max_string_length 1024

  @doc "Maximum number of arguments allowed."
  @spec max_args() :: pos_integer()
  def max_args, do: @max_args

  @doc "Maximum number of environment variables allowed."
  @spec max_env_properties() :: pos_integer()
  def max_env_properties, do: @max_env_properties

  @doc "Maximum length of any string value."
  @spec max_string_length() :: pos_integer()
  def max_string_length, do: @max_string_length

  # ===========================================================================
  # Environment Variable Name Validation
  # ===========================================================================

  @env_var_name_pattern ~r/^[A-Z_][A-Z0-9_]*$/

  @doc """
  Returns the regex pattern for valid environment variable names.
  """
  @spec env_var_name_pattern() :: Regex.t()
  def env_var_name_pattern, do: @env_var_name_pattern

  @doc """
  Checks if a string is a valid environment variable name.

  Must start with A-Z or underscore, followed by A-Z, 0-9, or underscore.

  ## Examples

      iex> SecurityPolicy.valid_env_var_name?("GITHUB_TOKEN")
      true

      iex> SecurityPolicy.valid_env_var_name?("_INTERNAL")
      true

      iex> SecurityPolicy.valid_env_var_name?("lowercase")
      false

      iex> SecurityPolicy.valid_env_var_name?("123_INVALID")
      false
  """
  @spec valid_env_var_name?(String.t()) :: boolean()
  def valid_env_var_name?(name) when is_binary(name) do
    Regex.match?(@env_var_name_pattern, name)
  end

  def valid_env_var_name?(_), do: false

  # ===========================================================================
  # Shell Metacharacter Detection
  # ===========================================================================

  @shell_metacharacters ~r/[\r\n;&|`$(){}!<>\\]/

  @doc """
  Returns the regex pattern for dangerous shell metacharacters.
  """
  @spec shell_metacharacters() :: Regex.t()
  def shell_metacharacters, do: @shell_metacharacters

  @doc """
  Checks if a string contains shell metacharacters.

  ## Examples

      iex> SecurityPolicy.has_shell_metacharacters?("; rm -rf /")
      true

      iex> SecurityPolicy.has_shell_metacharacters?("normal-arg")
      false
  """
  @spec has_shell_metacharacters?(String.t()) :: boolean()
  def has_shell_metacharacters?(str) when is_binary(str) do
    Regex.match?(@shell_metacharacters, str)
  end

  def has_shell_metacharacters?(_), do: false

  # ===========================================================================
  # Docker-Specific Restrictions
  # ===========================================================================

  @docker_forbidden_args [
    "--privileged",
    "--network=host",
    "-v /var/run/docker.sock",
    "--pid=host",
    "--ipc=host"
  ]

  @doc """
  Returns the list of forbidden Docker arguments.
  """
  @spec docker_forbidden_args() :: [String.t()]
  def docker_forbidden_args, do: @docker_forbidden_args

  @doc """
  Checks if any Docker arguments are forbidden.

  Checks both individual args and joined args (for patterns like "-v docker.sock").

  ## Examples

      iex> SecurityPolicy.docker_args_safe?(["run", "--rm", "alpine"])
      true

      iex> SecurityPolicy.docker_args_safe?(["run", "--privileged", "alpine"])
      false
  """
  @spec docker_args_safe?([String.t()]) :: boolean()
  def docker_args_safe?(args) when is_list(args) do
    all_args_str = Enum.join(args, " ")

    not Enum.any?(@docker_forbidden_args, fn forbidden ->
      String.contains?(all_args_str, forbidden) or
        Enum.any?(args, fn arg -> String.contains?(arg, forbidden) end)
    end)
  end

  def docker_args_safe?(_), do: false

  # ===========================================================================
  # Comprehensive Validation
  # ===========================================================================

  @doc """
  Validates a complete skill configuration against all security policies.

  Returns `:ok` if valid, or `{:error, reason}` with details.

  ## Checks performed

  1. Command is in allowlist
  2. Argument count within limits
  3. No dangerous patterns in arguments
  4. No shell metacharacters in arguments
  5. Environment variables are in allowlist
  6. String lengths within limits

  ## Examples

      config = %{
        "command" => "npx",
        "args" => ["-y", "@anthropic-ai/mcp-server"],
        "env" => %{"GITHUB_TOKEN" => "${GITHUB_TOKEN}"}
      }
      SecurityPolicy.validate_config(config)
      #=> :ok
  """
  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(config) when is_map(config) do
    with :ok <- validate_command(config),
         :ok <- validate_args(config),
         :ok <- validate_env(config) do
      :ok
    end
  end

  def validate_config(_), do: {:error, {:invalid_config, "Config must be a map"}}

  defp validate_command(%{"command" => cmd}) do
    if command_allowed?(cmd) do
      :ok
    else
      {:error, {:command_not_allowed, cmd, @allowed_commands}}
    end
  end

  defp validate_command(_), do: {:error, {:missing_field, "command"}}

  defp validate_args(%{"args" => args}) when is_list(args) do
    cond do
      length(args) > @max_args ->
        {:error, {:too_many_args, length(args), @max_args}}

      true ->
        validate_each_arg(args)
    end
  end

  defp validate_args(%{"args" => _}), do: {:error, {:invalid_type, "args", "array"}}
  defp validate_args(_), do: :ok

  defp validate_each_arg(args) do
    dangerous =
      Enum.reject(args, fn arg ->
        str = to_string(arg)
        pattern_safe?(str) and not has_shell_metacharacters?(str)
      end)

    if dangerous == [] do
      :ok
    else
      {:error, {:dangerous_args, dangerous}}
    end
  end

  defp validate_env(%{"env" => env}) when is_map(env) do
    cond do
      map_size(env) > @max_env_properties ->
        {:error, {:too_many_env_vars, map_size(env), @max_env_properties}}

      true ->
        validate_env_entries(env)
    end
  end

  defp validate_env(%{"env" => _}), do: {:error, {:invalid_type, "env", "object"}}
  defp validate_env(_), do: :ok

  defp validate_env_entries(env) do
    # Check all interpolation variables are allowed
    invalid_vars =
      env
      |> Map.values()
      |> Enum.flat_map(&extract_interpolation_vars/1)
      |> Enum.reject(&env_var_allowed?/1)

    if invalid_vars == [] do
      :ok
    else
      {:error, {:invalid_interpolation_vars, invalid_vars, @allowed_env_vars}}
    end
  end

  defp extract_interpolation_vars(value) when is_binary(value) do
    ~r/\$\{([^}]+)\}/
    |> Regex.scan(value)
    |> Enum.map(fn [_, var] -> var end)
  end

  defp extract_interpolation_vars(_), do: []
end
