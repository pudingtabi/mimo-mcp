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
  alias Mimo.Cognitive.FeedbackLoop
  alias Mimo.Repo
  alias Mimo.Awakening.Hooks, as: AwakeningHooks

  # Suppress Dialyzer warnings for defensive catch-all patterns
  # These patterns exist for robustness but Dialyzer infers they can't match current callers
  @dialyzer [
    {:nowarn_function, build_suggestion_hint: 2},
    {:nowarn_function, extract_output_text: 1},
    {:nowarn_function, analyze_result: 1},
    {:nowarn_function, extract_memory_result_id: 1},
    {:nowarn_function, normalize_router_results: 1}
  ]

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

    # Track cognitive lifecycle (non-blocking)
    track_cognitive_lifecycle(tool_name, arguments)

    # 🦾 IRON MAN SUIT: Gateway enforcement (SPEC-091)
    # Uses ReasoningSession.list_active() which persists across MCP calls!
    # Set MIMO_GATEWAY_ENABLED=false to disable
    gateway_enabled = Application.get_env(:mimo_mcp, :gateway_enabled, true)

    if gateway_enabled do
      session_id = arguments["_gateway_session"] || arguments[:_gateway_session]

      case Mimo.Gateway.would_allow?(session_id, tool_name, arguments) do
        {:blocked, reason, suggestion} ->
          # Gateway blocked - return string error that MCP can handle
          {:error, "🛡️ Gateway blocked: #{reason}. Suggestion: #{suggestion}"}

        _ ->
          # Gateway allows - proceed with execution
          execute_with_enrichment(tool_name, arguments)
      end
    else
      # Gateway disabled - proceed directly
      execute_with_enrichment(tool_name, arguments)
    end
  end

  # Extracted the original execute logic
  defp execute_with_enrichment(tool_name, arguments) do
    # SPEC-INTERCEPTOR: Analyze request for cognitive enhancement
    result =
      case Mimo.RequestInterceptor.analyze_and_enrich(tool_name, arguments) do
        {:enriched, context, metadata} ->
          # Auto-enriched with cognitive context - add to arguments
          enriched_args = Map.put(arguments, "_mimo_context", context)
          res = do_execute(tool_name, enriched_args)
          add_cognitive_metadata(res, metadata)

        {:suggest, cognitive_tool, query, reason} ->
          # Execute the tool but add suggestion to result
          res = do_execute(tool_name, arguments)
          add_cognitive_suggestion(res, cognitive_tool, query, reason)

        {:continue, nil} ->
          # Normal execution
          do_execute(tool_name, arguments)
      end

    # Phase 3 L3: Add experience context to results (non-blocking enhancement)
    result = add_experience_context(result, tool_name)

    # Auto-reflect on significant outputs (non-blocking, feeds Optimizer)
    maybe_auto_reflect(tool_name, arguments, result)

    # Track context window usage (non-blocking)
    track_context_window_usage(arguments, result)

    # Phase 3: Predictive context prefetching (non-blocking)
    maybe_prefetch_context(tool_name, arguments, result)

    # SPEC-074: Record tool execution outcome for cognitive learning (non-blocking)
    record_tool_outcome(tool_name, arguments, result)

    # SPEC-040: Award XP for tool execution (non-blocking)
    AwakeningHooks.tool_executed(tool_name, result)

    result
  end

  # Track tool usage in cognitive lifecycle (non-blocking)
  defp track_cognitive_lifecycle(tool_name, arguments) do
    # Extract thread_id from arguments or use default
    thread_id = arguments["_thread_id"] || arguments[:_thread_id] || "default"
    # Extract operation from arguments
    operation = arguments["operation"] || arguments[:operation]

    # Fire-and-forget tracking
    spawn(fn ->
      try do
        Mimo.Brain.CognitiveLifecycle.track_transition(thread_id, tool_name, operation)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end)
  end

  # Add cognitive metadata to successful results
  defp add_cognitive_metadata({:ok, result}, metadata) when is_map(result) do
    {:ok, Map.put(result, :_cognitive_enhancement, metadata)}
  end

  defp add_cognitive_metadata(result, _metadata), do: result

  # Add cognitive suggestion to successful results
  defp add_cognitive_suggestion({:ok, result}, tool, query, reason) when is_map(result) do
    hint = build_suggestion_hint(tool, query)

    suggestion = %{
      recommended_tool: tool,
      query: query,
      reason: reason,
      hint: hint
    }

    # Track prompt for self-improving optimization (non-blocking)
    if hint do
      spawn(fn ->
        try do
          Mimo.Cognitive.PromptOptimizer.track_prompt(hint, %{
            type: :cognitive_suggestion,
            tool_name: to_string(tool),
            query: query
          })
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end
      end)
    end

    {:ok, Map.put(result, :_cognitive_suggestion, suggestion)}
  end

  defp add_cognitive_suggestion(result, _tool, _query, _reason), do: result

  # Phase 3 L3: Add experience context to results for learning-aware execution
  # Shows historical success rates for this tool, helping agents make informed decisions
  defp add_experience_context({:ok, result}, tool_name) when is_map(result) do
    try do
      stats = Mimo.Cognitive.FeedbackLoop.tool_execution_stats(tool_name)

      # Only add context if there's meaningful data (at least 5 executions)
      if stats.total >= 5 do
        experience = %{
          past_executions: stats.total,
          success_rate: stats.success_rate,
          trend: stats.recent_trend
        }

        {:ok, Map.put(result, :_experience_context, experience)}
      else
        {:ok, result}
      end
    rescue
      _ -> {:ok, result}
    catch
      _, _ -> {:ok, result}
    end
  end

  defp add_experience_context(result, _tool_name), do: result

  defp build_suggestion_hint("reason", problem) do
    "💡 Consider using structured reasoning (reason: guided) for: #{String.slice(problem, 0, 50)}..."
  end

  defp build_suggestion_hint("knowledge", query) do
    "💡 Consider querying the knowledge graph for: #{String.slice(query, 0, 50)}..."
  end

  defp build_suggestion_hint("prepare_context", query) do
    "💡 Consider preparing context first (meta: prepare_context) for: #{String.slice(query, 0, 50)}..."
  end

  defp build_suggestion_hint(_, _), do: nil

  # Register activity with the ActivityTracker (non-blocking)
  defp register_activity do
    if Process.whereis(Mimo.Brain.ActivityTracker) do
      Mimo.Brain.ActivityTracker.register_activity()
    end
  end

  # Auto-reflect on significant tool outputs (feeds Evaluator-Optimizer)
  # Non-blocking: spawns a task to evaluate output quality
  defp maybe_auto_reflect(tool_name, arguments, {:ok, result}) when is_map(result) do
    # Check if this tool should auto-reflect
    tool_atom = String.to_existing_atom(tool_name)
    should_reflect = Mimo.Brain.Reflector.Config.should_auto_reflect?(tool_atom)

    if should_reflect do
      # Only reflect on substantial outputs (> 100 chars when serialized)
      output_text = extract_output_text(result)

      if String.length(output_text) > 100 do
        spawn(fn ->
          try do
            # Build context from arguments
            context = %{
              tool: tool_name,
              operation: arguments["operation"],
              query: arguments["query"] || arguments["path"] || arguments["command"]
            }

            # Lightweight evaluation (skip full refinement)
            case Mimo.Brain.Reflector.reflect_and_refine(output_text, context,
                   skip_refinement: true,
                   store_outcome: true
                 ) do
              {:ok, _} -> :ok
              {:uncertain, _} -> :ok
              {:error, _} -> :ok
            end
          rescue
            _ -> :ok
          catch
            :exit, _ -> :ok
          end
        end)
      end
    end
  rescue
    # String.to_existing_atom can raise if atom doesn't exist
    ArgumentError -> :ok
  end

  defp maybe_auto_reflect(_tool_name, _arguments, _result), do: :ok

  # Extract displayable text from tool result for reflection
  defp extract_output_text(result) when is_map(result) do
    cond do
      Map.has_key?(result, :content) -> to_string(result.content)
      Map.has_key?(result, "content") -> to_string(result["content"])
      Map.has_key?(result, :output) -> to_string(result.output)
      Map.has_key?(result, "output") -> to_string(result["output"])
      Map.has_key?(result, :data) -> inspect(result.data, limit: 500)
      Map.has_key?(result, "data") -> inspect(result["data"], limit: 500)
      true -> inspect(result, limit: 500)
    end
  end

  defp extract_output_text(result), do: inspect(result, limit: 500)

  # Track context window usage for the session (non-blocking)
  defp track_context_window_usage(arguments, {:ok, result}) when is_map(result) do
    thread_id = arguments["_thread_id"] || arguments[:_thread_id] || "default"
    model = arguments["_model"] || arguments[:_model] || "opus"

    spawn(fn ->
      try do
        # Estimate tokens from result
        output_text = extract_output_text(result)
        tokens = Mimo.Context.BudgetAllocator.estimate_string_tokens(output_text)

        # Track in ContextWindowManager
        if Process.whereis(Mimo.Context.ContextWindowManager) do
          Mimo.Context.ContextWindowManager.track_usage(thread_id, tokens, model: model)
        end
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end)
  end

  defp track_context_window_usage(_arguments, _result), do: :ok

  # Phase 3: Predictive context prefetching (non-blocking)
  # Uses AccessPatternTracker and Prefetcher to anticipate future context needs
  defp maybe_prefetch_context(tool_name, arguments, {:ok, result}) when is_map(result) do
    spawn(fn ->
      try do
        # Extract query/context from arguments
        query = extract_query_from_args(tool_name, arguments)

        if query && String.length(query) > 3 do
          # Track access pattern for learning
          track_access_pattern(tool_name, arguments, result)

          # Predict and prefetch likely next context needs
          prefetch_predicted_context(query, tool_name)
        end
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end)
  end

  defp maybe_prefetch_context(_tool_name, _arguments, _result), do: :ok

  # SPEC-074: Record tool execution outcomes for cognitive learning
  # This enables the FeedbackLoop to learn from tool success/failure patterns
  defp record_tool_outcome(tool_name, arguments, result) do
    spawn(fn ->
      try do
        {success, latency_ms} = analyze_result(result)
        operation = arguments["operation"] || arguments[:operation] || "default"

        context = %{
          tool: tool_name,
          operation: operation,
          has_context: Map.has_key?(arguments, "_mimo_context")
        }

        outcome = %{
          success: success,
          latency_ms: latency_ms,
          timestamp: DateTime.utc_now()
        }

        FeedbackLoop.record_outcome(:tool_execution, context, outcome)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end)
  end

  # Analyze result to determine success and extract timing
  defp analyze_result({:ok, result}) when is_map(result) do
    latency = result["latency_ms"] || result[:latency_ms] || 0
    {true, latency}
  end

  defp analyze_result({:ok, _}), do: {true, 0}
  defp analyze_result({:error, _}), do: {false, 0}
  defp analyze_result(_), do: {true, 0}

  # Tool-specific field priorities for query extraction
  @query_fields %{
    "memory" => ~w(query content),
    "file" => ~w(path pattern),
    "knowledge" => ~w(query text),
    "code" => ~w(name path),
    "ask_mimo" => ~w(query),
    "reason" => ~w(problem thought),
    "web" => ~w(query url)
  }

  @default_query_fields ~w(query path name)

  # Extract query/context from tool arguments based on tool type
  defp extract_query_from_args("terminal", arguments) do
    cmd = get_arg(arguments, "command") || ""
    extract_command_context(cmd)
  end

  defp extract_query_from_args(tool_name, arguments) do
    fields = Map.get(@query_fields, tool_name, @default_query_fields)
    find_first_arg(arguments, fields)
  end

  # Find first non-nil argument from a list of field names
  defp find_first_arg(arguments, fields) do
    Enum.find_value(fields, fn field ->
      get_arg(arguments, field)
    end)
  end

  # Get argument by name, checking both string and atom keys
  defp get_arg(arguments, field) when is_binary(field) do
    arguments[field] || arguments[String.to_existing_atom(field)]
  rescue
    ArgumentError -> arguments[field]
  end

  defp extract_command_context(command) when is_binary(command) do
    # Extract meaningful context from shell commands
    cond do
      String.contains?(command, "test") -> "testing"
      String.contains?(command, "build") or String.contains?(command, "compile") -> "building"
      String.contains?(command, "install") -> "dependencies"
      String.contains?(command, "git") -> "version control"
      true -> nil
    end
  end

  defp extract_command_context(_), do: nil

  # Track access pattern for predictive learning
  defp track_access_pattern(tool_name, arguments, result) do
    if Process.whereis(Mimo.Context.AccessPatternTracker) do
      source_type = tool_name_to_source_type(tool_name)
      source_id = extract_source_id(tool_name, arguments, result)
      task_query = extract_query_from_args(tool_name, arguments) || ""

      Mimo.Context.AccessPatternTracker.track_access(
        source_type,
        source_id,
        task: task_query,
        tier: result[:tier] || result["tier"]
      )
    end
  end

  defp tool_name_to_source_type(tool_name) do
    case tool_name do
      "memory" -> :memory
      "code" -> :code_symbol
      "knowledge" -> :knowledge
      "file" -> :file
      _ -> :other
    end
  end

  defp extract_source_id("memory", arguments, result) do
    extract_memory_result_id(result) || get_arg(arguments, "query") || "unknown"
  end

  defp extract_source_id("file", arguments, _result) do
    get_arg(arguments, "path") || "unknown"
  end

  defp extract_source_id("code", arguments, _result) do
    get_arg(arguments, "name") || get_arg(arguments, "path") || "unknown"
  end

  defp extract_source_id(_tool_name, _arguments, _result), do: "unknown"

  defp extract_memory_result_id(%{items: [%{id: id} | _]}), do: id
  defp extract_memory_result_id(%{"items" => [%{"id" => id} | _]}), do: id
  defp extract_memory_result_id(_), do: nil

  # Prefetch context predicted to be needed next
  defp prefetch_predicted_context(query, tool_name) do
    if Process.whereis(Mimo.Context.Prefetcher) do
      # Determine which sources to prefetch based on current tool
      sources = predict_next_sources(tool_name)

      Mimo.Context.Prefetcher.prefetch_for_query(query, sources: sources, priority: :normal)
    end
  end

  # Predict which sources will likely be needed next based on current tool
  defp predict_next_sources(tool_name) do
    case tool_name do
      "ask_mimo" ->
        # After consulting mimo, likely to access memory or code
        [:memory, :knowledge, :code_symbol]

      "memory" ->
        # After memory search, might look at code or knowledge
        [:code_symbol, :knowledge]

      "file" ->
        # After file ops, might search memory or symbols
        [:memory, :code_symbol]

      "code" ->
        # After code analysis, might access related files or memory
        [:file, :memory]

      "knowledge" ->
        # After knowledge query, might access memory or code
        [:memory, :code_symbol]

      "reason" ->
        # After reasoning, might access any source
        [:memory, :knowledge, :code_symbol]

      _ ->
        # Default: memory and knowledge are common
        [:memory, :knowledge]
    end
  end

  defp do_execute(tool_name, arguments)

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

  # Unified memory operations: store, search, list, delete, stats, decay_check.
  defp do_execute("memory", %{"operation" => "store"} = args) do
    # Delegate to store_fact logic
    content = Map.get(args, "content")
    category = Map.get(args, "category", "fact")
    importance = Map.get(args, "importance", 0.5)

    # SPEC-060: Temporal validity options
    temporal_opts =
      [
        valid_from: parse_datetime(Map.get(args, "valid_from")),
        valid_until: parse_datetime(Map.get(args, "valid_until")),
        validity_source: Map.get(args, "validity_source")
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

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

  # SPEC-106: Add synthesize operation - triggers memory synthesis/consolidation
  defp do_execute("memory", %{"operation" => "synthesize"} = args) do
    query = Map.get(args, "query")

    result =
      if query do
        # Query-based synthesis using QueryInterface (same as ask_mimo)
        case Mimo.QueryInterface.ask(query, nil, timeout_ms: 30_000) do
          {:ok, response} ->
            {:ok, %{type: :query_synthesis, query: query, response: sanitize_for_json(response)}}

          {:error, reason} ->
            {:error, "Synthesis failed: #{inspect(reason)}"}
        end
      else
        # Background synthesis using Synthesizer
        case Mimo.Brain.Synthesizer.synthesize_now() do
          {:ok, stats} -> {:ok, %{type: :background_synthesis, stats: stats}}
          {:error, reason} -> {:error, "Synthesis failed: #{inspect(reason)}"}
        end
      end

    case result do
      {:ok, data} ->
        {:ok, %{tool_call_id: UUID.uuid4(), status: "success", data: data}}

      {:error, msg} ->
        {:error, msg}
    end
  end

  # SPEC-106: Add graph operation - redirects to knowledge dispatcher for graph queries
  defp do_execute("memory", %{"operation" => "graph"} = args) do
    # Redirect to knowledge dispatcher which handles all graph operations
    case Mimo.Tools.Dispatchers.Knowledge.dispatch_graph(args) do
      {:ok, result} ->
        {:ok,
         %{
           tool_call_id: UUID.uuid4(),
           status: "success",
           data: result,
           note:
             "Graph operations are handled by the knowledge tool. Consider using 'knowledge operation=query' directly."
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # SPEC-106: Add ingest operation - ingests files/text into memory
  defp do_execute("memory", %{"operation" => "ingest"} = args) do
    path = Map.get(args, "path")
    content = Map.get(args, "content")
    strategy = Map.get(args, "strategy", "auto") |> String.to_atom()
    category = Map.get(args, "category", "fact")
    importance = Map.get(args, "importance", 0.5)
    tags = Map.get(args, "tags", [])
    metadata = Map.get(args, "metadata", %{})

    result =
      cond do
        path && path != "" ->
          # Ingest from file
          Mimo.Ingest.ingest_file(path,
            strategy: strategy,
            category: category,
            importance: importance,
            tags: tags,
            metadata: metadata
          )

        content && content != "" ->
          # Ingest from text content
          Mimo.Ingest.ingest_text(content,
            strategy: strategy,
            category: category,
            importance: importance,
            tags: tags,
            metadata: metadata
          )

        true ->
          {:error, "Missing required argument: 'path' or 'content'"}
      end

    case result do
      {:ok, data} ->
        {:ok, %{tool_call_id: UUID.uuid4(), status: "success", data: data}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_execute("memory", %{"operation" => op}) do
    {:error,
     "Unknown memory operation: #{op}. Valid: store, search, list, delete, stats, health, decay_check, get_chain, get_current, get_original, supersede, synthesize, graph, ingest"}
  end

  defp do_execute("memory", _args) do
    {:error, "Missing required argument: 'operation'"}
  end

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

  defp do_execute("ask_mimo", %{"query" => query} = args) do
    # Support optional timeout parameter (default: 45s from TimeoutConfig)
    timeout = Map.get(args, "timeout", Mimo.TimeoutConfig.query_timeout())

    case Mimo.QueryInterface.ask(query, nil, timeout_ms: timeout) do
      {:ok, result} ->
        # Sanitize result to ensure all structs are converted to maps for JSON encoding
        sanitized_result = sanitize_for_json(result)

        {:ok,
         %{
           tool_call_id: UUID.uuid4(),
           status: "success",
           data: sanitized_result
         }}

      {:error, :timeout} ->
        {:error, "Query timed out after #{timeout}ms. Try a simpler query or increase timeout."}

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
            total_sessions: stats["sessions"],
            total_memories: stats["memories"],
            total_relationships: stats["relationships"],
            total_procedures: stats["procedures"],
            active_days: stats["days_active"]
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
        execute_mimo_core(tool_name, arguments)

      {:ok, {:skill, skill_name, _pid, _tool_def}} ->
        execute_running_skill(skill_name, tool_name, arguments)

      {:ok, {:skill_lazy, skill_name, config, _nil}} ->
        execute_lazy_skill(skill_name, config, tool_name, arguments)

      {:ok, {:internal, _}} ->
        {:error, "Missing required arguments for tool: #{tool_name}"}

      {:error, :not_found} ->
        available = Mimo.ToolRegistry.list_all_tools() |> Enum.map(& &1["name"]) |> Enum.take(10)
        {:error, "Unknown tool: #{tool_name}. Available tools include: #{inspect(available)}"}

      {:error, reason} ->
        {:error, "Tool routing failed: #{inspect(reason)}"}
    end
  end

  defp execute_mimo_core(tool_name, arguments) do
    Logger.debug("Dispatching #{tool_name} to Mimo.Tools")

    case Mimo.Tools.dispatch(tool_name, arguments) do
      {:ok, result} ->
        enriched = try_enrich_result(tool_name, arguments, result)
        {:ok, build_success_response(enriched)}

      {:error, reason} ->
        Mimo.RequestInterceptor.record_error(tool_name, reason)
        {:error, "Core tool execution failed: #{inspect(reason)}"}

      :ok ->
        {:ok, build_success_response(%{message: "Operation completed successfully"})}

      other ->
        Logger.warning("Unexpected return from #{tool_name}: #{inspect(other)}")
        {:ok, build_success_response(other)}
    end
  end

  defp execute_running_skill(skill_name, tool_name, arguments) do
    Logger.debug("Routing #{tool_name} to running skill #{skill_name}")

    case Mimo.Skills.Client.call_tool(skill_name, tool_name, arguments) do
      {:ok, result} -> {:ok, build_success_response(result)}
      {:error, reason} -> {:error, "Skill execution failed: #{inspect(reason)}"}
    end
  end

  defp execute_lazy_skill(skill_name, config, tool_name, arguments) do
    Logger.debug("Lazy-spawning skill #{skill_name} for tool #{tool_name}")

    case Mimo.Skills.Client.call_tool_sync(skill_name, config, tool_name, arguments) do
      {:ok, result} -> {:ok, build_success_response(result)}
      {:error, reason} -> {:error, "Skill execution failed: #{inspect(reason)}"}
    end
  end

  defp build_success_response(data) do
    %{
      tool_call_id: UUID.uuid4(),
      status: "success",
      data: data
    }
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

  # SPEC-060: Support temporal validity options
  # SPEC-SQLite: Memory.persist_memory already handles WriteSerializer internally
  # DO NOT wrap here - causes calling_self deadlock (nested GenServer.call)
  defp execute_memory_store(content, category, importance, opts) do
    # SPEC-034: Route through Memory.persist_memory for TMC integration
    # SPEC-060: Pass temporal validity options
    # Memory.persist_memory handles serialization internally - no wrapper needed
    result = Mimo.Brain.Memory.persist_memory(content, category, importance, opts)

    case result do
      {:ok, {:ok, id}} ->
        base_data = %{stored: true, id: id, embedding_generated: true}
        temporal_data = build_temporal_response(opts)

        {:ok,
         %{tool_call_id: UUID.uuid4(), status: "success", data: Map.merge(base_data, temporal_data)}}

      {:ok, {:duplicate, id}} ->
        {:ok,
         %{
           tool_call_id: UUID.uuid4(),
           status: "success",
           data: %{stored: true, id: id, duplicate: true, embedding_generated: true}
         }}

      {:ok, {:error, reason}} ->
        {:error, "Failed to store memory: #{inspect(reason)}"}

      # Direct result (fallback path)
      {:ok, id} when is_integer(id) ->
        base_data = %{stored: true, id: id, embedding_generated: true}
        temporal_data = build_temporal_response(opts)

        {:ok,
         %{tool_call_id: UUID.uuid4(), status: "success", data: Map.merge(base_data, temporal_data)}}

      {:duplicate, id} ->
        {:ok,
         %{
           tool_call_id: UUID.uuid4(),
           status: "success",
           data: %{stored: true, id: id, duplicate: true, embedding_generated: true}
         }}

      {:error, :write_timeout} ->
        {:error, "Memory store timed out due to high database load. Please retry."}

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

    # SPEC-092: Check for operation redirect FIRST
    # Strong temporal queries like "latest plan" should use list, not search
    case Mimo.Brain.MemoryRouter.recommend_operation(query) do
      {:list, opts, :temporal_redirect} ->
        # Auto-redirect to list operation for accurate chronological results
        list_args = %{
          "sort" => Keyword.get(opts, :sort, :recent) |> to_string(),
          "limit" => Keyword.get(opts, :limit, 5)
        }

        case execute_memory_list(list_args) do
          {:ok, result} ->
            # Add routing metadata to inform caller of the redirect
            {:ok,
             Map.merge(result, %{
               routing: %{
                 type: :temporal_redirect,
                 original_query: query,
                 note:
                   "Query was auto-redirected from search to list due to strong temporal intent (SPEC-092)"
               }
             })}

          error ->
            error
        end

      _ ->
        # Continue with normal search
        execute_memory_search_impl(args)
    end
  end

  defp execute_memory_search_impl(args) do
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
                    # BUG FIX 2026-01-11: If no timestamp, exclude from time-filtered results
                    # Previously returned true which caused all results to pass
                    false

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
        temporal =
          %{
            valid_from: format_datetime(r[:valid_from]),
            valid_until: format_datetime(r[:valid_until]),
            validity_source: r[:validity_source]
          }
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()

        Map.merge(base, temporal)
      end)

    # Build temporal context for response
    temporal_context = build_search_temporal_context(as_of, valid_at)

    # SPEC-095: Coverage metrics to help AI understand search completeness
    total_memories = Memory.count_memories()
    results_count = length(formatted)

    coverage_pct =
      if total_memories > 0, do: Float.round(results_count / total_memories * 100, 2), else: 0.0

    # Smart suggestion based on coverage
    suggestion = build_search_suggestion(query, results_count, total_memories, coverage_pct)

    {:ok,
     %{
       tool_call_id: UUID.uuid4(),
       status: "success",
       data:
         Map.merge(
           %{
             results: formatted,
             total_searched: length(base_results),
             # SPEC-XXX: MemoryRouter integration - query type for observability
             query_type: query_type,
             routing_confidence: Float.round(routing_confidence, 2),
             # SPEC-095: Coverage metrics for AI self-correction
             coverage: %{
               returned: results_count,
               total_in_database: total_memories,
               percentage: coverage_pct
             }
           },
           temporal_context
         ),
       # SPEC-095: Dynamic suggestion based on query/coverage analysis
       suggestion: suggestion
     }}
  end

  # SPEC-095: Build smart suggestion based on query analysis and coverage
  defp build_search_suggestion(query, results_count, total_memories, coverage_pct) do
    query_lower = String.downcase(query || "")

    cond do
      # Aggregation query pattern detected
      String.contains?(query_lower, ["how many", "all ", "count ", "total ", "list all"]) ->
        "⚠️ Aggregation query detected. For accurate counts, use: memory operation=stats"

      # Very low coverage with potential for more results
      coverage_pct < 1.0 and results_count < 20 and total_memories > 100 ->
        "💡 Low coverage (#{coverage_pct}%). For comprehensive results, try: limit=100 or memory operation=stats first"

      # SPEC query pattern - suggest higher limit
      String.contains?(query_lower, "spec") and results_count < 30 ->
        "💡 For SPEC queries, consider: limit=100 to capture all specifications"

      # Default cross-tool suggestion
      true ->
        "💡 For entity relationships, also check `knowledge operation=query`"
    end
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
    cursor = Map.get(args, "cursor")
    category = Map.get(args, "category")
    sort = Map.get(args, "sort", "recent")

    # SPEC-096: Cursor-based pagination for scalability
    # Cursor takes precedence over offset when both are provided
    # Fetch limit + 1 to detect if there are more results
    fetch_limit = limit + 1

    # Build base query with limit
    query =
      if cursor do
        # Cursor-based: decode cursor and use WHERE clause for O(log n) lookup
        cursor_id = decode_cursor(cursor)

        from(e in Engram,
          where: e.id > ^cursor_id,
          limit: ^fetch_limit
        )
      else
        # Legacy offset-based for backward compatibility
        from(e in Engram, limit: ^fetch_limit, offset: ^offset)
      end

    # Apply category filter
    query =
      if category do
        from(e in query, where: e.category == ^category)
      else
        query
      end

    # Apply sort order
    # Note: For cursor pagination to work correctly with non-ID sorts,
    # we need compound cursors. Currently cursor only works with ID sort.
    # BUG FIX 2026-01-11: Was using [asc: e.id] which returned oldest first!
    query =
      case sort do
        "importance" -> from(e in query, order_by: [desc: e.importance, desc: e.id])
        "decay_score" -> from(e in query, order_by: [asc: e.importance, desc: e.id])
        # Default: recent (by ID since ID correlates with insert time - highest ID = most recent)
        _ -> from(e in query, order_by: [desc: e.id])
      end

    results = Repo.all(query)

    # Determine if there are more results
    has_more = length(results) > limit
    memories = Enum.take(results, limit)

    # Generate next cursor from the last returned ID
    next_cursor =
      if has_more and memories != [] do
        encode_cursor(List.last(memories).id)
      else
        nil
      end

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
         # Pagination info (legacy offset included for backward compatibility)
         offset: offset,
         limit: limit,
         # SPEC-096: New cursor-based pagination fields
         next_cursor: next_cursor,
         has_more: has_more
       }
     }}
  end

  # SPEC-096: Cursor encoding/decoding helpers
  # Simple implementation: cursor is just the ID as a string
  # Can be extended to compound cursors (ID + sort field) if needed
  defp decode_cursor(nil), do: 0

  defp decode_cursor(cursor) when is_binary(cursor) do
    case Integer.parse(cursor) do
      {id, ""} -> id
      _ -> 0
    end
  end

  defp decode_cursor(cursor) when is_integer(cursor), do: cursor
  defp decode_cursor(_), do: 0

  defp encode_cursor(id) when is_integer(id), do: Integer.to_string(id)
  defp encode_cursor(_), do: nil

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

    # Get cluster summary if GnnPredictor is trained
    cluster_summary = get_cluster_summary()

    base_data = %{
      total_memories: stats.total || 0,
      by_category: by_category,
      avg_importance: stats.avg_importance && Float.round(stats.avg_importance, 2),
      at_risk_count: at_risk_count || 0,
      oldest: format_datetime(stats.min_inserted),
      newest: format_datetime(stats.max_inserted)
    }

    # Add cluster info if available
    data =
      if cluster_summary do
        Map.put(base_data, :clusters, cluster_summary)
      else
        base_data
      end

    {:ok,
     %{
       tool_call_id: UUID.uuid4(),
       status: "success",
       data: data
     }}
  end

  # Get cluster summary from GnnPredictor if model is trained
  defp get_cluster_summary do
    alias Mimo.NeuroSymbolic.GnnPredictor

    clusters = GnnPredictor.cluster_similar(nil, :memory)

    if clusters == [] do
      nil
    else
      %{
        count: length(clusters),
        largest: Enum.max_by(clusters, & &1.size, fn -> nil end) |> cluster_to_summary(),
        available: true,
        hint: "Use 'neuro_symbolic_inference operation=cluster_memories' for full details"
      }
    end
  rescue
    _ -> nil
  end

  defp cluster_to_summary(nil), do: nil

  defp cluster_to_summary(cluster) do
    %{
      id: cluster.cluster_id,
      size: cluster.size,
      top_category:
        cluster.category_breakdown
        |> Enum.max_by(fn {_k, v} -> v end, fn -> {nil, 0} end)
        |> elem(0)
    }
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
        old_update_result =
          Repo.update(
            Engram.changeset(old_engram, %{
              superseded_at: DateTime.utc_now() |> DateTime.truncate(:second)
            })
          )

        case old_update_result do
          {:ok, updated_old} ->
            # Update new engram to link to old one
            new_update_result =
              Repo.update(
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
      {:ok, dt, _offset} ->
        dt

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
