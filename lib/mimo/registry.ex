defmodule Mimo.Registry do
  @moduledoc """
  ETS-based registry for tool routing with hot-reload support.
  """
  use GenServer
  require Logger

  @tools_table :mimo_tools
  @skills_table :mimo_skills

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    # Create ETS tables for tool routing
    :ets.new(@tools_table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@skills_table, [:named_table, :set, :public, read_concurrency: true])
    
    # Note: Mimo.Skills.Registry is started in Application supervisor, not here
    {:ok, %{}}
  end

  def register_skill_tools(skill_name, tools, client_pid) do
    GenServer.call(__MODULE__, {:register_tools, skill_name, tools, client_pid})
  end

  def unregister_skill(skill_name) do
    GenServer.cast(__MODULE__, {:unregister_skill, skill_name})
  end

  def list_all_tools do
    internal_tools() ++ external_tools()
  end

  defp internal_tools do
    [
      %{
        "name" => "ask_mimo",
        "description" => "Consult Mimo's memory for strategic guidance. Query the AI memory system for context, patterns, and recommendations.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "query" => %{
              "type" => "string",
              "description" => "The question or topic to consult about"
            }
          },
          "required" => ["query"]
        }
      },
      %{
        "name" => "mimo_store_memory",
        "description" => "Store a new memory/fact in Mimo's brain",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "content" => %{"type" => "string", "description" => "The content to remember"},
            "category" => %{
              "type" => "string",
              "enum" => ["fact", "action", "observation", "plan"],
              "description" => "Category of the memory"
            },
            "importance" => %{
              "type" => "number",
              "minimum" => 0,
              "maximum" => 1,
              "description" => "Importance score (0-1)"
            }
          },
          "required" => ["content", "category"]
        }
      },
      %{
        "name" => "mimo_reload_skills",
        "description" => "Hot-reload all skills from skills.json without restart",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      }
    ]
  end

  defp external_tools do
    # Use tab2list for better compatibility (ets:foldl requires OTP 25+)
    @tools_table
    |> :ets.tab2list()
    |> Enum.reduce([], fn {_key, skill_name, client_pid, tool_def}, acc ->
      if Process.alive?(client_pid) do
        prefixed_name = "#{skill_name}_#{tool_def["name"]}"
        [Map.put(tool_def, "name", prefixed_name) | acc]
      else
        acc
      end
    end)
  end

  def get_tool_owner(tool_name) do
    case tool_name do
      "ask_mimo" -> {:ok, {:internal, :ask_mimo}}
      "mimo_store_memory" -> {:ok, {:internal, :store_memory}}
      "mimo_reload_skills" -> {:ok, {:internal, :reload}}
      _ ->
        # Look up in ETS
        pattern = {tool_name, :_, :_, :_}
        case :ets.match_object(@tools_table, pattern) do
          [{_, skill_name, client_pid, _}] -> 
            {:ok, {:skill, skill_name, client_pid}}
          [] -> 
            {:error, :not_found}
        end
    end
  end

  def reload_skills do
    Logger.warning("🔄 Hot reload initiated...")
    
    # Terminate all skill clients
    @skills_table
    |> :ets.tab2list()
    |> Enum.each(fn {skill_name, _client_pid, _status} ->
      case Registry.lookup(Mimo.Skills.Registry, skill_name) do
        [{pid, _}] -> GenServer.stop(pid, :normal)
        [] -> :ok
      end
    end)
    
    # Clear tables
    :ets.delete_all_objects(@tools_table)
    :ets.delete_all_objects(@skills_table)
    
    # Re-bootstrap
    Mimo.bootstrap_skills()
    
    Logger.warning("✅ Hot reload complete")
    {:ok, :reloaded}
  end

  @impl true
  def handle_call({:register_tools, skill_name, tools, client_pid}, _from, state) do
    # Clear old entries for this skill
    :ets.match_delete(@tools_table, {:_, skill_name, :_, :_})
    
    # Insert new tools
    for tool <- tools do
      prefixed_name = "#{skill_name}_#{tool["name"]}"
      :ets.insert(@tools_table, {prefixed_name, skill_name, client_pid, tool})
    end
    
    # Track the skill
    :ets.insert(@skills_table, {skill_name, client_pid, :active})
    
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:unregister_skill, skill_name}, state) do
    :ets.match_delete(@tools_table, {:_, skill_name, :_, :_})
    :ets.delete(@skills_table, skill_name)
    {:noreply, state}
  end
end
