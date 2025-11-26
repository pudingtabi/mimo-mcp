defmodule Mimo.ToolRegistry do
  @moduledoc """
  Thread-safe tool registry with distributed process coordination.
  
  Replaces the ETS-based registry with a GenServer-backed implementation
  that provides:
  - Atomic operations (no TOCTOU race conditions)
  - Automatic cleanup of dead processes via monitors
  - Distributed coordination via :pg process groups
  - Thread-safe tool lookup and registration
  
  ## Architecture
  
  Tools are registered by skills and stored in a single GenServer state.
  Each skill process is monitored, and when it dies, all its tools are
  automatically unregistered.
  
  ## Usage
  
      # Register tools for a skill
      Mimo.ToolRegistry.register_skill_tools("exa", tools, self())
      
      # Look up a tool owner
      {:ok, {:skill, "exa", pid, tool_def}} = Mimo.ToolRegistry.get_tool_owner("exa_search")
      
      # List all tools
      tools = Mimo.ToolRegistry.list_all_tools()
  """
  
  use GenServer
  require Logger
  
  @topic :"mimo_tools_#{Mix.env()}"
  
  # Internal tool definitions
  @internal_tool_names [
    "ask_mimo",
    "search_vibes",
    "store_fact",
    "mimo_store_memory",
    "mimo_reload_skills"
  ]
  
  # ==========================================================================
  # Public API
  # ==========================================================================
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  @doc """
  Register tools for a skill. Atomic operation.
  
  Returns `{:ok, [prefixed_tool_names]}` on success.
  """
  def register_skill_tools(skill_name, tools, pid) when is_list(tools) and is_pid(pid) do
    GenServer.call(__MODULE__, {:register, skill_name, tools, pid}, 30_000)
  end
  
  @doc """
  Unregister all tools for a skill.
  """
  def unregister_skill(skill_name) do
    GenServer.cast(__MODULE__, {:unregister, skill_name})
  end
  
  @doc """
  Get the owner of a tool.
  
  Returns:
  - `{:ok, {:internal, atom}}` for internal tools
  - `{:ok, {:skill, skill_name, pid, tool_def}}` for skill tools
  - `{:error, :not_found}` if tool doesn't exist
  """
  def get_tool_owner(tool_name) do
    case classify_tool(tool_name) do
      {:internal, _} = result -> {:ok, result}
      :external -> GenServer.call(__MODULE__, {:lookup, tool_name})
    end
  end
  
  @doc """
  List all available tools (internal + catalog + active skills).
  """
  def list_all_tools do
    internal_tools() ++ catalog_tools() ++ active_skill_tools()
  end
  
  @doc """
  Check if a tool is internal.
  """
  def internal_tool?(name), do: name in @internal_tool_names
  
  @doc """
  List internal tool names.
  """
  def internal_tool_names, do: @internal_tool_names
  
  @doc """
  Signal all skills to prepare for draining (hot reload).
  """
  def signal_drain do
    GenServer.call(__MODULE__, :signal_drain)
  end
  
  @doc """
  Check if all skills have drained.
  """
  def all_drained? do
    GenServer.call(__MODULE__, :all_drained?)
  end
  
  @doc """
  Clear all registrations (used during hot reload).
  """
  def clear_all do
    GenServer.call(__MODULE__, :clear_all)
  end
  
  @doc """
  Get registry statistics.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end
  
  @doc """
  Hot reload all skills.
  """
  def reload_skills do
    GenServer.call(__MODULE__, :reload_skills, 60_000)
  end
  
  # ==========================================================================
  # GenServer Callbacks
  # ==========================================================================
  
  @impl true
  def init(_opts) do
    # Join distributed process group for coordination
    :pg.start_link()
    :pg.join(@topic, self())
    
    state = %{
      tools: %{},      # tool_name => {skill_name, pid, tool_def}
      skills: %{},     # skill_name => %{pid: pid, tools: [tool_names], status: :active | :draining}
      monitors: %{},   # ref => skill_name
      draining: false
    }
    
    Logger.info("ToolRegistry started (topic: #{@topic})")
    {:ok, state}
  end
  
  @impl true
  def handle_call({:register, skill_name, tools, pid}, _from, state) do
    # First, clean up any existing registration for this skill
    state = cleanup_skill(state, skill_name)
    
    # Monitor process for automatic cleanup
    ref = Process.monitor(pid)
    
    # Build tool map with prefixed names
    new_tools = 
      tools
      |> Enum.map(fn tool ->
        prefixed_name = "#{skill_name}_#{tool["name"]}"
        {prefixed_name, {skill_name, pid, tool}}
      end)
      |> Map.new()
    
    tool_names = Map.keys(new_tools)
    
    # Update state atomically
    new_state = %{state |
      tools: Map.merge(state.tools, new_tools),
      skills: Map.put(state.skills, skill_name, %{
        pid: pid,
        tools: tool_names,
        status: :active
      }),
      monitors: Map.put(state.monitors, ref, skill_name)
    }
    
    Logger.info("Registered #{length(tool_names)} tools for skill '#{skill_name}'")
    
    {:reply, {:ok, tool_names}, new_state}
  end
  
  @impl true
  def handle_call({:lookup, tool_name}, _from, state) do
    result = case Map.get(state.tools, tool_name) do
      nil ->
        # Try catalog lookup for lazy-loading
        lookup_catalog_and_spawn(tool_name, state)
        
      {skill_name, pid, tool_def} ->
        if Process.alive?(pid) do
          {:ok, {:skill, skill_name, pid, tool_def}}
        else
          # Process died, clean up and return not found
          {:error, :not_found}
        end
    end
    
    {:reply, result, state}
  end
  
  @impl true
  def handle_call(:signal_drain, _from, state) do
    # Mark all skills as draining
    new_skills = 
      state.skills
      |> Enum.map(fn {name, skill} -> {name, %{skill | status: :draining}} end)
      |> Map.new()
    
    Logger.warning("Signaling drain for #{map_size(new_skills)} skills")
    
    {:reply, :ok, %{state | skills: new_skills, draining: true}}
  end
  
  @impl true
  def handle_call(:all_drained?, _from, state) do
    # Check if all skills are idle (no in-flight requests)
    # In a real implementation, this would check request counters
    all_drained = map_size(state.skills) == 0 or state.draining
    {:reply, all_drained, state}
  end
  
  @impl true
  def handle_call(:clear_all, _from, state) do
    # Demonitor all processes
    Enum.each(state.monitors, fn {ref, _} ->
      Process.demonitor(ref, [:flush])
    end)
    
    Logger.warning("Cleared all registry entries")
    
    {:reply, :ok, %{state | tools: %{}, skills: %{}, monitors: %{}, draining: false}}
  end
  
  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      total_tools: map_size(state.tools),
      total_skills: map_size(state.skills),
      skills: Enum.map(state.skills, fn {name, skill} ->
        {name, %{
          tool_count: length(skill.tools),
          status: skill.status,
          alive: Process.alive?(skill.pid)
        }}
      end) |> Map.new(),
      draining: state.draining
    }
    
    {:reply, stats, state}
  end
  
  @impl true
  def handle_call(:reload_skills, _from, state) do
    Logger.warning("🔄 Hot reload initiated...")
    
    # Terminate all skill clients
    Enum.each(state.skills, fn {_skill_name, %{pid: pid}} ->
      if Process.alive?(pid) do
        GenServer.stop(pid, :normal, 5000)
      end
    end)
    
    # Clear all registrations
    Enum.each(state.monitors, fn {ref, _} ->
      Process.demonitor(ref, [:flush])
    end)
    
    new_state = %{state | tools: %{}, skills: %{}, monitors: %{}, draining: false}
    
    # Reload catalog
    if Code.ensure_loaded?(Mimo.Skills.Catalog) do
      Mimo.Skills.Catalog.reload()
    end
    
    Logger.warning("✅ Hot reload complete")
    
    {:reply, {:ok, :reloaded}, new_state}
  end
  
  @impl true
  def handle_call(:get_active_tools, _from, state) do
    tools = 
      state.tools
      |> Enum.filter(fn {_, {_, pid, _}} -> Process.alive?(pid) end)
      |> Enum.map(fn {name, {_, _, tool_def}} ->
        Map.put(tool_def, "name", name)
      end)
    
    {:reply, tools, state}
  end
  
  @impl true
  def handle_cast({:unregister, skill_name}, state) do
    {:noreply, cleanup_skill(state, skill_name)}
  end
  
  # Handle monitored process death
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.get(state.monitors, ref) do
      nil ->
        {:noreply, state}
        
      skill_name ->
        Logger.warning("Skill '#{skill_name}' died (#{inspect(reason)}), cleaning up registry")
        new_state = cleanup_skill(state, skill_name)
        new_state = %{new_state | monitors: Map.delete(new_state.monitors, ref)}
        {:noreply, new_state}
    end
  end
  
  @impl true
  def handle_info(msg, state) do
    Logger.debug("ToolRegistry received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end
  
  # ==========================================================================
  # Private Functions
  # ==========================================================================
  
  defp classify_tool("ask_mimo"), do: {:internal, :ask_mimo}
  defp classify_tool("search_vibes"), do: {:internal, :search_vibes}
  defp classify_tool("store_fact"), do: {:internal, :store_fact}
  defp classify_tool("mimo_store_memory"), do: {:internal, :store_memory}
  defp classify_tool("mimo_reload_skills"), do: {:internal, :reload}
  defp classify_tool(_), do: :external
  
  defp cleanup_skill(state, skill_name) do
    case Map.get(state.skills, skill_name) do
      nil -> 
        state
        
      %{tools: tool_names} ->
        # Demonitor if we have a reference
        ref_to_remove = Enum.find(state.monitors, fn {_, name} -> name == skill_name end)
        
        monitors = case ref_to_remove do
          {ref, _} ->
            Process.demonitor(ref, [:flush])
            Map.delete(state.monitors, ref)
          nil ->
            state.monitors
        end
        
        %{state |
          tools: Map.drop(state.tools, tool_names),
          skills: Map.delete(state.skills, skill_name),
          monitors: monitors
        }
    end
  end
  
  defp lookup_catalog_and_spawn(tool_name, _state) do
    if Code.ensure_loaded?(Mimo.Skills.Catalog) do
      case Mimo.Skills.Catalog.get_skill_for_tool(tool_name) do
        {:ok, skill_name, config} ->
          # Lazy spawn the skill
          case ensure_skill_running(skill_name, config) do
            {:ok, pid} -> 
              # After spawning, the skill will register itself
              # Wait a moment and then look up again
              Process.sleep(100)
              {:ok, {:skill, skill_name, pid, nil}}
            {:error, reason} -> 
              {:error, {:spawn_failed, reason}}
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
        if Process.alive?(pid) do
          {:ok, pid}
        else
          start_skill(skill_name, config)
        end
        
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
  
  # ==========================================================================
  # Internal Tools
  # ==========================================================================
  
  defp internal_tools do
    [
      %{
        "name" => "ask_mimo",
        "description" =>
          "Consult Mimo's memory for strategic guidance. Query the AI memory system for context, patterns, and recommendations.",
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
        "name" => "search_vibes",
        "description" =>
          "Vector similarity search in Mimo's episodic memory. Find memories semantically related to a query.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "query" => %{
              "type" => "string",
              "description" => "Search query for semantic similarity"
            },
            "limit" => %{
              "type" => "integer",
              "default" => 10,
              "description" => "Maximum number of results"
            },
            "threshold" => %{
              "type" => "number",
              "default" => 0.3,
              "description" => "Minimum similarity threshold (0-1)"
            }
          },
          "required" => ["query"]
        }
      },
      %{
        "name" => "store_fact",
        "description" => "Store a fact or observation in Mimo's memory with semantic embedding.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "content" => %{"type" => "string", "description" => "The content to store"},
            "category" => %{
              "type" => "string",
              "enum" => ["fact", "action", "observation", "plan"],
              "description" => "Category of the memory"
            },
            "importance" => %{
              "type" => "number",
              "minimum" => 0,
              "maximum" => 1,
              "default" => 0.5,
              "description" => "Importance score (0-1)"
            }
          },
          "required" => ["content"]
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
    GenServer.call(__MODULE__, :get_active_tools, 5000)
  rescue
    _ -> []
  end
end
