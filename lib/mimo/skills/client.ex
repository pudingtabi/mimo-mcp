defmodule Mimo.Skills.Client do
  @moduledoc """
  Manages a single external MCP skill process via Port.
  Includes secure execution and config validation.

  Delegates to extracted modules:
  - `Mimo.Protocol.McpParser` - JSON-RPC protocol handling
  - `Mimo.Skills.ProcessManager` - Port lifecycle management
  """
  use GenServer
  require Logger

  alias Mimo.Protocol.McpParser
  alias Mimo.Skills.ProcessManager
  alias Mimo.Skills.Validator

  defstruct [:skill_name, :port, :tool_prefix, :status, :tools, :port_monitor_ref]

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
        # Monitor the port for cleanup
        port_monitor_ref = Port.monitor(port)

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
              tools: tools,
              port_monitor_ref: port_monitor_ref
            }

            Logger.info("✓ Skill '#{skill_name}' loaded #{length(tools)} tools")
            {:ok, state}

          {:error, reason} ->
            Logger.error("✗ Skill '#{skill_name}' discovery failed: #{inspect(reason)}")
            # Ensure port is closed on discovery failure
            Port.close(port)
            {:stop, {:discovery_failed, reason}}
        end

      {:error, reason} ->
        Logger.error("✗ Skill '#{skill_name}' spawn failed: #{inspect(reason)}")
        {:stop, {:spawn_failed, reason}}
    end
  end

  # Use SecureExecutor for subprocess spawning when available
  defp spawn_subprocess_secure(config) do
    # Delegate to ProcessManager which handles SecureExecutor and fallback
    ProcessManager.spawn_subprocess(config)
  end

  defp discover_tools(port) do
    # Step 1: Send initialize request (required by MCP protocol)
    # Using McpParser for message building
    init_request = McpParser.initialize_request(1)
    Port.command(port, init_request)

    # Wait for initialize response (may get multiple messages)
    # 30s timeout to allow npx to download packages on first run
    case ProcessManager.receive_json_response(port, 30_000) do
      {:ok, %{"result" => _}} ->
        # Step 2: Send initialized notification
        initialized = McpParser.initialized_notification()
        Port.command(port, initialized)

        # Give server time to process
        Process.sleep(100)

        # Step 3: Request tools list
        list_request = McpParser.tools_list_request(2)
        Port.command(port, list_request)

        case ProcessManager.receive_json_response(port, 30_000) do
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

  @impl true
  def handle_call({:call_tool, tool_name, arguments}, _from, state) do
    # Remove skill prefix from tool name
    base_tool_name = String.replace_prefix(tool_name, "#{state.tool_prefix}_", "")

    # Use McpParser for request building
    request =
      McpParser.tools_call_request(
        base_tool_name,
        arguments,
        System.unique_integer([:positive])
      )

    Port.command(state.port, request)

    # Use ProcessManager for response handling
    case ProcessManager.receive_data(state.port, 60_000) do
      {:ok, binary_data} ->
        case Jason.decode(binary_data) do
          {:ok, %{"result" => result}} -> {:reply, {:ok, result}, state}
          {:ok, %{"error" => error}} -> {:reply, {:error, error}, state}
          {:error, _} -> {:reply, {:error, :invalid_response}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:get_tools, _from, state) do
    {:reply, state.tools, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :port, port, _reason}, %{port: port, port_monitor_ref: ref} = state) do
    Logger.error("Skill '#{state.skill_name}' port died unexpectedly")
    {:stop, {:port_died, :unexpected}, state}
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
    # Robust port cleanup
    if state.port do
      try do
        Port.close(state.port)
        Logger.debug("Closed port for skill: #{state.skill_name}")
      catch
        :error, _ ->
          Logger.debug("Port already closed for skill: #{state.skill_name}")
          :ok
      end
    end

    # Clean up port monitor
    if state.port_monitor_ref do
      Port.demonitor(state.port_monitor_ref, [:flush])
    end

    Mimo.ToolRegistry.unregister_skill(state.skill_name)
    :ok
  end
end
