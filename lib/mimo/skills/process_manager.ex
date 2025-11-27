defmodule Mimo.Skills.ProcessManager do
  @moduledoc """
  Manages Port lifecycle for external MCP skill processes.

  Responsibilities:
  - Spawning skill subprocesses via Port
  - Managing port lifecycle (spawn/kill/cleanup)
  - Handling port communication (send/receive)
  - Environment variable interpolation
  - Process cleanup coordination

  This module extracts process management logic from Client.ex
  to provide a cleaner separation of concerns.
  """
  require Logger

  alias Mimo.Skills.{SecureExecutor, Validator}

  @type port_ref :: port()
  @type spawn_result :: {:ok, port_ref()} | {:error, term()}

  # ==========================================================================
  # Port Spawning
  # ==========================================================================

  @doc """
  Spawns a subprocess for an MCP skill using secure execution.

  First attempts SecureExecutor for sandboxed execution,
  falls back to legacy spawn if rejected.

  ## Options

  Config should contain:
  - "command" - Executable command (e.g., "npx", "node")
  - "args" - List of arguments
  - "env" - Map of environment variables (supports ${VAR} interpolation)

  ## Returns

  - `{:ok, port}` on success
  - `{:error, reason}` on failure
  """
  @spec spawn_subprocess(map()) :: spawn_result()
  def spawn_subprocess(config) do
    case Validator.validate_config(config) do
      {:ok, validated_config} ->
        spawn_secure(validated_config)

      {:error, reason} ->
        Logger.error("Config validation failed: #{inspect(reason)}")
        {:error, {:validation_failed, reason}}
    end
  end

  @doc """
  Spawns using SecureExecutor, with fallback to legacy spawn.
  """
  @spec spawn_secure(map()) :: spawn_result()
  def spawn_secure(config) do
    case SecureExecutor.execute_skill(config) do
      {:ok, port} ->
        {:ok, port}

      {:error, reason} ->
        Logger.warning("SecureExecutor rejected config: #{inspect(reason)}, falling back")
        spawn_legacy(config)
    end
  end

  @doc """
  Legacy subprocess spawning (fallback when SecureExecutor fails).
  """
  @spec spawn_legacy(map()) :: spawn_result()
  def spawn_legacy(%{"command" => cmd, "args" => args} = config) do
    raw_env = Map.get(config, "env", %{})
    env_list = build_env_list(raw_env)

    case System.find_executable(cmd) do
      nil ->
        {:error, "Command not found: #{cmd}"}

      executable ->
        port_options = [
          :binary,
          :exit_status,
          :use_stdio,
          {:env, env_list},
          {:args, args}
        ]

        port = Port.open({:spawn_executable, executable}, port_options)
        {:ok, port}
    end
  end

  def spawn_legacy(_invalid_config) do
    {:error, "Invalid config: missing 'command' or 'args'"}
  end

  # ==========================================================================
  # Port Communication
  # ==========================================================================

  @doc """
  Sends a command to a port.
  """
  @spec send_command(port_ref(), String.t()) :: :ok | {:error, term()}
  def send_command(port, message) when is_port(port) and is_binary(message) do
    try do
      Port.command(port, message)
      :ok
    catch
      :error, reason ->
        {:error, reason}
    end
  end

  @doc """
  Receives data from a port with timeout.

  Handles both raw binary and line-mode tuples.
  """
  @spec receive_data(port_ref(), timeout()) :: {:ok, binary()} | {:error, term()}
  def receive_data(port, timeout \\ 30_000) do
    receive do
      {^port, {:data, data}} ->
        binary_data = normalize_port_data(data)
        {:ok, binary_data}

      {^port, {:exit_status, status}} ->
        {:error, {:process_exited, status}}
    after
      timeout ->
        {:error, :timeout}
    end
  end

  @doc """
  Receives data accumulating until a complete JSON response is found.
  """
  @spec receive_json_response(port_ref(), timeout(), String.t()) :: {:ok, map()} | {:error, term()}
  def receive_json_response(port, timeout \\ 30_000, buffer \\ "") do
    receive do
      {^port, {:data, data}} ->
        binary_data = normalize_port_data(data)
        new_buffer = buffer <> binary_data

        case find_json_response(new_buffer) do
          {:ok, response, _rest} ->
            {:ok, response}

          :incomplete ->
            receive_json_response(port, timeout, new_buffer)
        end

      {^port, {:exit_status, status}} ->
        {:error, {:process_exited, status}}
    after
      timeout ->
        {:error, :discovery_timeout}
    end
  end

  # ==========================================================================
  # Port Lifecycle
  # ==========================================================================

  @doc """
  Safely closes a port, handling already-closed cases.
  """
  @spec close_port(port_ref() | nil) :: :ok
  def close_port(nil), do: :ok

  def close_port(port) when is_port(port) do
    try do
      case Port.info(port) do
        nil ->
          Logger.debug("Port already closed")
          :ok

        _info ->
          Port.close(port)
          :ok
      end
    catch
      :error, _ ->
        Logger.debug("Port cleanup failed, already dead")
        :ok
    end
  end

  @doc """
  Checks if a port is still alive.
  """
  @spec port_alive?(port_ref()) :: boolean()
  def port_alive?(port) when is_port(port) do
    Port.info(port) != nil
  end

  def port_alive?(_), do: false

  @doc """
  Gets port info or nil if port is dead.
  """
  @spec port_info(port_ref()) :: list() | nil
  def port_info(port) when is_port(port) do
    Port.info(port)
  rescue
    _ -> nil
  end

  # ==========================================================================
  # Private Helpers
  # ==========================================================================

  defp build_env_list(raw_env) when is_map(raw_env) do
    Enum.map(raw_env, fn {k, v} ->
      final_value = interpolate_env(v)
      {String.to_charlist(k), String.to_charlist(final_value)}
    end)
  end

  defp build_env_list(_), do: []

  # Interpolate ${VAR_NAME} patterns with actual env values
  defp interpolate_env(value) when is_binary(value) do
    Regex.replace(~r/\$\{([^}]+)\}/, value, fn _, var_name ->
      System.get_env(var_name) || ""
    end)
  end

  defp interpolate_env(value), do: to_string(value)

  # Normalize port data to binary (handles both raw and line-mode)
  defp normalize_port_data({:eol, line}), do: line <> "\n"
  defp normalize_port_data({:noeol, chunk}), do: chunk
  defp normalize_port_data(bin) when is_binary(bin), do: bin
  defp normalize_port_data(other), do: inspect(other)

  # Find a valid JSON-RPC response in buffer
  defp find_json_response(buffer) do
    buffer
    |> String.split("\n", trim: true)
    |> Enum.reduce_while(:incomplete, fn line, _acc ->
      case Jason.decode(line) do
        {:ok, %{"jsonrpc" => "2.0"} = response} ->
          {:halt, {:ok, response, ""}}

        _ ->
          {:cont, :incomplete}
      end
    end)
  end
end
