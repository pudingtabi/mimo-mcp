defmodule Mimo.Skills.Validator do
  @moduledoc """
  JSON Schema validation for skill configurations.
  Prevents injection via malformed configs.

  All skill configurations must pass validation before execution.
  This module enforces:
  - Command whitelist
  - Argument limits and patterns
  - Environment variable restrictions
  - Additional property rejection

  ## Usage

      config = %{
        "command" => "npx",
        "args" => ["-y", "@anthropic-ai/mcp-server-memory"],
        "env" => %{"MEMORY_PATH" => "/data/memory.json"}
      }
      
      {:ok, validated} = Mimo.Skills.Validator.validate_config(config)
  """

  require Logger

  # Command whitelist - only these commands can be executed
  @allowed_commands ~w(npx docker node python python3)

  # Maximum values for array/object properties
  @max_args 30
  @max_env_properties 30
  @max_string_length 1024

  # Environment variable name pattern
  @env_var_pattern ~r/^[A-Z_][A-Z0-9_]*$/

  # Allowed environment variables for interpolation
  @allowed_interpolation_vars ~w(
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

  # Dangerous patterns in arguments
  @dangerous_patterns [
    # Shell metacharacters
    ~r/[;&|`$(){}!<>\\]/,
    # Path traversal
    ~r/\.\.\//,
    # System config access
    ~r/^\/etc\//,
    # Docker socket
    ~r/^\/var\/run\/docker\.sock/,
    # Docker privileged mode
    ~r/--privileged/,
    # Docker host network
    ~r/--network=host/,
    # Docker PID namespace
    ~r/--pid=host/,
    # Docker capabilities
    ~r/--cap-add/
  ]

  @doc """
  Validate a skill configuration.

  Returns `{:ok, config}` if valid, or `{:error, reason}` if invalid.
  """
  def validate_config(config) when is_map(config) do
    # Normalize string keys
    normalized = normalize_keys(config)

    with :ok <- validate_required_fields(normalized),
         :ok <- validate_command(normalized),
         :ok <- validate_args(normalized),
         :ok <- validate_env(normalized),
         :ok <- validate_no_extra_fields(normalized) do
      {:ok, normalized}
    end
  end

  def validate_config(nil) do
    {:error, {:invalid_config, "Config cannot be nil"}}
  end

  def validate_config(_) do
    {:error, {:invalid_config, "Config must be a map"}}
  end

  @doc """
  Validate a batch of skill configurations.

  Returns `{:ok, configs}` if all valid, or `{:error, errors}` with list of failures.
  """
  def validate_configs(configs) when is_list(configs) do
    results =
      Enum.with_index(configs, fn config, idx ->
        case validate_config(config) do
          {:ok, validated} -> {:ok, idx, validated}
          {:error, reason} -> {:error, idx, reason}
        end
      end)

    errors = Enum.filter(results, fn {status, _, _} -> status == :error end)

    if errors == [] do
      {:ok, Enum.map(results, fn {:ok, _, config} -> config end)}
    else
      {:error, Enum.map(errors, fn {:error, idx, reason} -> {idx, reason} end)}
    end
  end

  @doc """
  Check if a specific argument is safe.
  """
  def safe_arg?(arg) when is_binary(arg) do
    not Enum.any?(@dangerous_patterns, fn pattern ->
      Regex.match?(pattern, arg)
    end)
  end

  def safe_arg?(_), do: false

  @doc """
  Check if an environment variable name is valid.
  """
  def valid_env_var_name?(name) when is_binary(name) do
    Regex.match?(@env_var_pattern, name)
  end

  def valid_env_var_name?(_), do: false

  @doc """
  Check if an interpolation variable is allowed.
  """
  def allowed_interpolation?(var_name) when is_binary(var_name) do
    var_name in @allowed_interpolation_vars
  end

  def allowed_interpolation?(_), do: false

  defp normalize_keys(config) when is_map(config) do
    config
    |> Enum.map(fn {k, v} -> {to_string(k), normalize_value(v)} end)
    |> Enum.into(%{})
  end

  defp normalize_value(v) when is_map(v), do: normalize_keys(v)
  defp normalize_value(v) when is_list(v), do: Enum.map(v, &normalize_value/1)
  defp normalize_value(v), do: v

  defp validate_required_fields(config) do
    case Map.get(config, "command") do
      nil -> {:error, {:missing_field, "command"}}
      "" -> {:error, {:empty_field, "command"}}
      cmd when is_binary(cmd) -> :ok
      _ -> {:error, {:invalid_type, "command", "string"}}
    end
  end

  defp validate_command(config) do
    cmd = Map.get(config, "command")
    basename = Path.basename(cmd)

    cond do
      basename != cmd ->
        # Command contains path separators - potential path traversal
        log_validation_failure(:path_in_command, %{command: cmd})
        {:error, {:invalid_command, "Command must not contain path separators"}}

      basename not in @allowed_commands ->
        log_validation_failure(:command_not_allowed, %{command: basename})
        {:error, {:command_not_allowed, basename, @allowed_commands}}

      true ->
        :ok
    end
  end

  defp validate_args(%{"args" => args}) when is_list(args) do
    cond do
      length(args) > @max_args ->
        {:error, {:too_many_args, length(args), @max_args}}

      not Enum.all?(args, &is_binary/1) and not Enum.all?(args, &is_number/1) ->
        {:error, {:invalid_arg_type, "Args must be strings or numbers"}}

      true ->
        validate_arg_safety(args)
    end
  end

  defp validate_args(%{"args" => args}) when not is_list(args) do
    {:error, {:invalid_type, "args", "array"}}
  end

  # args is optional
  defp validate_args(_), do: :ok

  defp validate_arg_safety(args) do
    dangerous_args =
      args
      |> Enum.map(&to_string/1)
      |> Enum.reject(&safe_arg?/1)

    if Enum.empty?(dangerous_args) do
      validate_arg_lengths(args)
    else
      log_validation_failure(:dangerous_args, %{args: dangerous_args})
      {:error, {:dangerous_args, dangerous_args}}
    end
  end

  defp validate_arg_lengths(args) do
    long_args =
      Enum.filter(args, fn arg ->
        String.length(to_string(arg)) > @max_string_length
      end)

    if Enum.empty?(long_args) do
      :ok
    else
      {:error, {:arg_too_long, @max_string_length}}
    end
  end

  defp validate_env(%{"env" => env}) when is_map(env) do
    if map_size(env) > @max_env_properties do
      {:error, {:too_many_env_vars, map_size(env), @max_env_properties}}
    else
      validate_env_entries(env)
    end
  end

  defp validate_env(%{"env" => env}) when not is_map(env) do
    {:error, {:invalid_type, "env", "object"}}
  end

  # env is optional
  defp validate_env(_), do: :ok

  defp validate_env_entries(env) do
    invalid_keys =
      env
      |> Map.keys()
      |> Enum.reject(&valid_env_var_name?/1)

    if invalid_keys != [] do
      {:error, {:invalid_env_var_names, invalid_keys}}
    else
      validate_env_values(env)
    end
  end

  defp validate_env_values(env) do
    results =
      Enum.map(env, fn {k, v} ->
        validate_env_value(k, v)
      end)

    case Enum.find(results, fn r -> r != :ok end) do
      nil -> :ok
      error -> error
    end
  end

  defp validate_env_value(key, value) when is_binary(value) do
    if String.length(value) > @max_string_length do
      {:error, {:env_value_too_long, key, @max_string_length}}
    else
      validate_interpolation(key, value)
    end
  end

  defp validate_env_value(_key, value) when is_number(value), do: :ok

  defp validate_env_value(key, _value) do
    {:error, {:invalid_env_value_type, key, "string or number"}}
  end

  defp validate_interpolation(key, value) do
    # Find all ${VAR} patterns
    interpolations = Regex.scan(~r/\$\{([^}]+)\}/, value)

    invalid_vars =
      interpolations
      |> Enum.map(fn [_, var] -> var end)
      |> Enum.reject(&allowed_interpolation?/1)

    if Enum.empty?(invalid_vars) do
      :ok
    else
      log_validation_failure(:invalid_interpolation, %{key: key, vars: invalid_vars})
      {:error, {:invalid_interpolation, key, invalid_vars, @allowed_interpolation_vars}}
    end
  end

  defp validate_no_extra_fields(config) do
    allowed_fields = ~w(command args env)
    extra_fields = Map.keys(config) -- allowed_fields

    if Enum.empty?(extra_fields) do
      :ok
    else
      {:error, {:extra_fields, extra_fields, allowed_fields}}
    end
  end

  defp log_validation_failure(reason, metadata) do
    :telemetry.execute(
      [:mimo, :skills, :validation_failure],
      %{count: 1},
      Map.merge(metadata, %{
        reason: reason,
        timestamp: System.system_time(:second)
      })
    )

    Logger.warning("[VALIDATION] Skill config rejected: #{reason} - #{inspect(metadata)}")
  end
end
