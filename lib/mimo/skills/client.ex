defmodule Mimo.Skills.Client do
  @moduledoc """
  Manages a single external MCP skill process via Port.
  Includes ENV var interpolation fix.
  """
  use GenServer
  require Logger

  defstruct [:skill_name, :port, :tool_prefix, :status, :tools]

  def start_link(skill_name, config) do
    GenServer.start_link(__MODULE__, {skill_name, config}, name: via_tuple(skill_name))
  end

  def call_tool(skill_name, tool_name, arguments) do
    GenServer.call(via_tuple(skill_name), {:call_tool, tool_name, arguments}, 60_000)
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

    case spawn_subprocess(config) do
      {:ok, port} ->
        # Give the process time to start
        Process.sleep(1000)
        
        case discover_tools(port) do
          {:ok, tools} ->
            Mimo.Registry.register_skill_tools(skill_name, tools, self())
            
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

  # FIX #1: Environment Variable Interpolation
  defp spawn_subprocess(%{"command" => cmd, "args" => args} = config) do
    raw_env = Map.get(config, "env", %{}) 
    
    env_list = Enum.map(raw_env, fn {k, v} -> 
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
    request = Jason.encode!(%{
      "jsonrpc" => "2.0",
      "method" => "tools/list",
      "id" => 1
    })

    # Use Port.command/2 for proper port communication
    Port.command(port, request <> "\n")
    
    receive do
      {^port, {:data, data}} ->
        case Jason.decode(data) do
          {:ok, %{"result" => %{"tools" => tools}}} -> {:ok, tools}
          {:ok, %{"error" => error}} -> {:error, {:mcp_error, error}}
          {:error, _} -> {:error, :invalid_json}
        end
    after
      15_000 -> {:error, :discovery_timeout}
    end
  end

  @impl true
  def handle_call({:call_tool, tool_name, arguments}, _from, state) do
    # Remove skill prefix from tool name
    base_tool_name = String.replace_prefix(tool_name, "#{state.tool_prefix}_", "")
    
    request = Jason.encode!(%{
      "jsonrpc" => "2.0",
      "method" => "tools/call",
      "params" => %{"name" => base_tool_name, "arguments" => arguments},
      "id" => System.unique_integer([:positive])
    })

    # Use Port.command/2 for proper port communication
    Port.command(state.port, request <> "\n")
    
    receive do
      {_, {:data, data}} ->
        case Jason.decode(data) do
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
    Mimo.Registry.unregister_skill(state.skill_name)
    :ok
  end
end
