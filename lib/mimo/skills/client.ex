defmodule Mimo.Skills.Client do
  @moduledoc """
  Manages a single external MCP skill process via Port.
  Includes secure execution and config validation.
  """
  use GenServer
  require Logger

  alias Mimo.Skills.SecureExecutor
  alias Mimo.Skills.Validator

  defstruct [:skill_name, :port, :tool_prefix, :status, :tools]

  def start_link(skill_name, config) do
    GenServer.start_link(__MODULE__, {skill_name, config}, name: via_tuple(skill_name))
  end

  def call_tool(skill_name, tool_name, arguments) do
    GenServer.call(via_tuple(skill_name), {:call_tool, tool_name, arguments}, 60_000)
  end

  @doc """
  Synchronous one-shot tool call - spawns process, calls tool, returns result.
  Used by McpCli for stdio mode.
  """
  def call_tool_sync(skill_name, config, tool_name, arguments) do
    # Check if skill is already running
    case Registry.lookup(Mimo.Skills.Registry, skill_name) do
      [{pid, _}] when is_pid(pid) ->
        if Process.alive?(pid) do
          call_tool(skill_name, tool_name, arguments)
        else
          spawn_and_call(skill_name, config, tool_name, arguments)
        end

      [] ->
        spawn_and_call(skill_name, config, tool_name, arguments)
    end
  end

  defp spawn_and_call(skill_name, config, tool_name, arguments) do
    child_spec = %{
      id: {__MODULE__, skill_name},
      start: {__MODULE__, :start_link, [skill_name, config]},
      restart: :transient,
      shutdown: 30_000
    }

    case DynamicSupervisor.start_child(Mimo.Skills.Supervisor, child_spec) do
      {:ok, _pid} -> call_tool(skill_name, tool_name, arguments)
      {:error, {:already_started, _pid}} -> call_tool(skill_name, tool_name, arguments)
      {:error, reason} -> {:error, reason}
    end
  end

  def get_tools(skill_name) do
    GenServer.call(via_tuple(skill_name), :get_tools)
  end

  defp via_tuple(skill_name) do
    {:via, Registry, {Mimo.Skills.Registry, skill_name}}
  end

  @impl true
  def init({skill_name, config}) do
    Process.flag(:trap_exit, true)
    Logger.info("Starting skill: #{skill_name}")

    # Validate config before spawning
    case Validator.validate_config(config) do
      {:ok, validated_config} ->
        spawn_with_validated_config(skill_name, validated_config)

      {:error, reason} ->
        Logger.error("✗ Skill '#{skill_name}' config validation failed: #{inspect(reason)}")
        {:stop, {:validation_failed, reason}}
    end
  end

  defp spawn_with_validated_config(skill_name, config) do
    case spawn_subprocess_secure(config) do
      {:ok, port} ->
        # Give the process time to start
        Process.sleep(1000)

        case discover_tools(port) do
          {:ok, tools} ->
            # Register with the thread-safe registry
            Mimo.ToolRegistry.register_skill_tools(skill_name, tools, self())

            state = %__MODULE__{
              skill_name: skill_name,
              port: port,
              tool_prefix: skill_name,
              status: :active,
              tools: tools
            }

            Logger.info("✓ Skill '#{skill_name}' loaded #{length(tools)} tools")
            {:ok, state}

          {:error, reason} ->
            Logger.error("✗ Skill '#{skill_name}' discovery failed: #{inspect(reason)}")
            {:stop, {:discovery_failed, reason}}
        end

      {:error, reason} ->
        Logger.error("✗ Skill '#{skill_name}' spawn failed: #{inspect(reason)}")
        {:stop, {:spawn_failed, reason}}
    end
  end

  # Use SecureExecutor for subprocess spawning when available
  defp spawn_subprocess_secure(config) do
    case SecureExecutor.execute_skill(config) do
      {:ok, port} ->
        {:ok, port}

      {:error, reason} ->
        Logger.warning(
          "SecureExecutor rejected config: #{inspect(reason)}, falling back to legacy spawn"
        )

        spawn_subprocess(config)
    end
  end

  # Legacy subprocess spawning (fallback)
  defp spawn_subprocess(%{"command" => cmd, "args" => args} = config) do
    raw_env = Map.get(config, "env", %{})

    env_list =
      Enum.map(raw_env, fn {k, v} ->
        final_value = interpolate_env(v)
        {String.to_charlist(k), String.to_charlist(final_value)}
      end)

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

  defp spawn_subprocess(_invalid_config) do
    {:error, "Invalid config: missing 'command' or 'args'"}
  end

  # Interpolate ${VAR_NAME} patterns with actual env values
  defp interpolate_env(value) when is_binary(value) do
    Regex.replace(~r/\$\{([^}]+)\}/, value, fn _, var_name ->
      System.get_env(var_name) || ""
    end)
  end

  defp interpolate_env(value), do: to_string(value)

  defp discover_tools(port) do
    # Step 1: Send initialize request (required by MCP protocol)
    init_request =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2024-11-05",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "mimo-mcp", "version" => "2.3.0"}
        },
        "id" => 1
      })

    Port.command(port, init_request <> "\n")

    # Wait for initialize response (may get multiple messages)
    # 30s timeout to allow npx to download packages on first run
    case wait_for_json_response(port, 30_000) do
      {:ok, %{"result" => _}} ->
        # Step 2: Send initialized notification
        initialized =
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "method" => "notifications/initialized"
          })

        Port.command(port, initialized <> "\n")

        # Give server time to process
        Process.sleep(100)

        # Step 3: Request tools list
        list_request =
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "method" => "tools/list",
            "id" => 2
          })

        Port.command(port, list_request <> "\n")

        case wait_for_json_response(port, 30_000) do
          {:ok, %{"result" => %{"tools" => tools}}} -> {:ok, tools}
          {:ok, %{"error" => error}} -> {:error, {:mcp_error, error}}
          {:error, reason} -> {:error, reason}
        end

      {:ok, %{"error" => error}} ->
        {:error, {:init_error, error}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Wait for a valid JSON response, accumulating data across multiple receives
  defp wait_for_json_response(port, timeout) do
    wait_for_json_response(port, timeout, "")
  end

  defp wait_for_json_response(port, timeout, buffer) do
    receive do
      {^port, {:data, data}} ->
        # Handle both raw binary and line-mode tuples
        binary_data = case data do
          {:eol, line} -> line <> "\n"
          {:noeol, chunk} -> chunk
          bin when is_binary(bin) -> bin
          other -> inspect(other)
        end
        new_buffer = buffer <> binary_data

        # Try to parse each line as JSON
        case find_json_response(new_buffer) do
          {:ok, response, _rest} ->
            {:ok, response}

          :incomplete ->
            # Keep accumulating
            wait_for_json_response(port, timeout, new_buffer)
        end

      {^port, {:exit_status, status}} ->
        {:error, {:process_exited, status}}
    after
      timeout -> {:error, :discovery_timeout}
    end
  end

  # Find a valid JSON-RPC response in the buffer (handles multi-line output)
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

  @impl true
  def handle_call({:call_tool, tool_name, arguments}, _from, state) do
    # Remove skill prefix from tool name
    base_tool_name = String.replace_prefix(tool_name, "#{state.tool_prefix}_", "")

    request =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "params" => %{"name" => base_tool_name, "arguments" => arguments},
        "id" => System.unique_integer([:positive])
      })

    # Use Port.command/2 for proper port communication
    Port.command(state.port, request <> "\n")

    receive do
      {_, {:data, data}} ->
        # Handle both raw binary and line-mode tuples
        binary_data = case data do
          {:eol, line} -> line
          {:noeol, chunk} -> chunk
          bin when is_binary(bin) -> bin
          other -> inspect(other)
        end
        case Jason.decode(binary_data) do
          {:ok, %{"result" => result}} -> {:reply, {:ok, result}, state}
          {:ok, %{"error" => error}} -> {:reply, {:error, error}, state}
          {:error, _} -> {:reply, {:error, :invalid_response}, state}
        end
    after
      60_000 -> {:reply, {:error, :timeout}, state}
    end
  end

  @impl true
  def handle_call(:get_tools, _from, state) do
    {:reply, state.tools, state}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("Skill '#{state.skill_name}' exited with status: #{status}")
    {:stop, {:subprocess_exited, status}, state}
  end

  @impl true
  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logger.error("Skill '#{state.skill_name}' subprocess crashed: #{inspect(reason)}")
    {:stop, {:subprocess_crashed, reason}, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Skill '#{state.skill_name}' received: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.port do
      Port.close(state.port)
    end

    Mimo.ToolRegistry.unregister_skill(state.skill_name)
    :ok
  end
end
