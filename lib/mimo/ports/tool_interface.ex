defmodule Mimo.ToolInterface do
  @moduledoc """
  Port: ToolInterface

  Abstract port for direct, low-level memory operations.
  Routes to internal tools or external skills via Registry.

  Part of the Universal Aperture architecture - isolates Mimo Core from protocol concerns.

  ## Timeout Protection

  All tool executions are wrapped with timeout protection to prevent hanging:
  - Internal tools: 30 second timeout
  - External skills: 60 second timeout (allows for process startup)
  - Retries on transient failures with exponential backoff

  ## SPEC-011 Tools

  New tools added for feature parity:
  - `run_procedure` - Execute a procedural FSM
  - `procedure_status` - Check procedure execution status
  - `list_procedures` - List all registered procedures
  - `memory` - Unified memory operations (store, search, list, delete, stats, decay_check)
  - `ingest` - File ingestion with automatic chunking
  """
  require Logger

  import Ecto.Query, only: [from: 2]

  alias Mimo.Brain.{Memory, Engram, DecayScorer}
  alias Mimo.ProceduralStore.{ExecutionFSM, Loader, Execution}
  alias Mimo.Utils.InputValidation
  alias Mimo.Repo

  # Timeouts
  @procedure_sync_timeout 60_000

  @doc """
  Execute a tool by name with given arguments.
  Routes to internal tools or external skills automatically.

  Automatically registers activity for pause-aware memory decay.

  ## Returns
    - {:ok, result} on success
    - {:error, reason} on failure
  """
  @spec execute(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def execute(tool_name, arguments \\ %{}) do
    # Register activity for pause-aware decay (non-blocking)
    register_activity()

    # SPEC-INTERCEPTOR: Analyze request for cognitive enhancement
    case Mimo.RequestInterceptor.analyze_and_enrich(tool_name, arguments) do
      {:enriched, context, metadata} ->
        # Auto-enriched with cognitive context - add to arguments
        enriched_args = Map.put(arguments, "_mimo_context", context)
        result = do_execute(tool_name, enriched_args)
        add_cognitive_metadata(result, metadata)

      {:suggest, cognitive_tool, query, reason} ->
        # Execute the tool but add suggestion to result
        result = do_execute(tool_name, arguments)
        add_cognitive_suggestion(result, cognitive_tool, query, reason)

      {:continue, nil} ->
        # Normal execution
        do_execute(tool_name, arguments)
    end
  end

  # Add cognitive metadata to successful results
  defp add_cognitive_metadata({:ok, result}, metadata) when is_map(result) do
    {:ok, Map.put(result, :_cognitive_enhancement, metadata)}
  end
  defp add_cognitive_metadata(result, _metadata), do: result

  # Add cognitive suggestion to successful results
  defp add_cognitive_suggestion({:ok, result}, tool, query, reason) when is_map(result) do
    suggestion = %{
      recommended_tool: tool,
      query: query,
      reason: reason,
      hint: build_suggestion_hint(tool, query)
    }
    {:ok, Map.put(result, :_cognitive_suggestion, suggestion)}
  end
  defp add_cognitive_suggestion(result, _tool, _query, _reason), do: result

  defp build_suggestion_hint(:reason, problem) do
    "💡 Consider using: reason operation=guided problem=\"#{String.slice(problem, 0, 50)}...\""
  end
  defp build_suggestion_hint(:knowledge, query) do
    "💡 Consider using: knowledge operation=query query=\"#{String.slice(query, 0, 50)}...\""
  end
  defp build_suggestion_hint(:prepare_context, query) do
    "💡 Consider using: prepare_context query=\"#{String.slice(query, 0, 50)}...\""
  end
  defp build_suggestion_hint(_, _), do: nil

  # Register activity with the ActivityTracker (non-blocking)
  defp register_activity do
    if Process.whereis(Mimo.Brain.ActivityTracker) do
      Mimo.Brain.ActivityTracker.register_activity()
    end
  end

  # ============================================================================
  # Tool Handlers
  # ============================================================================

  defp do_execute(tool_name, arguments)

  # ============================================================================
  # SPEC-011.1: Procedural Store Tools (consolidated)
  # ============================================================================

  # Execute or check status of a procedure
  # operation=status: Check execution status by execution_id
  defp do_execute("run_procedure", %{"operation" => "status", "execution_id" => execution_id}) do
    if Mimo.Application.feature_enabled?(:procedural_store) do
      case Repo.get(Execution, execution_id) do
        nil ->
          {:error, "Execution not found: #{execution_id}"}

        execution ->
          elapsed_ms =
            if execution.started_at do
              now = NaiveDateTime.utc_now()
              NaiveDateTime.diff(now, execution.started_at, :millisecond)
            else
              0
            end

          {:ok,
           %{
             tool_call_id: UUID.uuid4(),
             status: "success",
             data: %{
               execution_id: execution.id,
               status: execution.status,
               current_state: execution.current_state,
               context: execution.context,
               history: execution.history,
               elapsed_ms: elapsed_ms,
               error: execution.error
             }
           }}
      end
    else
      {:error, "Procedural store is not enabled. Set PROCEDURAL_STORE_ENABLED=true to enable."}
    end
  end

  defp do_execute("run_procedure", %{"operation" => "status"}) do
    {:error, "Missing required argument: 'execution_id' for status operation"}
  end

  # operation=run (default): Execute a registered procedure as a state machine
  defp do_execute("run_procedure", %{"name" => name} = args) do
    if Mimo.Application.feature_enabled?(:procedural_store) do
      version = Map.get(args, "version", "latest")
      context = Map.get(args, "context", %{})
      async = Map.get(args, "async", false)
      timeout = Map.get(args, "timeout", @procedure_sync_timeout)

      start_time = System.monotonic_time(:millisecond)

      :telemetry.execute(
        [:mimo, :procedure, :start],
        %{count: 1},
        %{name: name, version: version, async: async}
      )

      if async do
        # Async mode: start and return immediately
        case ExecutionFSM.start_procedure(name, version, context, []) do
          {:ok, pid} ->
            # Get execution ID from FSM state
            {_state, data} = ExecutionFSM.get_state(pid)

            {:ok,
             %{
               tool_call_id: UUID.uuid4(),
               status: "success",
               data: %{
                 execution_id: data.execution_id,
                 status: "running",
                 pid: inspect(pid)
               }
             }}

          {:error, reason} ->
            {:error, "Failed to start procedure: #{inspect(reason)}"}
        end
      else
        # Sync mode: wait for completion
        caller = self()

        case ExecutionFSM.start_procedure(name, version, context, caller: caller) do
          {:ok, _pid} ->
            receive do
              {:procedure_complete, ^name, status, final_context} ->
                duration = System.monotonic_time(:millisecond) - start_time

                :telemetry.execute(
                  [:mimo, :procedure, :complete],
                  %{duration_ms: duration},
                  %{name: name, status: status}
                )

                # Get execution record for full history
                execution = get_latest_execution(name)

                {:ok,
                 %{
                   tool_call_id: UUID.uuid4(),
                   status: "success",
                   data: %{
                     execution_id: execution && execution.id,
                     status: to_string(status),
                     final_state: execution && execution.current_state,
                     context: final_context,
                     history: (execution && execution.history) || [],
                     duration_ms: duration
                   }
                 }}
            after
              timeout ->
                {:error, "Procedure execution timed out after #{timeout}ms"}
            end

          {:error, {:procedure_not_found, reason}} ->
            {:error, "Procedure '#{name}' not found: #{inspect(reason)}"}

          {:error, reason} ->
            {:error, "Failed to start procedure: #{inspect(reason)}"}
        end
      end
    else
      {:error, "Procedural store is not enabled. Set PROCEDURAL_STORE_ENABLED=true to enable."}
    end
  end

  defp do_execute("run_procedure", _args) do
    {:error,
     "Missing required argument: 'name' for run operation, or 'execution_id' for status operation"}
  end

  # List all registered procedures.
  defp do_execute("list_procedures", _args) do
    if Mimo.Application.feature_enabled?(:procedural_store) do
      procedures = Loader.list(active_only: true)

      procedure_list =
        Enum.map(procedures, fn proc ->
          state_count =
            case proc.definition do
              %{"states" => states} when is_map(states) -> map_size(states)
              _ -> 0
            end

          %{
            name: proc.name,
            version: proc.version,
            description: proc.description,
            state_count: state_count,
            timeout_ms: proc.timeout_ms,
            max_retries: proc.max_retries
          }
        end)

      {:ok,
       %{
         tool_call_id: UUID.uuid4(),
         status: "success",
         data: %{
           procedures: procedure_list,
           count: length(procedure_list)
         }
       }}
    else
      {:error, "Procedural store is not enabled. Set PROCEDURAL_STORE_ENABLED=true to enable."}
    end
  end

  # ============================================================================
  # SPEC-011.2: Unified Memory Tool
  # ============================================================================

  # Unified memory operations: store, search, list, delete, stats, decay_check.
  defp do_execute("memory", %{"operation" => "store"} = args) do
    # Delegate to store_fact logic
    content = Map.get(args, "content")
    category = Map.get(args, "category", "fact")
    importance = Map.get(args, "importance", 0.5)

    # SPEC-060: Temporal validity options
    temporal_opts = [
      valid_from: parse_datetime(Map.get(args, "valid_from")),
      valid_until: parse_datetime(Map.get(args, "valid_until")),
      validity_source: Map.get(args, "validity_source")
    ] |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    if is_nil(content) do
      {:error, "Missing required argument: 'content'"}
    else
      execute_memory_store(content, category, importance, temporal_opts)
    end
  end

  defp do_execute("memory", %{"operation" => "search"} = args) do
    query = Map.get(args, "query")

    if is_nil(query) do
      {:error, "Missing required argument: 'query'"}
    else
      execute_memory_search(args)
    end
  end

  defp do_execute("memory", %{"operation" => "list"} = args) do
    execute_memory_list(args)
  end

  defp do_execute("memory", %{"operation" => "delete"} = args) do
    id = Map.get(args, "id")

    if is_nil(id) do
      {:error, "Missing required argument: 'id'"}
    else
      execute_memory_delete(id)
    end
  end

  defp do_execute("memory", %{"operation" => "stats"} = _args) do
    execute_memory_stats()
  end

  defp do_execute("memory", %{"operation" => "health"} = _args) do
    execute_memory_health()
  end

  defp do_execute("memory", %{"operation" => "decay_check"} = args) do
    threshold = Map.get(args, "threshold", 0.1)
    limit = Map.get(args, "limit", 50)
    execute_memory_decay_check(threshold, limit)
  end

  # SPEC-034: Temporal Memory Chains operations
  defp do_execute("memory", %{"operation" => "get_chain", "id" => id}) do
    execute_memory_get_chain(id)
  end

  defp do_execute("memory", %{"operation" => "get_chain"}) do
    {:error, "Missing required argument: 'id'"}
  end

  defp do_execute("memory", %{"operation" => "get_current", "id" => id}) do
    execute_memory_get_current(id)
  end

  defp do_execute("memory", %{"operation" => "get_current"}) do
    {:error, "Missing required argument: 'id'"}
  end

  defp do_execute("memory", %{"operation" => "get_original", "id" => id}) do
    execute_memory_get_original(id)
  end

  defp do_execute("memory", %{"operation" => "get_original"}) do
    {:error, "Missing required argument: 'id'"}
  end

  defp do_execute("memory", %{"operation" => "supersede"} = args) do
    old_id = Map.get(args, "old_id")
    new_id = Map.get(args, "new_id")
    supersession_type = Map.get(args, "type", "update")

    if is_nil(old_id) or is_nil(new_id) do
      {:error, "Missing required arguments: 'old_id' and 'new_id'"}
    else
      execute_memory_supersede(old_id, new_id, supersession_type)
    end
  end

  defp do_execute("memory", %{"operation" => op}) do
    {:error,
     "Unknown memory operation: #{op}. Valid: store, search, list, delete, stats, health, decay_check, get_chain, get_current, get_original, supersede"}
  end

  defp do_execute("memory", _args) do
    {:error, "Missing required argument: 'operation'"}
  end

  # ============================================================================
  # Tool Usage Analytics
  # ============================================================================

  # Get comprehensive tool usage statistics
  defp do_execute("tool_usage", %{"operation" => "stats"} = args) do
    days = Map.get(args, "days", 30)
    limit = Map.get(args, "limit", 50)
    include_daily = Map.get(args, "include_daily", false)

    stats =
      Mimo.Brain.Interaction.tool_usage_stats(
        days: days,
        limit: limit,
        include_daily: include_daily
      )

    {:ok,
     %{
       tool_call_id: UUID.uuid4(),
       status: "success",
       data: stats
     }}
  end

  # Get detailed stats for a specific tool
  defp do_execute("tool_usage", %{"operation" => "detail", "tool_name" => tool_name} = args) do
    days = Map.get(args, "days", 30)
    detail = Mimo.Brain.Interaction.tool_detail(tool_name, days: days)

    {:ok,
     %{
       tool_call_id: UUID.uuid4(),
       status: "success",
       data: detail
     }}
  end

  defp do_execute("tool_usage", %{"operation" => "detail"}) do
    {:error, "Missing required argument: 'tool_name'"}
  end

  # Get quick rankings (default operation)
  defp do_execute("tool_usage", args) when map_size(args) == 0 or args == %{} do
    do_execute("tool_usage", %{"operation" => "stats", "days" => 30, "limit" => 20})
  end

  defp do_execute("tool_usage", %{"operation" => op}) do
    {:error, "Unknown tool_usage operation: #{op}. Valid: stats, detail"}
  end

  # ============================================================================
  # SPEC-011.3: File Ingestion Tool
  # ============================================================================

  # Ingest file content into memory with automatic chunking.
  defp do_execute("ingest", %{"path" => path} = args) do
    strategy = args["strategy"] |> parse_strategy()
    category = Map.get(args, "category", "fact")
    importance = Map.get(args, "importance", 0.5)
    tags = Map.get(args, "tags", [])
    metadata = Map.get(args, "metadata", %{})

    opts = [
      strategy: strategy,
      category: category,
      importance: importance,
      tags: tags,
      metadata: metadata
    ]

    case Mimo.Ingest.ingest_file(path, opts) do
      {:ok, result} ->
        {:ok,
         %{
           tool_call_id: UUID.uuid4(),
           status: "success",
           data: result
         }}

      {:error, {:file_too_large, size, max}} ->
        {:error, "File too large: #{size} bytes (max: #{max} bytes)"}

      {:error, {:too_many_chunks, count, max}} ->
        {:error, "File would create too many chunks: #{count} (max: #{max})"}

      {:error, {:file_error, reason}} ->
        {:error, "File error: #{inspect(reason)}"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "Ingestion failed: #{inspect(reason)}"}
    end
  end

  defp do_execute("ingest", _args) do
    {:error, "Missing required argument: 'path'"}
  end

  # ============================================================================
  # Legacy Tools (kept for backward compatibility)
  # ============================================================================

  defp do_execute("search_vibes", %{"query" => _query} = args) do
    Logger.warning("search_vibes is deprecated, use memory operation=search")
    execute("memory", Map.put(args, "operation", "search"))
  end

  defp do_execute("store_fact", %{"content" => _content, "category" => _category} = args) do
    Logger.warning("store_fact is deprecated, use memory operation=store")
    execute("memory", Map.put(args, "operation", "store"))
  end

  defp do_execute("store_fact", _args) do
    {:error, "Missing required arguments: 'content' and 'category' are required"}
  end

  defp do_execute("recall_procedure", %{"name" => name} = args) do
    # Check if procedural store is enabled before attempting to use it
    if Mimo.Application.feature_enabled?(:procedural_store) do
      version = Map.get(args, "version", "latest")

      case Loader.load(name, version) do
        {:ok, procedure} ->
          {:ok,
           %{
             tool_call_id: UUID.uuid4(),
             status: "success",
             data: %{
               name: procedure.name,
               version: procedure.version,
               description: procedure.description,
               steps: Map.get(procedure.definition, "states", %{}) |> Map.keys(),
               hash: procedure.hash
             }
           }}

        {:error, :not_found} ->
          {:error, "Procedure '#{name}' (version: #{version}) not found"}

        {:error, reason} ->
          {:error, "Failed to load procedure: #{inspect(reason)}"}
      end
    else
      {:error, "Procedural store is not enabled. Set PROCEDURAL_STORE_ENABLED=true to enable."}
    end
  end

  defp do_execute("mimo_reload_skills", _args) do
    case Mimo.ToolRegistry.reload_skills() do
      {:ok, :reloaded} ->
        {:ok,
         %{
           tool_call_id: UUID.uuid4(),
           status: "success",
           data: %{status: "success", message: "Skills reloaded"}
         }}

      {:error, reason} ->
        {:error, "Reload failed: #{inspect(reason)}"}
    end
  end

  defp do_execute("ask_mimo", %{"query" => query}) do
    case Mimo.QueryInterface.ask(query) do
      {:ok, result} ->
        # Sanitize result to ensure all structs are converted to maps for JSON encoding
        sanitized_result = sanitize_for_json(result)

        {:ok,
         %{
           tool_call_id: UUID.uuid4(),
           status: "success",
           data: sanitized_result
         }}

      {:error, reason} ->
        {:error, "Query failed: #{inspect(reason)}"}
    end
  end

  # SPEC-040 v1.2: Awakening Status Tool with Tool Balance Metrics
  defp do_execute("awakening_status", arguments) do
    include_achievements = Map.get(arguments, "include_achievements", false)
    include_guidance = Map.get(arguments, "include_guidance", true)

    case Mimo.Awakening.get_status(include_achievements: include_achievements) do
      {:ok, status} ->
        # Format the response for display
        power = status.power_level
        stats = status.stats

        response = %{
          power_level: %{
            level: power["current"],
            name: power["name"],
            icon: power["icon"],
            xp: power["xp"],
            next_level_xp: power["next_level_xp"],
            progress_percent: power["progress_percent"]
          },
          wisdom_stats: %{
            total_sessions: stats["total_sessions"],
            total_memories: stats["total_memories"],
            total_relationships: stats["total_relationships"],
            total_procedures: stats["total_procedures"],
            active_days: stats["active_days"]
          },
          unlocked_capabilities: status.unlocked_capabilities
        }

        response =
          if include_guidance do
            Map.put(response, :behavioral_guidance, status.behavioral_guidance)
          else
            response
          end

        response =
          if include_achievements do
            Map.put(response, :achievements, status.achievements || [])
          else
            response
          end

        # SPEC-040 v1.2: Add tool balance metrics for behavioral self-awareness
        session_id = Process.get(:mimo_session_id)

        response =
          if session_id do
            case Mimo.Awakening.ContextInjector.build_tool_balance_summary(session_id) do
              nil -> response
              balance_summary -> Map.put(response, :tool_balance, balance_summary)
            end
          else
            response
          end

        {:ok,
         %{
           tool_call_id: UUID.uuid4(),
           status: "success",
           data: response
         }}

      {:error, reason} ->
        {:error, "Failed to get awakening status: #{inspect(reason)}"}
    end
  end

  # Fallback: route unknown tools through Registry (external skills or Mimo.Tools)
  defp do_execute(tool_name, arguments) do
    case Mimo.ToolRegistry.get_tool_owner(tool_name) do
      {:ok, {:mimo_core, _tool_atom}} ->
        # Route to Mimo.Tools core capabilities
        Logger.debug("Dispatching #{tool_name} to Mimo.Tools")

        case Mimo.Tools.dispatch(tool_name, arguments) do
          {:ok, result} ->
            # Try to enrich result with context (non-blocking)
            enriched = try_enrich_result(tool_name, arguments, result)
            {:ok,
             %{
               tool_call_id: UUID.uuid4(),
               status: "success",
               data: enriched
             }}

          {:error, reason} ->
            # Record error for debugging chain detection
            Mimo.RequestInterceptor.record_error(tool_name, reason)
            {:error, "Core tool execution failed: #{inspect(reason)}"}

          # Handle bare :ok (some operations don't return data)
          :ok ->
            {:ok,
             %{
               tool_call_id: UUID.uuid4(),
               status: "success",
               data: %{message: "Operation completed successfully"}
             }}

          # Catch-all for unexpected return types
          other ->
            Logger.warning("Unexpected return from #{tool_name}: #{inspect(other)}")

            {:ok,
             %{
               tool_call_id: UUID.uuid4(),
               status: "success",
               data: other
             }}
        end

      {:ok, {:skill, skill_name, _pid, _tool_def}} ->
        # Route to already-running external skill
        Logger.debug("Routing #{tool_name} to running skill #{skill_name}")

        case Mimo.Skills.Client.call_tool(skill_name, tool_name, arguments) do
          {:ok, result} ->
            {:ok,
             %{
               tool_call_id: UUID.uuid4(),
               status: "success",
               data: result
             }}

          {:error, reason} ->
            {:error, "Skill execution failed: #{inspect(reason)}"}
        end

      {:ok, {:skill_lazy, skill_name, config, _nil}} ->
        # Lazy-spawn external skill on first call
        Logger.debug("Lazy-spawning skill #{skill_name} for tool #{tool_name}")

        case Mimo.Skills.Client.call_tool_sync(skill_name, config, tool_name, arguments) do
          {:ok, result} ->
            {:ok,
             %{
               tool_call_id: UUID.uuid4(),
               status: "success",
               data: result
             }}

          {:error, reason} ->
            {:error, "Skill execution failed: #{inspect(reason)}"}
        end

      {:ok, {:internal, _}} ->
        # Internal tool without specific handler - missing arguments
        {:error, "Missing required arguments for tool: #{tool_name}"}

      {:error, :not_found} ->
        available = Mimo.ToolRegistry.list_all_tools() |> Enum.map(& &1["name"]) |> Enum.take(10)
        {:error, "Unknown tool: #{tool_name}. Available tools include: #{inspect(available)}"}

      {:error, reason} ->
        {:error, "Tool routing failed: #{inspect(reason)}"}
    end
  end

  # Try to enrich a tool result with memory/knowledge context (non-blocking)
  defp try_enrich_result(tool_name, arguments, result) do
    case Mimo.RequestInterceptor.enrich_result(tool_name, arguments, result) do
      {:enriched, enriched_result} -> enriched_result
      {:ok, original} -> original
      _ -> result
    end
  rescue
    _ -> result
  end

  @doc """
  List all supported tools with their schemas.
  """
  @spec list_tools() :: [map()]
  def list_tools do
    Mimo.ToolRegistry.list_all_tools()
  end

  # ============================================================================
  # Private: Memory Operations
  # ============================================================================

  # SPEC-060: Support temporal validity options
  defp execute_memory_store(content, category, importance, opts) do
    # SPEC-034: Route through Memory.persist_memory for TMC integration
    # This ensures contradiction detection and supersession for explicit user stores
    # SPEC-060: Pass temporal validity options (valid_from, valid_until, validity_source)
    case Mimo.Brain.Memory.persist_memory(content, category, importance, opts) do
      {:ok, id} ->
        # Build response data with temporal info if provided
        base_data = %{stored: true, id: id, embedding_generated: true}
        temporal_data = build_temporal_response(opts)
        
        {:ok,
         %{
           tool_call_id: UUID.uuid4(),
           status: "success",
           data: Map.merge(base_data, temporal_data)
         }}

      {:duplicate, id} ->
        # Handle duplicate detection from TMC
        {:ok,
         %{
           tool_call_id: UUID.uuid4(),
           status: "success",
           data: %{stored: true, id: id, duplicate: true, embedding_generated: true}
         }}

      {:error, reason} ->
        {:error, "Failed to store memory: #{inspect(reason)}"}
    end
  end

  # Build temporal validity info for response
  defp build_temporal_response(opts) do
    temporal_fields = [:valid_from, :valid_until, :validity_source]
    
    opts
    |> Keyword.take(temporal_fields)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new(fn {k, v} -> {k, format_datetime(v)} end)
  end

  defp execute_memory_search(args) do
    query = Map.get(args, "query")
    limit = InputValidation.validate_limit(Map.get(args, "limit"), default: 10, max: 200)
    threshold = InputValidation.validate_threshold(Map.get(args, "threshold"), default: 0.3)
    category = Map.get(args, "category")
    time_filter = Map.get(args, "time_filter")
    # SPEC-060: Temporal validity search parameters
    as_of = parse_datetime(Map.get(args, "as_of"))
    valid_at = parse_datetime(Map.get(args, "valid_at"))
    # New: opt-in intelligent routing via MemoryRouter
    use_router = Map.get(args, "use_router", true)

    # Use MemoryRouter for intelligent routing or fall back to direct search
    {base_results, query_type, routing_confidence} =
      if use_router do
        case Mimo.Brain.MemoryRouter.route(query, limit: limit * 2, include_working: true) do
          {:ok, routed_results} ->
            # MemoryRouter returns tuples {memory, score} - convert to map format
            results = normalize_router_results(routed_results)
            # Get query type for observability
            {type, confidence} = Mimo.Brain.MemoryRouter.analyze(query)
            {results, type, confidence}

          {:error, _reason} ->
            # Fallback to direct search
            Logger.warning("MemoryRouter failed, falling back to direct search")
            results = Memory.search_memories(query, limit: limit * 2, min_similarity: threshold)
            {results, :fallback, 0.0}
        end
      else
        # Direct search without router
        results = Memory.search_memories(query, limit: limit * 2, min_similarity: threshold)
        {results, :direct, 1.0}
      end

    # Apply category filter
    filtered =
      if category do
        Enum.filter(base_results, &(&1[:category] == category))
      else
        base_results
      end

    # Apply time filter (SPEC-011.4)
    filtered =
      case time_filter do
        nil ->
          filtered

        filter ->
          case Mimo.Utils.TimeParser.parse(filter) do
            {:ok, {from_dt, to_dt}} ->
              from_naive = DateTime.to_naive(from_dt)
              to_naive = DateTime.to_naive(to_dt)

              Enum.filter(filtered, fn result ->
                case Map.get(result, :inserted_at) do
                  nil ->
                    true

                  dt ->
                    NaiveDateTime.compare(dt, from_naive) != :lt and
                      NaiveDateTime.compare(dt, to_naive) != :gt
                end
              end)

            {:error, _reason} ->
              # Invalid time filter - return all results
              filtered
          end
      end

    # SPEC-060: Apply temporal validity filters
    filtered = apply_temporal_validity_filter(filtered, as_of, valid_at)

    # Take final limit
    results = Enum.take(filtered, limit)

    # Format response
    formatted =
      Enum.map(results, fn r ->
        base = %{
          id: r[:id],
          content: r[:content],
          category: r[:category],
          score: r[:similarity],
          importance: r[:importance],
          created_at: format_datetime(r[:inserted_at])
        }
        
        # SPEC-060: Include temporal validity info when present
        temporal = %{
          valid_from: format_datetime(r[:valid_from]),
          valid_until: format_datetime(r[:valid_until]),
          validity_source: r[:validity_source]
        } |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
        
        Map.merge(base, temporal)
      end)

    # Build temporal context for response
    temporal_context = build_search_temporal_context(as_of, valid_at)

    {:ok,
     %{
       tool_call_id: UUID.uuid4(),
       status: "success",
       data: Map.merge(%{
         results: formatted,
         total_searched: length(base_results),
         # SPEC-XXX: MemoryRouter integration - query type for observability
         query_type: query_type,
         routing_confidence: Float.round(routing_confidence, 2)
       }, temporal_context),
       # SPEC-031 Phase 2: Cross-tool suggestion
       suggestion: "💡 For entity relationships, also check `knowledge operation=query`"
     }}
  end

  # SPEC-060: Apply temporal validity filters to search results
  defp apply_temporal_validity_filter(results, nil, nil), do: results
  
  defp apply_temporal_validity_filter(results, as_of, valid_at) do
    # Determine the effective query time
    query_time = valid_at || as_of || DateTime.utc_now()
    
    Enum.filter(results, fn result ->
      # Check if result has an engram with temporal validity fields
      valid_from = result[:valid_from]
      valid_until = result[:valid_until]
      
      from_ok = is_nil(valid_from) or DateTime.compare(valid_from, query_time) != :gt
      until_ok = is_nil(valid_until) or DateTime.compare(valid_until, query_time) == :gt
      
      from_ok and until_ok
    end)
  end

  # Build temporal search context for response
  defp build_search_temporal_context(nil, nil), do: %{}
  defp build_search_temporal_context(as_of, valid_at) do
    context = %{}
    context = if as_of, do: Map.put(context, :as_of, format_datetime(as_of)), else: context
    context = if valid_at, do: Map.put(context, :valid_at, format_datetime(valid_at)), else: context
    if map_size(context) > 0, do: %{temporal_query: context}, else: %{}
  end

  # Helper to normalize MemoryRouter results (tuples) to map format
  defp normalize_router_results(results) when is_list(results) do
    Enum.map(results, fn
      # MemoryRouter returns {memory_map, score} tuples
      {memory, score} when is_map(memory) ->
        memory
        |> Map.put(:similarity, score)
        |> Map.put_new(:id, Map.get(memory, :id))
        |> Map.put_new(:content, Map.get(memory, :content))
        |> Map.put_new(:category, Map.get(memory, :category))
        |> Map.put_new(:importance, Map.get(memory, :importance, 0.5))
        |> Map.put_new(:inserted_at, Map.get(memory, :inserted_at))

      # HybridRetriever already returns maps with :similarity
      memory when is_map(memory) ->
        memory

      # Handle any other format
      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_router_results(_), do: []

  defp execute_memory_list(args) do
    limit = InputValidation.validate_limit(Map.get(args, "limit"), default: 20, max: 200)
    offset = InputValidation.validate_offset(Map.get(args, "offset"))
    category = Map.get(args, "category")
    sort = Map.get(args, "sort", "recent")

    query = from(e in Engram, limit: ^limit, offset: ^offset)

    query =
      if category do
        from(e in query, where: e.category == ^category)
      else
        query
      end

    query =
      case sort do
        "importance" -> from(e in query, order_by: [desc: e.importance])
        # Approximate
        "decay_score" -> from(e in query, order_by: [asc: e.importance])
        _ -> from(e in query, order_by: [desc: e.inserted_at])
      end

    memories = Repo.all(query)
    total = Repo.one(from(e in Engram, select: count(e.id)))

    formatted =
      Enum.map(memories, fn m ->
        %{
          id: m.id,
          content: m.content,
          category: m.category,
          importance: m.importance,
          created_at: format_datetime(m.inserted_at),
          access_count: m.access_count,
          protected: m.protected
        }
      end)

    {:ok,
     %{
       tool_call_id: UUID.uuid4(),
       status: "success",
       data: %{
         memories: formatted,
         total: total,
         offset: offset,
         limit: limit
       }
     }}
  end

  defp execute_memory_delete(id) do
    case Repo.get(Engram, id) do
      nil ->
        {:error, "Memory not found: #{id}"}

      engram ->
        case Repo.delete(engram) do
          {:ok, _deleted} ->
            {:ok,
             %{
               tool_call_id: UUID.uuid4(),
               status: "success",
               data: %{deleted: true, id: id}
             }}

          {:error, reason} ->
            {:error, "Failed to delete memory: #{inspect(reason)}"}
        end
    end
  end

  defp execute_memory_stats do
    # Get counts by category
    by_category =
      Repo.all(
        from(e in Engram,
          group_by: e.category,
          select: {e.category, count(e.id)}
        )
      )
      |> Map.new()

    # Get aggregate stats
    stats =
      Repo.one(
        from(e in Engram,
          select: %{
            total: count(e.id),
            avg_importance: avg(e.importance),
            min_inserted: min(e.inserted_at),
            max_inserted: max(e.inserted_at)
          }
        )
      )

    # Get at-risk count (low decay score approximation)
    at_risk_count =
      Repo.one(
        from(e in Engram,
          where: e.importance < 0.3 and e.protected == false,
          select: count(e.id)
        )
      )

    {:ok,
     %{
       tool_call_id: UUID.uuid4(),
       status: "success",
       data: %{
         total_memories: stats.total || 0,
         by_category: by_category,
         avg_importance: stats.avg_importance && Float.round(stats.avg_importance, 2),
         at_risk_count: at_risk_count || 0,
         oldest: format_datetime(stats.min_inserted),
         newest: format_datetime(stats.max_inserted)
       }
     }}
  end

  defp execute_memory_health do
    # Get brain system health report from HealthMonitor
    report =
      try do
        Mimo.Brain.HealthMonitor.health_report()
      rescue
        _ -> %{error: "HealthMonitor not running"}
      catch
        :exit, _ -> %{error: "HealthMonitor process not available"}
      end

    {:ok,
     %{
       tool_call_id: UUID.uuid4(),
       status: "success",
       data: %{
         healthy: Map.get(report, :healthy, false),
         last_check: format_datetime(Map.get(report, :last_check)),
         issues: Map.get(report, :issues, []),
         metrics: Map.get(report, :metrics, %{}),
         check_count: Map.get(report, :check_count, 0),
         error: Map.get(report, :error)
       }
     }}
  end

  defp execute_memory_decay_check(threshold, limit) do
    # Get memories and calculate decay scores
    memories =
      Repo.all(
        from(e in Engram,
          where: e.protected == false,
          limit: ^(limit * 2),
          order_by: [asc: e.importance]
        )
      )

    # Calculate decay scores and filter
    at_risk =
      memories
      |> Enum.map(fn m ->
        score = DecayScorer.calculate_score(m)
        days_until = DecayScorer.predict_forgetting(m, threshold)

        %{
          id: m.id,
          content: String.slice(m.content, 0, 200),
          decay_score: Float.round(score, 3),
          days_until_forgotten: days_until,
          category: m.category,
          importance: m.importance
        }
      end)
      |> Enum.filter(&(&1.decay_score < threshold))
      |> Enum.take(limit)

    {:ok,
     %{
       tool_call_id: UUID.uuid4(),
       status: "success",
       data: %{
         at_risk: at_risk,
         threshold: threshold,
         total_checked: length(memories)
       }
     }}
  end

  # SPEC-034: Temporal Memory Chains - Implementation Functions
  defp execute_memory_get_chain(id) do
    chain = Memory.get_chain(id)

    formatted_chain =
      Enum.map(chain, fn engram ->
        %{
          id: engram.id,
          content: String.slice(engram.content, 0, 200),
          category: engram.category,
          importance: engram.importance,
          active: Engram.active?(engram),
          supersedes_id: engram.supersedes_id,
          superseded_at: format_datetime(engram.superseded_at),
          supersession_type: engram.supersession_type,
          inserted_at: format_datetime(engram.inserted_at)
        }
      end)

    {:ok,
     %{
       tool_call_id: UUID.uuid4(),
       status: "success",
       data: %{
         chain: formatted_chain,
         chain_length: length(chain),
         original_id: if(chain != [], do: hd(chain).id, else: nil),
         current_id: if(chain != [], do: List.last(chain).id, else: nil)
       }
     }}
  end

  defp execute_memory_get_current(id) do
    case Memory.get_current(id) do
      nil ->
        {:error, "Memory not found: #{id}"}

      engram ->
        {:ok,
         %{
           tool_call_id: UUID.uuid4(),
           status: "success",
           data: %{
             id: engram.id,
             content: engram.content,
             category: engram.category,
             importance: engram.importance,
             is_current: true,
             supersedes_id: engram.supersedes_id,
             inserted_at: format_datetime(engram.inserted_at)
           }
         }}
    end
  end

  defp execute_memory_get_original(id) do
    case Memory.get_original(id) do
      nil ->
        {:error, "Memory not found: #{id}"}

      engram ->
        {:ok,
         %{
           tool_call_id: UUID.uuid4(),
           status: "success",
           data: %{
             id: engram.id,
             content: engram.content,
             category: engram.category,
             importance: engram.importance,
             is_original: true,
             chain_length: Memory.chain_length(engram.id),
             inserted_at: format_datetime(engram.inserted_at)
           }
         }}
    end
  end

  defp execute_memory_supersede(old_id, new_id, supersession_type) do
    old_engram = Repo.get(Engram, old_id)
    new_engram = Repo.get(Engram, new_id)

    cond do
      is_nil(old_engram) ->
        {:error, "Old memory not found: #{old_id}"}

      is_nil(new_engram) ->
        {:error, "New memory not found: #{new_id}"}

      not is_nil(old_engram.superseded_at) ->
        {:error, "Memory #{old_id} is already superseded"}

      true ->
        # Update old engram to mark as superseded (graceful handling)
        old_update_result = Repo.update(
            Engram.changeset(old_engram, %{
              superseded_at: DateTime.utc_now() |> DateTime.truncate(:second)
            })
          )

        case old_update_result do
          {:ok, updated_old} ->
            # Update new engram to link to old one
            new_update_result = Repo.update(
                Engram.changeset(new_engram, %{
                  supersedes_id: old_id,
                  supersession_type: supersession_type
                })
              )

            case new_update_result do
              {:ok, updated_new} ->
                {:ok,
                 %{
                   tool_call_id: UUID.uuid4(),
                   status: "success",
                   data: %{
                     superseded_id: updated_old.id,
                     successor_id: updated_new.id,
                     supersession_type: supersession_type,
                     message: "Memory #{old_id} superseded by #{new_id}"
                   }
                 }}

              {:error, changeset} ->
                {:error, "Failed to update new memory: #{inspect(changeset.errors)}"}
            end

          {:error, changeset} ->
            {:error, "Failed to update old memory: #{inspect(changeset.errors)}"}
        end
    end
  end

  # ============================================================================
  # Private: Helpers
  # ============================================================================

  defp get_latest_execution(procedure_name) do
    Repo.one(
      from(e in Execution,
        where: e.procedure_name == ^procedure_name,
        order_by: [desc: e.inserted_at],
        limit: 1
      )
    )
  end

  defp parse_strategy(nil), do: :auto
  defp parse_strategy("auto"), do: :auto
  defp parse_strategy("paragraphs"), do: :paragraphs
  defp parse_strategy("markdown"), do: :markdown
  defp parse_strategy("lines"), do: :lines
  defp parse_strategy("sentences"), do: :sentences
  defp parse_strategy("whole"), do: :whole
  defp parse_strategy(_), do: :auto

  defp format_datetime(nil), do: nil
  defp format_datetime(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(other), do: inspect(other)

  # SPEC-060: Parse datetime strings for temporal validity
  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = dt), do: dt
  defp parse_datetime(string) when is_binary(string) do
    case DateTime.from_iso8601(string) do
      {:ok, dt, _offset} -> dt
      {:error, _} ->
        # Try parsing as date only (assume start of day UTC)
        case Date.from_iso8601(string) do
          {:ok, date} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
          {:error, _} -> nil
        end
    end
  end
  defp parse_datetime(_), do: nil

  # Recursively sanitize data for JSON encoding - converts structs to maps
  defp sanitize_for_json(%{__struct__: _} = struct) do
    struct
    |> Map.from_struct()
    |> Map.drop([:embedding, :embedding_int8, :embedding_binary, :__meta__])
    |> sanitize_for_json()
  end

  defp sanitize_for_json(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, sanitize_for_json(v)} end)
  end

  defp sanitize_for_json(list) when is_list(list) do
    Enum.map(list, &sanitize_for_json/1)
  end

  defp sanitize_for_json(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> sanitize_for_json()
  end

  defp sanitize_for_json(other), do: other
end
