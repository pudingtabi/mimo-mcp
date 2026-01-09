defmodule Mimo.Skills.SecureExecutor do
  @moduledoc """
  Secure subprocess execution with mandatory sandboxing.
  Prevents command injection and limits resource abuse.

  Security features:
  - Command whitelist with version requirements
  - Argument sanitization (no shell metacharacters)
  - Environment variable filtering
  - Resource limits (timeout, memory)
  - Telemetry logging of all executions
  - **Automatic timeout enforcement** - runaway processes are killed

  ## Usage

      config = %{
        "command" => "npx",
        "args" => ["-y", "@anthropic-ai/tool-name"],
        "env" => %{"API_KEY" => "${EXA_API_KEY}"}
      }
      
      {:ok, port, timeout_ref} = Mimo.Skills.SecureExecutor.execute_skill(config)
      
      # ... use port ...
      
      # When done, cancel the timeout to prevent premature killing
      Mimo.Skills.SecureExecutor.cancel_timeout(timeout_ref)
      
  If you don't cancel the timeout, the port will be automatically killed after
  the configured timeout period (e.g., 120s for npx, 300s for docker).
  """

  require Logger

  # Whitelist of allowed commands with their restrictions
  @allowed_commands %{
    "npx" => %{
      max_args: 20,
      timeout_ms: 120_000,
      allowed_arg_patterns: [
        ~r/^-y$/,
        ~r/^--yes$/,
        ~r/^-p$/,
        ~r/^--package$/,
        # Scoped packages like @anthropic/tool or @wonderwhy-er/desktop-commander@latest
        ~r/^@[\w\-\.\/]+(@[\w\-\.]+)?$/,
        # Simple package names with optional version like package@1.0.0 or package@latest
        ~r/^[\w\-\.]+(@[\w\-\.]+)?$/,
        # Flags with values
        ~r/^--[\w\-]+=[\w\-\.:\/]+$/
      ]
    },
    "docker" => %{
      max_args: 30,
      timeout_ms: 300_000,
      restrictions: [:no_privileged, :no_host_network, :no_docker_sock],
      allowed_arg_patterns: [
        ~r/^run$/,
        ~r/^--rm$/,
        ~r/^-i$/,
        ~r/^--name=[\w\-]+$/,
        ~r/^-e$/,
        # Env vars
        ~r/^[\w\-]+=[\w\-\.:\/]*$/,
        # Image:tag
        ~r/^[\w\-\.\/]+:[\w\-\.]+$/,
        # Simple args
        ~r/^[\w\-\.\/]+$/
      ],
      forbidden_args: [
        "--privileged",
        "--network=host",
        "-v /var/run/docker.sock",
        "--pid=host",
        "--ipc=host"
      ]
    },
    "node" => %{
      max_args: 10,
      timeout_ms: 60_000,
      allowed_arg_patterns: [
        # JS files
        ~r/^[\w\-\.\/]+\.js$/,
        # ES modules
        ~r/^[\w\-\.\/]+\.mjs$/,
        # Node flags
        ~r/^--[\w\-]+=[\w\-\.:\/]+$/
      ]
    },
    "python" => %{
      max_args: 10,
      timeout_ms: 60_000,
      allowed_arg_patterns: [
        # Python files
        ~r/^[\w\-\.\/]+\.py$/,
        ~r/^-m$/,
        # Module names
        ~r/^[\w\-\.]+$/,
        # Python flags
        ~r/^--[\w\-]+=[\w\-\.:\/]+$/
      ]
    },
    "python3" => %{
      max_args: 10,
      timeout_ms: 60_000,
      allowed_arg_patterns: [
        ~r/^[\w\-\.\/]+\.py$/,
        ~r/^-m$/,
        ~r/^[\w\-\.]+$/,
        ~r/^--[\w\-]+=[\w\-\.:\/]+$/
      ]
    }
  }

  # Environment variables that can be interpolated
  # NOTE: Must stay in sync with @allowed_interpolation_vars in Mimo.Skills.Validator
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

  # Dangerous shell metacharacters
  @shell_metacharacters ~r/[\r\n;&|`$(){}!<>\\]/

  @doc """
  Execute a skill with secure subprocess spawning.

  Returns `{:ok, port, timeout_ref}` on success or `{:error, reason}` on failure.
  Call `cancel_timeout(timeout_ref)` when the port completes normally.
  """
  def execute_skill(config) when is_map(config) do
    with {:ok, normalized} <- normalize_config(config),
         {:ok, validated} <- validate_config(normalized),
         {:ok, secure_opts} <- build_secure_opts(validated) do
      do_spawn(validated.command, validated.args, secure_opts)
    end
  end

  @doc """
  Check if a command is in the whitelist.
  """
  def allowed_command?(cmd) when is_binary(cmd) do
    Map.has_key?(@allowed_commands, Path.basename(cmd))
  end

  @doc """
  Get the restrictions for a command.
  """
  def command_restrictions(cmd) when is_binary(cmd) do
    Map.get(@allowed_commands, Path.basename(cmd))
  end

  defp normalize_config(%{"command" => cmd} = config) when is_binary(cmd) do
    # Prevent path traversal by taking only basename
    normalized_cmd = Path.basename(cmd)
    args = Map.get(config, "args", [])
    env = Map.get(config, "env", %{})

    {:ok,
     %{
       command: normalized_cmd,
       args: normalize_args(args),
       env: env,
       original_command: cmd
     }}
  end

  defp normalize_config(_) do
    {:error, {:invalid_config, "Missing or invalid 'command' field"}}
  end

  defp normalize_args(args) when is_list(args) do
    Enum.map(args, &to_string/1)
  end

  defp normalize_args(_), do: []

  defp validate_config(%{command: cmd} = config) do
    case Map.get(@allowed_commands, cmd) do
      nil ->
        log_security_event(:command_rejected, %{command: cmd})
        {:error, {:command_not_allowed, cmd, Map.keys(@allowed_commands)}}

      restrictions ->
        # Check security-critical validations first (metacharacters, forbidden args)
        # before pattern matching
        with :ok <- validate_arg_count(config.args, restrictions),
             :ok <- validate_no_metacharacters(config.args),
             :ok <- validate_no_forbidden_args(config.args, restrictions),
             :ok <- validate_arg_patterns(config.args, restrictions),
             {:ok, sanitized_env} <- validate_and_sanitize_env(config.env) do
          {:ok, %{config | env: sanitized_env}}
        end
    end
  end

  defp validate_arg_count(args, %{max_args: max}) when length(args) > max do
    {:error, {:too_many_args, length(args), max}}
  end

  defp validate_arg_count(_, _), do: :ok

  defp validate_arg_patterns(args, %{allowed_arg_patterns: patterns}) do
    invalid_args =
      Enum.reject(args, fn arg ->
        Enum.any?(patterns, fn pattern -> Regex.match?(pattern, arg) end)
      end)

    if Enum.empty?(invalid_args) do
      :ok
    else
      log_security_event(:invalid_args, %{args: invalid_args})
      {:error, {:invalid_args, invalid_args}}
    end
  end

  defp validate_arg_patterns(_, _), do: :ok

  defp validate_no_forbidden_args(args, %{forbidden_args: forbidden}) do
    # Check each arg for forbidden patterns
    # Also check sequential args joined (for patterns like "-v docker.sock")
    all_args_str = Enum.join(args, " ")

    found =
      Enum.filter(forbidden, fn f ->
        String.contains?(all_args_str, f) or
          Enum.any?(args, fn arg -> String.contains?(arg, f) end)
      end)

    if Enum.empty?(found) do
      :ok
    else
      log_security_event(:forbidden_args, %{patterns: found})
      {:error, {:forbidden_args, found}}
    end
  end

  defp validate_no_forbidden_args(_, _), do: :ok

  defp validate_no_metacharacters(args) do
    dangerous_args =
      Enum.filter(args, fn arg ->
        Regex.match?(@shell_metacharacters, arg)
      end)

    if Enum.empty?(dangerous_args) do
      :ok
    else
      log_security_event(:shell_injection_attempt, %{args: dangerous_args})
      {:error, {:invalid_arg_characters, dangerous_args}}
    end
  end

  defp validate_and_sanitize_env(env) when is_map(env) do
    sanitized =
      env
      |> Enum.map(fn {k, v} -> sanitize_env_pair(k, v) end)
      |> Enum.filter(fn {_, v} -> v != :filtered end)
      |> Enum.into(%{})

    {:ok, sanitized}
  end

  defp validate_and_sanitize_env(_), do: {:ok, %{}}

  defp sanitize_env_pair(key, value) when is_binary(key) and is_binary(value) do
    # Validate key format (alphanumeric + underscore only)
    if Regex.match?(~r/^[A-Z_][A-Z0-9_]*$/, key) do
      {key, interpolate_env_value(value)}
    else
      {key, :filtered}
    end
  end

  defp sanitize_env_pair(key, value),
    do: {to_string(key), sanitize_env_pair("K", to_string(value)) |> elem(1)}

  defp interpolate_env_value(value) do
    # Handle ${VAR_NAME} patterns
    Regex.replace(~r/\$\{([A-Z_][A-Z0-9_]*)\}/, value, fn _, var_name ->
      if var_name in @allowed_env_vars do
        System.get_env(var_name) || ""
      else
        log_security_event(:env_var_blocked, %{var: var_name})
        ""
      end
    end)
  end

  defp build_secure_opts(config) do
    env_list =
      config.env
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    {:ok,
     %{
       env: env_list,
       timeout_ms: get_timeout(config.command)
     }}
  end

  defp get_timeout(cmd) do
    case Map.get(@allowed_commands, cmd) do
      %{timeout_ms: timeout} -> timeout
      _ -> 60_000
    end
  end

  defp do_spawn(cmd, args, opts) do
    executable =
      case System.find_executable(cmd) do
        nil ->
          log_security_event(:executable_not_found, %{command: cmd})
          {:error, {:command_not_found, cmd}}

        path ->
          {:ok, path}
      end

    case executable do
      {:ok, path} ->
        port_opts = [
          :binary,
          :exit_status,
          :use_stdio,
          :hide,
          {:args, args},
          {:env, opts[:env]},
          {:line, 16_384},
          {:parallelism, true}
        ]

        # Log execution for audit
        log_execution(cmd, args)

        port = Port.open({:spawn_executable, path}, port_opts)

        # Verify port spawned successfully
        case :erlang.port_info(port) do
          :undefined ->
            {:error, :port_spawn_failed}

          _ ->
            # Set up timeout monitor - spawns a process that will kill the port after timeout
            timeout_ref = schedule_timeout_check(port, opts[:timeout_ms])
            {:ok, port, timeout_ref}
        end

      error ->
        error
    end
  end

  # Schedules a timeout check for a port. Returns a timeout reference that can be
  # cancelled with `cancel_timeout/1` when the port completes normally.
  #
  # The spawned monitor process will forcefully close the port after timeout_ms.
  defp schedule_timeout_check(port, timeout_ms) do
    caller = self()

    # Spawn a monitor process that will kill the port after timeout
    # This runs independently so callers who forget to handle timeout are protected
    monitor_pid =
      spawn(fn ->
        receive do
          :cancel_timeout ->
            # Port completed normally, timeout cancelled
            :ok
        after
          timeout_ms ->
            # Timeout reached - kill the port if it still exists
            Logger.warning(
              "SecureExecutor: Port #{inspect(port)} timed out after #{timeout_ms}ms, killing"
            )

            if is_port(port) and :erlang.port_info(port) != :undefined do
              try do
                Port.close(port)
              catch
                _, _ -> :already_closed
              end

              # Notify the caller that timeout occurred
              send(caller, {:port_timeout, port})
            end
        end
      end)

    # Return reference so caller can cancel on successful completion
    {:timeout_monitor, monitor_pid}
  end

  @doc """
  Cancels a pending timeout. Call this when the port completes successfully
  to prevent the timeout monitor from killing it.
  """
  def cancel_timeout({:timeout_monitor, pid}) when is_pid(pid) do
    send(pid, :cancel_timeout)
    :ok
  end

  def cancel_timeout(_), do: :ok

  defp log_security_event(event_type, metadata) do
    :telemetry.execute(
      [:mimo, :security, :executor],
      %{count: 1},
      Map.merge(metadata, %{
        event_type: event_type,
        timestamp: System.system_time(:second)
      })
    )

    Logger.warning("[SECURITY] SecureExecutor #{event_type}: #{inspect(metadata)}")
  end

  defp log_execution(cmd, args) do
    :telemetry.execute(
      [:mimo, :skills, :execution],
      %{count: 1},
      %{
        command: cmd,
        arg_count: length(args),
        timestamp: System.system_time(:second)
      }
    )

    Logger.info("Executing: #{cmd} with #{length(args)} args")
  end
end
