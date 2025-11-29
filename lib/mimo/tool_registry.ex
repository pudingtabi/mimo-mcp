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
    "mimo_reload_skills",
    # SPEC-011.1: Procedural Store Tools
    "run_procedure",
    "procedure_status",
    "list_procedures",
    # SPEC-011.2: Unified Memory Tool
    "memory",
    # SPEC-011.3: File Ingestion
    "ingest"
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
  - `{:ok, {:mimo_core, atom}}` for Mimo.Tools core capabilities
  - `{:ok, {:skill, skill_name, pid, tool_def}}` for skill tools
  - `{:error, :not_found}` if tool doesn't exist
  """
  def get_tool_owner(tool_name) do
    case classify_tool(tool_name) do
      {:internal, _} = result -> {:ok, result}
      {:mimo_core, _} = result -> {:ok, result}
      :external -> GenServer.call(__MODULE__, {:lookup, tool_name})
    end
  end

  @doc """
  List all available tools (internal + mimo core + catalog + active skills).
  """
  def list_all_tools do
    internal_tools() ++ mimo_core_tools() ++ catalog_tools() ++ active_skill_tools()
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
      # tool_name => {skill_name, pid, tool_def}
      tools: %{},
      # skill_name => %{pid: pid, tools: [tool_names], status: :active | :draining}
      skills: %{},
      # ref => skill_name
      monitors: %{},
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
    new_state = %{
      state
      | tools: Map.merge(state.tools, new_tools),
        skills:
          Map.put(state.skills, skill_name, %{
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
    result =
      case Map.get(state.tools, tool_name) do
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
      skills:
        Enum.map(state.skills, fn {name, skill} ->
          {name,
           %{
             tool_count: length(skill.tools),
             status: skill.status,
             alive: Process.alive?(skill.pid)
           }}
        end)
        |> Map.new(),
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
  defp classify_tool("mimo_reload_skills"), do: {:internal, :reload}

  # SPEC-011.1: Procedural Store Tools
  defp classify_tool("run_procedure"), do: {:internal, :run_procedure}
  defp classify_tool("procedure_status"), do: {:internal, :procedure_status}
  defp classify_tool("list_procedures"), do: {:internal, :list_procedures}

  # SPEC-011.2: Unified Memory Tool
  defp classify_tool("memory"), do: {:internal, :memory}

  # SPEC-011.3: File Ingestion
  defp classify_tool("ingest"), do: {:internal, :ingest}

  # Mimo.Tools core capabilities (consolidated 9 tools)
  defp classify_tool("file"), do: {:mimo_core, :file}
  defp classify_tool("terminal"), do: {:mimo_core, :terminal}
  defp classify_tool("fetch"), do: {:mimo_core, :fetch}
  defp classify_tool("think"), do: {:mimo_core, :think}
  defp classify_tool("web_parse"), do: {:mimo_core, :web_parse}
  defp classify_tool("search"), do: {:mimo_core, :search}
  defp classify_tool("sonar"), do: {:mimo_core, :sonar}
  defp classify_tool("knowledge"), do: {:mimo_core, :knowledge}
  defp classify_tool("vision"), do: {:mimo_core, :vision}
  defp classify_tool("web_extract"), do: {:mimo_core, :web_extract}

  # Legacy tool names (keep for backward compatibility)
  defp classify_tool("http_request"), do: {:mimo_core, :fetch}
  defp classify_tool("plan"), do: {:mimo_core, :think}
  defp classify_tool("consult_graph"), do: {:mimo_core, :knowledge}
  defp classify_tool("teach_mimo"), do: {:mimo_core, :knowledge}

  defp classify_tool(_), do: :external

  defp cleanup_skill(state, skill_name) do
    case Map.get(state.skills, skill_name) do
      nil ->
        state

      %{tools: tool_names} ->
        # Demonitor if we have a reference
        ref_to_remove = Enum.find(state.monitors, fn {_, name} -> name == skill_name end)

        monitors =
          case ref_to_remove do
            {ref, _} ->
              Process.demonitor(ref, [:flush])
              Map.delete(state.monitors, ref)

            nil ->
              state.monitors
          end

        %{
          state
          | tools: Map.drop(state.tools, tool_names),
            skills: Map.delete(state.skills, skill_name),
            monitors: monitors
        }
    end
  end

  defp lookup_catalog_and_spawn(tool_name, _state) do
    if Code.ensure_loaded?(Mimo.Skills.Catalog) do
      case Mimo.Skills.Catalog.get_skill_for_tool(tool_name) do
        {:ok, skill_name, config} ->
          # Don't spawn synchronously - this would block the GenServer
          # Instead, return a special marker that tells the caller to use call_tool_sync
          {:ok, {:skill_lazy, skill_name, config, nil}}

        {:error, :not_found} ->
          {:error, :not_found}
      end
    else
      {:error, :not_found}
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
          "[Deprecated: use memory operation=search] Vector similarity search in Mimo's episodic memory.",
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
        "description" => "[Deprecated: use memory operation=store] Store a fact in Mimo's memory.",
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
          "required" => ["content", "category"]
        }
      },
      %{
        "name" => "mimo_reload_skills",
        "description" => "Hot-reload all skills from skills.json without restart",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      },
      # ========================================================================
      # SPEC-011.1: Procedural Store Tools
      # ========================================================================
      %{
        "name" => "run_procedure",
        "description" =>
          "Execute a registered procedure as a state machine. Procedures run deterministically without LLM involvement.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "name" => %{
              "type" => "string",
              "description" => "Procedure name"
            },
            "version" => %{
              "type" => "string",
              "default" => "latest",
              "description" => "Procedure version (or 'latest')"
            },
            "context" => %{
              "type" => "object",
              "default" => %{},
              "description" => "Initial execution context"
            },
            "async" => %{
              "type" => "boolean",
              "default" => false,
              "description" => "Return immediately with execution_id instead of waiting"
            },
            "timeout" => %{
              "type" => "integer",
              "default" => 60000,
              "description" => "Timeout in milliseconds (sync mode only)"
            }
          },
          "required" => ["name"]
        }
      },
      %{
        "name" => "procedure_status",
        "description" => "Check status of a procedure execution (especially for async executions).",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "execution_id" => %{
              "type" => "string",
              "description" => "Execution ID returned from run_procedure"
            }
          },
          "required" => ["execution_id"]
        }
      },
      %{
        "name" => "list_procedures",
        "description" => "List all registered procedures available for execution.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{}
        }
      },
      # ========================================================================
      # SPEC-011.2: Unified Memory Tool
      # ========================================================================
      %{
        "name" => "memory",
        "description" =>
          "Unified memory operations: store, search, list, delete, stats, decay_check. Replaces store_fact and search_vibes.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "operation" => %{
              "type" => "string",
              "enum" => ["store", "search", "list", "delete", "stats", "decay_check"],
              "description" => "Memory operation to perform"
            },
            # Store operation
            "content" => %{
              "type" => "string",
              "description" => "For store: content to store"
            },
            "category" => %{
              "type" => "string",
              "enum" => ["fact", "action", "observation", "plan"],
              "description" => "For store/search/list: memory category"
            },
            "importance" => %{
              "type" => "number",
              "minimum" => 0,
              "maximum" => 1,
              "default" => 0.5,
              "description" => "For store: importance score (0-1)"
            },
            # Search operation
            "query" => %{
              "type" => "string",
              "description" => "For search: semantic search query"
            },
            "threshold" => %{
              "type" => "number",
              "default" => 0.3,
              "description" => "For search/decay_check: minimum threshold"
            },
            "time_filter" => %{
              "type" => "string",
              "description" =>
                "For search: natural language time filter (e.g., 'yesterday', 'last week', '3 days ago')"
            },
            # List operation
            "limit" => %{
              "type" => "integer",
              "default" => 20,
              "description" => "For search/list/decay_check: max results"
            },
            "offset" => %{
              "type" => "integer",
              "default" => 0,
              "description" => "For list: pagination offset"
            },
            "sort" => %{
              "type" => "string",
              "enum" => ["recent", "importance", "decay_score"],
              "default" => "recent",
              "description" => "For list: sort order"
            },
            # Delete operation
            "id" => %{
              "type" => "string",
              "description" => "For delete: memory ID to delete"
            }
          },
          "required" => ["operation"]
        }
      },
      # ========================================================================
      # SPEC-011.3: File Ingestion
      # ========================================================================
      %{
        "name" => "ingest",
        "description" =>
          "Ingest file content into memory with automatic chunking. Supports markdown, text, and code files.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "File path to ingest"
            },
            "strategy" => %{
              "type" => "string",
              "enum" => ["auto", "paragraphs", "markdown", "lines", "sentences", "whole"],
              "default" => "auto",
              "description" => "Chunking strategy (auto detects from file extension)"
            },
            "category" => %{
              "type" => "string",
              "enum" => ["fact", "action", "observation", "plan"],
              "default" => "fact",
              "description" => "Category for stored chunks"
            },
            "importance" => %{
              "type" => "number",
              "minimum" => 0,
              "maximum" => 1,
              "default" => 0.5,
              "description" => "Base importance for chunks"
            },
            "tags" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "Tags to apply to all chunks"
            },
            "metadata" => %{
              "type" => "object",
              "description" => "Additional metadata for chunks"
            }
          },
          "required" => ["path"]
        }
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

  # Core tools from Mimo.Tools module (internal capabilities)
  defp mimo_core_tools do
    if Code.ensure_loaded?(Mimo.Tools) do
      try do
        Mimo.Tools.list_tools()
        |> Enum.map(&convert_to_mcp_format/1)
      rescue
        _ -> []
      end
    else
      []
    end
  end

  # Convert atom-keyed tool definition to MCP JSON string format
  defp convert_to_mcp_format(%{name: name, description: desc, input_schema: schema}) do
    %{
      "name" => to_string(name),
      "description" => desc,
      "inputSchema" => convert_schema(schema)
    }
  end

  defp convert_to_mcp_format(tool), do: tool

  # Recursively convert schema atom keys to strings
  defp convert_schema(schema) when is_map(schema) do
    for {k, v} <- schema, into: %{} do
      key = if is_atom(k), do: Atom.to_string(k), else: k
      value = if is_map(v), do: convert_schema(v), else: v
      {key, value}
    end
  end

  defp convert_schema(value), do: value

  # Tools from already-running skill processes
  defp active_skill_tools do
    GenServer.call(__MODULE__, :get_active_tools, 5000)
  rescue
    _ -> []
  end
end
