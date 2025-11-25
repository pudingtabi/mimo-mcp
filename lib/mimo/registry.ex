defmodule Mimo.Registry do
  @moduledoc """
  ETS-based registry for tool routing with lazy-loading support.
  Tools are advertised from catalog, skills spawn on-demand.
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
    :ets.new(@tools_table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@skills_table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  def register_skill_tools(skill_name, tools, client_pid) do
    GenServer.call(__MODULE__, {:register_tools, skill_name, tools, client_pid})
  end

  def unregister_skill(skill_name) do
    GenServer.cast(__MODULE__, {:unregister_skill, skill_name})
  end

  @doc """
  List all available tools - internal + catalog (lazy) + active skills.
  """
  def list_all_tools do
    internal_tools() ++ catalog_tools() ++ active_skill_tools()
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

  # Tools from pre-generated manifest (instant, no process)
  defp catalog_tools do
    if Code.ensure_loaded?(Mimo.Skills.Catalog) do
      try do
        Mimo.Skills.Catalog.list_tools()
      rescue
        _ -> []
      end
    else
      []
    end
  end

  # Tools from already-running skill processes
  defp active_skill_tools do
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

  @doc """
  Get tool owner - checks internal, then catalog (lazy-spawn), then active.
  """
  def get_tool_owner(tool_name) do
    case tool_name do
      "ask_mimo" -> {:ok, {:internal, :ask_mimo}}
      "mimo_store_memory" -> {:ok, {:internal, :store_memory}}
      "mimo_reload_skills" -> {:ok, {:internal, :reload}}
      _ ->
        # First check active skills
        case lookup_active_skill(tool_name) do
          {:ok, _} = result -> result
          {:error, :not_found} ->
            # Try catalog (will lazy-spawn if found)
            lookup_catalog_skill(tool_name)
        end
    end
  end

  defp lookup_active_skill(tool_name) do
    pattern = {tool_name, :_, :_, :_}
    case :ets.match_object(@tools_table, pattern) do
      [{_, skill_name, client_pid, _}] -> 
        if Process.alive?(client_pid) do
          {:ok, {:skill, skill_name, client_pid}}
        else
          {:error, :not_found}
        end
      [] -> 
        {:error, :not_found}
    end
  end

  defp lookup_catalog_skill(tool_name) do
    if Code.ensure_loaded?(Mimo.Skills.Catalog) do
      case Mimo.Skills.Catalog.get_skill_for_tool(tool_name) do
        {:ok, skill_name, config} ->
          # Lazy spawn the skill
          case ensure_skill_running(skill_name, config) do
            {:ok, pid} -> {:ok, {:skill, skill_name, pid}}
            {:error, reason} -> {:error, {:spawn_failed, reason}}
          end
        {:error, :not_found} ->
          {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  defp ensure_skill_running(skill_name, config) do
    case Registry.lookup(Mimo.Skills.Registry, skill_name) do
      [{pid, _}] when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: start_skill(skill_name, config)
      [] ->
        start_skill(skill_name, config)
    end
  end

  defp start_skill(skill_name, config) do
    Logger.info("🚀 Lazy-spawning skill: #{skill_name}")
    child_spec = %{
      id: {Mimo.Skills.Client, skill_name},
      start: {Mimo.Skills.Client, :start_link, [skill_name, config]},
      restart: :transient,
      shutdown: 30_000
    }
    
    case DynamicSupervisor.start_child(Mimo.Skills.Supervisor, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
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
    
    # Reload catalog
    if Code.ensure_loaded?(Mimo.Skills.Catalog) do
      Mimo.Skills.Catalog.reload()
    end
    
    Logger.warning("✅ Hot reload complete")
    {:ok, :reloaded}
  end

  @impl true
  def handle_call({:register_tools, skill_name, tools, client_pid}, _from, state) do
    :ets.match_delete(@tools_table, {:_, skill_name, :_, :_})
    
    for tool <- tools do
      prefixed_name = "#{skill_name}_#{tool["name"]}"
      :ets.insert(@tools_table, {prefixed_name, skill_name, client_pid, tool})
    end
    
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
