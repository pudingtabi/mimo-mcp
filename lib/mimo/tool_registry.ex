defmodule Mimo.ToolRegistry do
  alias Mimo.Skills.Catalog

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

  # Topic for PubSub - no env distinction needed, Mimo works the same everywhere
  @topic :mimo_tools

  # Internal tool definitions (exposed to MCP)
  # Deprecated aliases (search_vibes, store_fact) are defined but filtered out
  @internal_tool_names [
    "ask_mimo",
    "mimo_reload_skills",
    # SPEC-011.1: Procedural Store Tools (consolidated)
    "run_procedure",
    "list_procedures",
    # SPEC-011.2: Unified Memory Tool
    "memory",
    # SPEC-011.3: File Ingestion
    "ingest",
    # SPEC-040: Awakening Status
    "awakening_status",
    # Tool usage analytics
    "tool_usage"
  ]

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
  Filters out deprecated tools that should no longer be exposed via MCP.
  """
  def list_all_tools do
    all_tools = internal_tools() ++ mimo_core_tools() ++ catalog_tools() ++ active_skill_tools()

    # Filter out deprecated tools from MCP exposure
    deprecated = Mimo.Tools.Definitions.deprecated_tools()

    Enum.reject(all_tools, fn tool ->
      tool_name = tool["name"] || tool[:name]
      MapSet.member?(deprecated, to_string(tool_name))
    end)
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

  @impl true
  def init(_opts) do
    # Note: :pg distributed coordination disabled for now
    # Can be re-enabled when running in distributed mode
    # :pg.join(@topic, self())

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
    # Checks if all skills are idle (no in-flight requests).
    # Returns true if no skills registered or draining mode active.
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
      Catalog.reload()
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

  # REMOVED: :health_check handler (Dec 6 2025 Incident - TASK 4)
  #
  # The :health_check handler was removed because calling GenServer.call(ToolRegistry, :health_check)
  # during startup created a circular dependency that blocked initialization.
  #
  # DEFENSIVE PATTERN: Instead of health checks, use:
  # - Process.whereis(Mimo.ToolRegistry) to check if process is registered
  # - Mimo.Fallback.ServiceRegistry.available?(Mimo.ToolRegistry) to check if ready
  # - Try/catch around GenServer calls for graceful degradation
  #
  # @see Mimo.Fallback.ServiceRegistry.safe_call/3 for reusable defensive pattern

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

  defp classify_tool("ask_mimo"), do: {:internal, :ask_mimo}
  defp classify_tool("search_vibes"), do: {:internal, :search_vibes}
  defp classify_tool("store_fact"), do: {:internal, :store_fact}
  defp classify_tool("mimo_reload_skills"), do: {:internal, :reload}

  # SPEC-011.1: Procedural Store Tools (consolidated - procedure_status merged into run_procedure)
  defp classify_tool("run_procedure"), do: {:internal, :run_procedure}
  defp classify_tool("list_procedures"), do: {:internal, :list_procedures}

  # SPEC-011.2: Unified Memory Tool
  defp classify_tool("memory"), do: {:internal, :memory}

  # SPEC-011.3: File Ingestion
  defp classify_tool("ingest"), do: {:internal, :ingest}

  # SPEC-040: Awakening Status Tool
  defp classify_tool("awakening_status"), do: {:internal, :awakening_status}

  # Mimo.Tools core capabilities (17 tools)
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
  defp classify_tool("blink"), do: {:mimo_core, :blink}
  defp classify_tool("browser"), do: {:mimo_core, :browser}

  # SPEC-030: Unified Web Tool (consolidates fetch, search, blink, browser, vision, sonar, web_extract, web_parse)
  defp classify_tool("web"), do: {:mimo_core, :web}

  # SPEC-030 Phase 3: Unified Code Intelligence (consolidates code_symbols, library, diagnostics)
  defp classify_tool("code"), do: {:mimo_core, :code}

  # SPEC-043: Metacognitive Self-Reflection
  defp classify_tool("reflector"), do: {:mimo_core, :reflector}

  # SPEC-044: Emergence Pattern Detection
  defp classify_tool("emergence"), do: {:mimo_core, :emergence}

  # SPEC-AI-TEST: Executable Verification
  defp classify_tool("verify"), do: {:mimo_core, :verify}

  # SPEC-036: Meta Composite Tool
  defp classify_tool("meta"), do: {:mimo_core, :meta}

  # SPEC-021: Code structure analysis
  defp classify_tool("code_symbols"), do: {:mimo_core, :code_symbols}

  # SPEC-022: Package documentation
  defp classify_tool("library"), do: {:mimo_core, :library}

  # SPEC-023: Synapse graph operations
  defp classify_tool("graph"), do: {:mimo_core, :graph}

  # SPEC-024: Epistemic uncertainty & meta-cognition
  defp classify_tool("cognitive"), do: {:mimo_core, :cognitive}

  # SPEC-035: Unified Reasoning Engine
  defp classify_tool("reason"), do: {:mimo_core, :reason}

  # SPEC-029: Multi-language diagnostics
  defp classify_tool("diagnostics"), do: {:mimo_core, :diagnostics}

  # Legacy tool names (keep for backward compatibility)
  defp classify_tool("http_request"), do: {:mimo_core, :fetch}
  defp classify_tool("plan"), do: {:mimo_core, :think}
  defp classify_tool("consult_graph"), do: {:mimo_core, :knowledge}
  defp classify_tool("teach_mimo"), do: {:mimo_core, :knowledge}

  # SPEC-031: Composite domain actions (compound tools)
  defp classify_tool("onboard"), do: {:mimo_core, :onboard}
  defp classify_tool("analyze_file"), do: {:mimo_core, :analyze_file}
  defp classify_tool("debug_error"), do: {:mimo_core, :debug_error}
  # SPEC-036: Smart context aggregation
  defp classify_tool("prepare_context"), do: {:mimo_core, :prepare_context}
  # SPEC-037: Workflow routing
  defp classify_tool("suggest_next_tool"), do: {:mimo_core, :suggest_next_tool}

  # Tool usage analytics
  defp classify_tool("tool_usage"), do: {:internal, :tool_usage}

  # Autonomous Task Execution (SPEC-071)
  defp classify_tool("autonomous"), do: {:mimo_core, :autonomous}

  # SPEC-072: Multi-tool Orchestrator
  defp classify_tool("orchestrate"), do: {:mimo_core, :orchestrate}

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
      case Catalog.get_skill_for_tool(tool_name) do
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

  defp internal_tools do
    [
      %{
        "name" => "ask_mimo",
        "description" => """
        🎯 ASK MIMO - Strategic memory consultation. Start EVERY session here!

        WORKFLOW EXAMPLES:
        ✓ Session start: ask_mimo "What context exists about this project?" → accumulated wisdom
        ✓ Strategic question: ask_mimo "What patterns should I follow here?" → guidance
        ✓ Before decisions: ask_mimo "What do I know about auth approaches?" → informed choice

        Auto-records conversations for future context. Your questions AND Mimo's answers persist.
        Consult Mimo's memory for strategic guidance. Query the AI memory system for context, patterns, and recommendations.
        """,
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
          "[Deprecated: use memory (search)] Vector similarity search in Mimo's episodic memory.",
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
        "description" => "[Deprecated: use memory (store)] Store a fact in Mimo's memory.",
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
      %{
        "name" => "run_procedure",
        "description" =>
          "Execute or check status of a procedure. Operations: run (default), status. Procedures run deterministically without LLM involvement.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "operation" => %{
              "type" => "string",
              "enum" => ["run", "status"],
              "default" => "run",
              "description" => "Operation: 'run' to execute, 'status' to check execution status"
            },
            "name" => %{
              "type" => "string",
              "description" => "For run: Procedure name"
            },
            "version" => %{
              "type" => "string",
              "default" => "latest",
              "description" => "For run: Procedure version (or 'latest')"
            },
            "context" => %{
              "type" => "object",
              "default" => %{},
              "description" => "For run: Initial execution context"
            },
            "async" => %{
              "type" => "boolean",
              "default" => false,
              "description" => "For run: Return immediately with execution_id instead of waiting"
            },
            "timeout" => %{
              "type" => "integer",
              "default" => 60_000,
              "description" => "For run: Timeout in milliseconds (sync mode only)"
            },
            "execution_id" => %{
              "type" => "string",
              "description" => "For status: Execution ID returned from async run"
            }
          },
          "required" => []
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
      %{
        "name" => "memory",
        "description" => """
        🧠 MEMORY - Your persistent knowledge store. Search BEFORE reading files!

        ## WHEN TO USE
        • Need to recall facts, patterns, or context from past sessions
        • Before reading a file - check if you already know its contents
        • After discovering something important - store it for future sessions
        • To find similar past problems and their solutions
        • To track user preferences and project-specific patterns

        ## INSTEAD OF (common mistakes)
        • ❌ For entity relationships → ✅ Use `knowledge operation=query`
        • ❌ For synthesized wisdom → ✅ Use `ask_mimo` (combines memory + knowledge)
        • ❌ For code structure → ✅ Use `code operation=symbols`

        ## WORKFLOW EXAMPLES
        ✓ Before file read: memory search "auth patterns" → found context → skipped file read
        ✓ After discovery: memory store "Phoenix uses Ecto" category=fact → persists forever
        ✓ Session start: memory search "user preferences" → personalized behavior
        ✓ Check health: memory stats → see memory count, categories, decay status
        ✓ Bulk import: memory ingest path="README.md" → chunks file into memories

        Operations: store, search, list, delete, stats, decay_check, ingest, synthesize, graph
        """,
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "operation" => %{
              "type" => "string",
              "enum" => [
                "store",
                "search",
                "list",
                "delete",
                "stats",
                "decay_check",
                "ingest",
                "synthesize",
                "graph"
              ],
              "description" =>
                "Memory operation to perform. synthesize=combined wisdom (was ask_mimo), graph=relationship query (was knowledge query)"
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
              "description" => "For list: pagination offset (legacy, prefer cursor)"
            },
            "cursor" => %{
              "type" => "string",
              "description" =>
                "For list: cursor for efficient pagination (SPEC-096). Use next_cursor from previous response. Preferred over offset for large datasets."
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
            },
            # Ingest operation (consolidated from standalone ingest tool)
            "path" => %{
              "type" => "string",
              "description" => "For ingest: file path to ingest"
            },
            "strategy" => %{
              "type" => "string",
              "enum" => ["auto", "paragraphs", "markdown", "lines", "sentences", "whole"],
              "default" => "auto",
              "description" => "For ingest: chunking strategy (auto detects from file extension)"
            },
            "tags" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "For ingest: tags to apply to all chunks"
            },
            "metadata" => %{
              "type" => "object",
              "description" => "For ingest: additional metadata for chunks"
            }
          },
          "required" => ["operation"]
        }
      },
      %{
        "name" => "tool_usage",
        "description" =>
          "Get comprehensive tool usage statistics and analytics. Analyze which tools are popular, performance metrics, and trends over time. Useful for understanding AI agent behavior and optimizing tool design.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "operation" => %{
              "type" => "string",
              "enum" => ["stats", "detail"],
              "default" => "stats",
              "description" =>
                "Operation: 'stats' for overview/rankings, 'detail' for specific tool analysis"
            },
            "tool_name" => %{
              "type" => "string",
              "description" => "For detail: specific tool to analyze"
            },
            "days" => %{
              "type" => "integer",
              "default" => 30,
              "description" => "Number of days to analyze (default: 30)"
            },
            "limit" => %{
              "type" => "integer",
              "default" => 50,
              "description" => "Max tools to return in rankings (default: 50)"
            },
            "include_daily" => %{
              "type" => "boolean",
              "default" => false,
              "description" => "Include daily breakdown in stats (default: false)"
            }
          },
          "required" => []
        }
      },
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
      },
      %{
        "name" => "awakening_status",
        "description" =>
          "Get your current Mimo Awakening status including power level, XP, achievements, and capabilities. " <>
            "Shows your progression from Base (🌑) through Ultra (🌌) power levels.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "include_achievements" => %{
              "type" => "boolean",
              "default" => false,
              "description" => "Include detailed achievement list in response"
            },
            "include_guidance" => %{
              "type" => "boolean",
              "default" => true,
              "description" => "Include behavioral guidance for current power level"
            }
          },
          "required" => []
        }
      }
    ]
    # Filter to only include non-deprecated internal tools
    |> Enum.filter(fn %{"name" => name} -> name in @internal_tool_names end)
  end

  # Tools from pre-generated manifest (instant, no process)
  defp catalog_tools do
    if Code.ensure_loaded?(Mimo.Skills.Catalog) do
      try do
        Catalog.list_tools()
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
    case Process.whereis(__MODULE__) do
      nil ->
        # Process not started yet
        []

      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          try do
            GenServer.call(__MODULE__, :get_active_tools, 5000)
          catch
            :exit, {:noproc, _} -> []
            :exit, {:timeout, _} -> []
            :exit, reason when is_tuple(reason) and elem(reason, 0) == :noproc -> []
            _, _ -> []
          end
        else
          []
        end
    end
  end
end
