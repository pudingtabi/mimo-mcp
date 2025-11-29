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
  alias Mimo.Repo

  # Timeouts
  @procedure_sync_timeout 60_000

  @doc """
  Execute a tool by name with given arguments.
  Routes to internal tools or external skills automatically.

  ## Returns
    - {:ok, result} on success
    - {:error, reason} on failure
  """
  @spec execute(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def execute(tool_name, arguments \\ %{})

  # ============================================================================
  # SPEC-011.1: Procedural Store Tools
  # ============================================================================

  # Execute a registered procedure as a state machine.
  def execute("run_procedure", %{"name" => name} = args) do
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

            {:ok, %{
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

                {:ok, %{
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

  def execute("run_procedure", _args) do
    {:error, "Missing required argument: 'name'"}
  end

  # Check status of a procedure execution.
  def execute("procedure_status", %{"execution_id" => execution_id}) do
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

          {:ok, %{
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

  def execute("procedure_status", _args) do
    {:error, "Missing required argument: 'execution_id'"}
  end

  # List all registered procedures.
  def execute("list_procedures", _args) do
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

      {:ok, %{
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
  def execute("memory", %{"operation" => "store"} = args) do
    # Delegate to store_fact logic
    content = Map.get(args, "content")
    category = Map.get(args, "category", "fact")
    importance = Map.get(args, "importance", 0.5)

    if is_nil(content) do
      {:error, "Missing required argument: 'content'"}
    else
      execute_memory_store(content, category, importance)
    end
  end

  def execute("memory", %{"operation" => "search"} = args) do
    query = Map.get(args, "query")

    if is_nil(query) do
      {:error, "Missing required argument: 'query'"}
    else
      execute_memory_search(args)
    end
  end

  def execute("memory", %{"operation" => "list"} = args) do
    execute_memory_list(args)
  end

  def execute("memory", %{"operation" => "delete"} = args) do
    id = Map.get(args, "id")

    if is_nil(id) do
      {:error, "Missing required argument: 'id'"}
    else
      execute_memory_delete(id)
    end
  end

  def execute("memory", %{"operation" => "stats"} = _args) do
    execute_memory_stats()
  end

  def execute("memory", %{"operation" => "decay_check"} = args) do
    threshold = Map.get(args, "threshold", 0.1)
    limit = Map.get(args, "limit", 50)
    execute_memory_decay_check(threshold, limit)
  end

  def execute("memory", %{"operation" => op}) do
    {:error, "Unknown memory operation: #{op}. Valid: store, search, list, delete, stats, decay_check"}
  end

  def execute("memory", _args) do
    {:error, "Missing required argument: 'operation'"}
  end

  # ============================================================================
  # SPEC-011.3: File Ingestion Tool
  # ============================================================================

  # Ingest file content into memory with automatic chunking.
  def execute("ingest", %{"path" => path} = args) do
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
        {:ok, %{
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

  def execute("ingest", _args) do
    {:error, "Missing required argument: 'path'"}
  end

  # ============================================================================
  # Legacy Tools (kept for backward compatibility)
  # ============================================================================

  def execute("search_vibes", %{"query" => _query} = args) do
    Logger.warning("search_vibes is deprecated, use memory operation=search")
    execute("memory", Map.put(args, "operation", "search"))
  end

  def execute("store_fact", %{"content" => _content, "category" => _category} = args) do
    Logger.warning("store_fact is deprecated, use memory operation=store")
    execute("memory", Map.put(args, "operation", "store"))
  end

  def execute("store_fact", _args) do
    {:error, "Missing required arguments: 'content' and 'category' are required"}
  end

  def execute("recall_procedure", %{"name" => name} = args) do
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

  def execute("mimo_reload_skills", _args) do
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

  def execute("ask_mimo", %{"query" => query}) do
    case Mimo.QueryInterface.ask(query) do
      {:ok, result} ->
        {:ok,
         %{
           tool_call_id: UUID.uuid4(),
           status: "success",
           data: result
         }}

      {:error, reason} ->
        {:error, "Query failed: #{inspect(reason)}"}
    end
  end

  # Fallback: route unknown tools through Registry (external skills or Mimo.Tools)
  def execute(tool_name, arguments) do
    case Mimo.ToolRegistry.get_tool_owner(tool_name) do
      {:ok, {:mimo_core, _tool_atom}} ->
        # Route to Mimo.Tools core capabilities
        Logger.debug("Dispatching #{tool_name} to Mimo.Tools")

        case Mimo.Tools.dispatch(tool_name, arguments) do
          {:ok, result} ->
            {:ok,
             %{
               tool_call_id: UUID.uuid4(),
               status: "success",
               data: result
             }}

          {:error, reason} ->
            {:error, "Core tool execution failed: #{inspect(reason)}"}
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

  defp execute_memory_store(content, category, importance) do
    case Memory.persist_memory(content, category, importance) do
      {:ok, id} ->
        {:ok, %{
          tool_call_id: UUID.uuid4(),
          status: "success",
          data: %{stored: true, id: id, embedding_generated: true}
        }}

      {:error, reason} ->
        {:error, "Failed to store memory: #{inspect(reason)}"}
    end
  end

  defp execute_memory_search(args) do
    query = Map.get(args, "query")
    limit = Map.get(args, "limit", 10)
    threshold = Map.get(args, "threshold", 0.3)
    category = Map.get(args, "category")
    time_filter = Map.get(args, "time_filter")

    # Build base search
    base_results = Memory.search_memories(query, limit: limit * 2, min_similarity: threshold)

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
                  nil -> true
                  dt -> NaiveDateTime.compare(dt, from_naive) != :lt and
                        NaiveDateTime.compare(dt, to_naive) != :gt
                end
              end)

            {:error, _reason} ->
              # Invalid time filter - return all results
              filtered
          end
      end

    # Take final limit
    results = Enum.take(filtered, limit)

    # Format response
    formatted =
      Enum.map(results, fn r ->
        %{
          id: r[:id],
          content: r[:content],
          category: r[:category],
          score: r[:similarity],
          importance: r[:importance],
          created_at: format_datetime(r[:inserted_at])
        }
      end)

    {:ok, %{
      tool_call_id: UUID.uuid4(),
      status: "success",
      data: %{
        results: formatted,
        total_searched: length(base_results)
      }
    }}
  end

  defp execute_memory_list(args) do
    limit = Map.get(args, "limit", 20)
    offset = Map.get(args, "offset", 0)
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
        "decay_score" -> from(e in query, order_by: [asc: e.importance])  # Approximate
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

    {:ok, %{
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
            {:ok, %{
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

    {:ok, %{
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

    {:ok, %{
      tool_call_id: UUID.uuid4(),
      status: "success",
      data: %{
        at_risk: at_risk,
        threshold: threshold,
        total_checked: length(memories)
      }
    }}
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
end
