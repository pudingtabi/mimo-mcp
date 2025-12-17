defmodule Mimo.QueryInterface do
  @moduledoc """
  Port: QueryInterface

  Abstract port for natural language queries routed through the Meta-Cognitive Router.
  This port is protocol-agnostic - adapters (HTTP, MCP, CLI) call these functions.

  Part of the Universal Aperture architecture - isolates Mimo Core from protocol concerns.
  """
  require Logger

  alias Mimo.TaskHelper
  alias Mimo.Cognitive.KnowledgeTransfer

  @doc """
  Process a natural language query through the Meta-Cognitive Router.
  Routes to appropriate stores (Episodic, Semantic, Procedural) based on query classification.

  ## Parameters
    - query: The natural language query string
    - context_id: Optional session/context identifier for continuity
    - opts: Additional options (timeout_ms, etc.)

  ## Returns
    - {:ok, result} with router_decision and results from memory stores
    - {:error, reason} on failure
  """
  @spec ask(String.t(), String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def ask(query, context_id \\ nil, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, Mimo.TimeoutConfig.query_timeout())

    task =
      TaskHelper.async_with_callers(fn ->
        # Classify the query through Meta-Cognitive Router
        router_decision = Mimo.MetaCognitiveRouter.classify(query)

        # SPEC-071: Start Active Inference in parallel (proactive context pushing)
        active_inference_task =
          Task.async(fn ->
            Mimo.ActiveInference.infer(query, context: %{context_id: context_id})
          end)

        # Search memories based on router decision
        memories = search_by_decision(query, router_decision)

        # Get proactive suggestions from Observer (semantic graph insights)
        # Extract entity-like patterns from query for Observer
        entities = extract_entities_from_query(query)
        proactive_suggestions = get_observer_suggestions(entities, [])

        # Await Active Inference results (ran in parallel with memory search)
        active_inference =
          try do
            case Task.await(active_inference_task, 600) do
              {:ok, inference} -> inference
              _ -> nil
            end
          rescue
            _ -> nil
          catch
            :exit, _ -> nil
          end

        # STRICT FAIL-CLOSED: If LLM services are unavailable, return explicit error
        # We don't want sudden quality drops - quality or nothing
        if not Mimo.Brain.LLM.available?() or
             Application.get_env(:mimo_mcp, :skip_external_apis, false) do
          Logger.error("LLM services not available - failing closed (no degradation)")
          {:error, :llm_unavailable}
        else
          # Call LLM synthesis - fail if it fails
          llm_timeout = Mimo.TimeoutConfig.llm_synthesis_timeout()

          # Start cross-domain insights in parallel with LLM call (optimization)
          insights_task = Task.async(fn -> get_cross_domain_insights(query, "") end)

          synthesis_result = safe_llm_synthesis(query, memories.episodic || [], llm_timeout)

          case synthesis_result do
            {:ok, response} ->
              # SPEC-065: Check synthesis for contradictions with stored knowledge
              contradiction_check = check_for_contradictions(response)

              # Await cross-domain insights (ran in parallel with LLM)
              cross_domain_insights =
                try do
                  Task.await(insights_task, 5000)
                rescue
                  e ->
                    Logger.warning(
                      "[QueryInterface] Cross-domain insights failed: #{Exception.message(e)}"
                    )

                    nil
                catch
                  :exit, reason ->
                    Logger.warning(
                      "[QueryInterface] Cross-domain insights task exited: #{inspect(reason)}"
                    )

                    nil
                end

              # Record the conversation in memory (async, don't block response)
              record_conversation(query, response, context_id)

              {:ok,
               %{
                 query_id: UUID.uuid4(),
                 router_decision: router_decision,
                 results: memories,
                 synthesis: response,
                 # FULL QUALITY - the only acceptable outcome
                 quality_status: :full,
                 # Add contradiction check results
                 contradiction_check: contradiction_check,
                 proactive_suggestions: proactive_suggestions,
                 # Phase 3: Cross-domain knowledge transfer
                 cross_domain_insights: cross_domain_insights,
                 # SPEC-071: Active Inference - proactive context pushing
                 active_inference: active_inference,
                 context_id: context_id
               }}

            {:error, :synthesis_timeout} ->
              Task.shutdown(insights_task, :brutal_kill)
              Logger.error("LLM synthesis timed out after #{llm_timeout}ms - failing closed")
              {:error, {:llm_timeout, llm_timeout}}

            {:error, :no_api_key} ->
              Task.shutdown(insights_task, :brutal_kill)
              Logger.error("LLM unavailable (no API key) - failing closed")
              {:error, :llm_no_api_key}

            {:error, :circuit_breaker_open} ->
              Task.shutdown(insights_task, :brutal_kill)
              Logger.error("LLM circuit breaker open - failing closed")
              {:error, :llm_circuit_breaker_open}

            {:error, :all_providers_unavailable} ->
              Task.shutdown(insights_task, :brutal_kill)
              Logger.error("All LLM providers unavailable - failing closed")
              {:error, :llm_all_providers_unavailable}

            {:error, reason} ->
              Task.shutdown(insights_task, :brutal_kill)
              Logger.error("LLM synthesis failed: #{inspect(reason)} - failing closed")
              {:error, {:llm_synthesis_failed, reason}}
          end
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task) do
      {:ok, {:ok, result}} -> {:ok, result}
      {:ok, {:error, reason}} -> {:error, reason}
      nil -> {:error, :timeout}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Wrap LLM synthesis with its own timeout for graceful degradation
  # Returns {:ok, response}, {:error, :synthesis_timeout}, or {:error, reason}
  defp safe_llm_synthesis(query, memories, timeout_ms) do
    task =
      TaskHelper.async_with_callers(fn ->
        Mimo.Brain.LLM.consult_chief_of_staff(query, memories)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task) do
      {:ok, {:ok, response}} ->
        {:ok, response}

      {:ok, {:error, reason}} ->
        {:error, reason}

      nil ->
        # Task timed out - this is the key graceful degradation path
        {:error, :synthesis_timeout}
    end
  rescue
    e -> {:error, {:synthesis_exception, Exception.message(e)}}
  end

  defp search_by_decision(query, decision) do
    # SPEC-070: Differentiated retrieval strategies based on router classification
    # Different query types benefit from different search methods, not just different limits

    case decision.primary_store do
      :semantic ->
        # SEMANTIC queries: Graph traversal is primary, vector is secondary
        # These are relationship/architecture queries - graph structure matters most
        semantic = search_semantic_primary(query, decision)
        episodic = search_episodic_secondary(query, decision)
        procedural = nil

        %{episodic: episodic, semantic: semantic, procedural: procedural}

      :episodic ->
        # EPISODIC queries: Vector "vibe" search is primary
        # These are narrative/experience queries - semantic similarity matters most
        episodic = search_episodic_primary(query, decision)
        semantic = search_semantic_secondary(query, decision)
        procedural = nil

        %{episodic: episodic, semantic: semantic, procedural: procedural}

      :procedural ->
        # PROCEDURAL queries: Hybrid - procedures + graph for dependencies
        # These are code/fix queries - procedures AND their dependencies matter
        procedural = search_procedural_primary(query, decision)
        semantic = search_semantic_for_dependencies(query, decision)
        episodic = search_episodic_for_context(query, decision)

        %{episodic: episodic, semantic: semantic, procedural: procedural}

      _ ->
        # Fallback: balanced search across all stores
        episodic = search_episodic_always(query, decision)
        semantic = search_semantic(query, decision)
        procedural = search_procedural(query, decision)

        %{episodic: episodic, semantic: semantic, procedural: procedural}
    end
  end

  # =============================================================================
  # SPEC-070: Differentiated Retrieval Strategies
  # =============================================================================

  # SEMANTIC PRIMARY: Full graph traversal for relationship queries
  defp search_semantic_primary(query, _decision) do
    alias Mimo.SemanticStore.Query

    try do
      # Extract entities from query for targeted graph search
      entities = extract_entities_from_query(query)

      # Try to find relationships in the knowledge graph
      results =
        if Enum.empty?(entities) do
          # General pattern matching
          Query.pattern_match([{:any, :any, :any}])
          |> Enum.take(15)
        else
          # Targeted traversal from extracted entities - try each node type
          Enum.flat_map(entities, fn entity ->
            # Try to find node by searching across types
            case Mimo.Synapse.Graph.search_nodes(entity, limit: 1) do
              [node | _] ->
                # Get both outgoing and incoming edges
                outgoing =
                  Mimo.Synapse.Graph.outgoing_edges(node.id, preload: false) |> Enum.take(5)

                incoming =
                  Mimo.Synapse.Graph.incoming_edges(node.id, preload: false) |> Enum.take(5)

                outgoing ++ incoming

              [] ->
                []
            end
          end)
          |> Enum.uniq_by(fn e -> {e.source_node_id, e.target_node_id, e.edge_type} end)
          |> Enum.take(20)
        end

      if results == [] do
        nil
      else
        %{source: "semantic_graph", results: results, strategy: :graph_traversal}
      end
    rescue
      e ->
        Logger.warning("[QueryInterface] Semantic primary search failed: #{Exception.message(e)}")
        nil
    end
  end

  # SEMANTIC SECONDARY: Light graph lookup for non-semantic queries
  defp search_semantic_secondary(query, _decision) do
    entities = extract_entities_from_query(query)

    if Enum.empty?(entities) do
      nil
    else
      try do
        # Just check if entities exist in graph, don't traverse
        found =
          Enum.flat_map(entities, fn entity ->
            Mimo.Synapse.Graph.search_nodes(entity, limit: 1)
          end)
          |> Enum.map(& &1.name)

        if Enum.empty?(found),
          do: nil,
          else: %{source: "semantic_graph", entities: found, strategy: :entity_lookup}
      rescue
        _ -> nil
      end
    end
  end

  # SEMANTIC FOR DEPENDENCIES: Find code dependencies for procedural queries
  defp search_semantic_for_dependencies(query, _decision) do
    # Extract potential module/function names from procedural query
    code_entities = extract_code_entities(query)

    if Enum.empty?(code_entities) do
      nil
    else
      try do
        # Look for dependency relationships
        deps =
          Enum.flat_map(code_entities, fn entity ->
            case Mimo.Synapse.Graph.search_nodes(entity, types: [:module, :function], limit: 1) do
              [node | _] ->
                # Get uses/imports edges (dependency-like)
                Mimo.Synapse.Graph.outgoing_edges(node.id,
                  types: [:uses, :imports, :calls],
                  preload: false
                )
                |> Enum.take(5)

              [] ->
                []
            end
          end)
          |> Enum.take(10)

        if Enum.empty?(deps),
          do: nil,
          else: %{source: "semantic_graph", dependencies: deps, strategy: :dependency_lookup}
      rescue
        _ -> nil
      end
    end
  end

  # EPISODIC PRIMARY: Full vector search with recency boost for narrative queries
  defp search_episodic_primary(query, _decision) do
    case Mimo.Brain.MemoryRouter.route(query, limit: 20, recency_boost: 0.4) do
      {:ok, results} ->
        results
        |> Enum.map(fn
          {memory, score} -> Map.put(sanitize_memory_for_json(memory), :relevance_score, score)
          memory -> sanitize_memory_for_json(memory)
        end)
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  # EPISODIC SECONDARY: Limited vector search for non-episodic queries
  defp search_episodic_secondary(query, _decision) do
    case Mimo.Brain.MemoryRouter.route(query, limit: 8) do
      {:ok, results} ->
        results
        |> Enum.map(fn
          {memory, _score} -> sanitize_memory_for_json(memory)
          memory -> sanitize_memory_for_json(memory)
        end)
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  # EPISODIC FOR CONTEXT: Minimal context retrieval for procedural queries
  defp search_episodic_for_context(query, _decision) do
    # For procedural queries, we want recent relevant context, not deep history
    case Mimo.Brain.MemoryRouter.route(query, limit: 5, recency_boost: 0.6) do
      {:ok, results} ->
        results
        |> Enum.map(fn
          {memory, _score} -> sanitize_memory_for_json(memory)
          memory -> sanitize_memory_for_json(memory)
        end)
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  # PROCEDURAL PRIMARY: Full procedure search with pattern matching
  defp search_procedural_primary(query, _decision) do
    if Mimo.Application.feature_enabled?(:procedural_store) do
      try do
        procedures = Mimo.ProceduralStore.Loader.list(active_only: true)

        # Score procedures by relevance
        scored =
          procedures
          |> Enum.map(fn p ->
            name_score =
              if String.contains?(String.downcase(p.name || ""), String.downcase(query)),
                do: 2.0,
                else: 0.0

            desc_score =
              if String.contains?(String.downcase(p.description || ""), String.downcase(query)),
                do: 1.0,
                else: 0.0

            {p, name_score + desc_score}
          end)
          |> Enum.filter(fn {_p, score} -> score > 0 end)
          |> Enum.sort_by(fn {_p, score} -> -score end)
          |> Enum.take(10)
          |> Enum.map(fn {p, _score} -> p end)

        if Enum.empty?(scored),
          do: nil,
          else: %{source: "procedural_store", procedures: scored, strategy: :pattern_match}
      rescue
        _ -> nil
      end
    else
      nil
    end
  end

  # Extract code-like entities (module names, function names) from query
  defp extract_code_entities(query) do
    # Match PascalCase (modules), snake_case (functions), or dotted names
    patterns = [
      # PascalCase
      ~r/\b([A-Z][a-z]+(?:[A-Z][a-z]+)+)\b/,
      # snake_case
      ~r/\b([a-z][a-z0-9]*(?:_[a-z0-9]+)+)\b/,
      # Dotted.Module.Name
      ~r/\b([A-Z][a-z]+(?:\.[A-Z][a-z]+)+)\b/
    ]

    Enum.flat_map(patterns, fn pattern ->
      Regex.scan(pattern, query)
      |> Enum.map(fn [_, match] -> match end)
    end)
    |> Enum.uniq()
    |> Enum.take(5)
  end

  # Always search episodic memory, but adjust limit based on router decision
  defp search_episodic_always(query, decision) do
    limit =
      case decision do
        # Primary: more results
        %{primary_store: :episodic} ->
          15

        %{secondary_stores: stores} when is_list(stores) ->
          # Secondary or tertiary: still search
          if :episodic in stores, do: 10, else: 8

        # Always search at least some memories
        _ ->
          8
      end

    # Use MemoryRouter for robust retrieval with fallbacks
    # (Previously used Memory.search_memories which fails silently on embedding errors)
    case Mimo.Brain.MemoryRouter.route(query, limit: limit) do
      {:ok, results} ->
        # MemoryRouter returns {memory, score} tuples - extract just the memories
        # Also sanitize for JSON encoding (remove binary embedding field)
        memories =
          Enum.map(results, fn
            {memory, _score} when is_map(memory) -> sanitize_memory_for_json(memory)
            memory when is_map(memory) -> sanitize_memory_for_json(memory)
            _ -> nil
          end)
          |> Enum.reject(&is_nil/1)

        # Log if we found memories that would have been missed by old logic
        if not Enum.empty?(memories) and decision.primary_store != :episodic do
          Logger.debug("Found #{length(memories)} episodic memories for non-episodic query")
        end

        memories

      {:error, reason} ->
        Logger.warning("MemoryRouter failed: #{inspect(reason)}, trying direct search")
        # Fallback to direct search - also sanitize the results
        case Mimo.Brain.Memory.search_memories(query, limit: limit, recency_boost: 0.3) do
          results when is_list(results) ->
            Enum.map(results, &sanitize_memory_for_json/1)

          _ ->
            []
        end
    end
  end

  # Sanitize memory for JSON encoding - remove binary fields and convert structs
  defp sanitize_memory_for_json(memory) when is_map(memory) do
    memory
    |> convert_to_map()
    |> Map.drop([:embedding, :embedding_int8, :embedding_binary, :__struct__, :__meta__])
    |> Map.update(:embedding, [], fn
      nil -> []
      # Binary embeddings can't be JSON encoded
      bin when is_binary(bin) -> []
      # Even float lists are huge, skip
      list when is_list(list) -> []
      _ -> []
    end)
  end

  defp sanitize_memory_for_json(other), do: other

  defp convert_to_map(%{__struct__: _} = struct), do: Map.from_struct(struct)
  defp convert_to_map(map) when is_map(map), do: map

  defp search_semantic(query, %{primary_store: :semantic} = _decision) do
    alias Mimo.SemanticStore.Query

    # Try pattern matching for structured queries
    try do
      # Extract potential entity patterns from query
      triples = Query.pattern_match([{:any, "relates_to", :any}])

      if triples == [] do
        # Fallback to episodic search if no semantic results
        search_episodic_fallback(query)
      else
        # Return just the triples list (JSON-serializable)
        %{source: "semantic", triples: triples}
      end
    rescue
      e ->
        Logger.warning("Semantic search failed: #{Exception.message(e)}, falling back to episodic")
        search_episodic_fallback(query)
    end
  end

  defp search_semantic(_query, _decision), do: nil

  defp search_episodic_fallback(query) do
    results = Mimo.Brain.Memory.search_memories(query, limit: 5)
    # Return just the memories list, not a tuple (to be JSON-serializable)
    results
  end

  defp search_procedural(query, %{primary_store: :procedural} = _decision) do
    # Check if procedural store is enabled
    if Mimo.Application.feature_enabled?(:procedural_store) do
      # Search procedures by name pattern matching
      # TODO: v3.0 Roadmap - Add full-text search and semantic matching for procedures
      try do
        # List all active procedures and filter by query match
        procedures = Mimo.ProceduralStore.Loader.list(active_only: true)

        matching =
          procedures
          |> Enum.filter(fn p ->
            String.contains?(String.downcase(p.name || ""), String.downcase(query)) ||
              String.contains?(String.downcase(p.description || ""), String.downcase(query))
          end)
          |> Enum.take(10)

        if Enum.empty?(matching), do: nil, else: matching
      rescue
        _ -> nil
      end
    else
      # Return nil for consistency - procedural store not enabled
      nil
    end
  end

  defp search_procedural(_query, _decision), do: nil

  # Record ask_mimo conversations in memory for future context
  defp record_conversation(query, response, context_id) do
    # Run async to not block the response
    Mimo.Sandbox.run_async(Mimo.Repo, fn ->
      try do
        # Truncate long responses to avoid bloating memory
        truncated_response =
          if String.length(response) > 500 do
            String.slice(response, 0, 497) <> "..."
          else
            response
          end

        # Format as a conversation turn
        content = """
        [AI asked Mimo]: #{query}
        [Mimo responded]: #{truncated_response}
        """

        # Determine importance based on query characteristics
        importance = calculate_conversation_importance(query)

        # Route through SafeMemory for resilient consolidation pipeline
        case Mimo.Brain.SafeMemory.store(
               String.trim(content),
               category: "observation",
               importance: importance,
               source: "ask_mimo"
             ) do
          {:ok, id} ->
            # Mark for consolidation since conversations are valuable
            Mimo.Brain.SafeMemory.mark_for_consolidation(id)

          {:error, reason} ->
            Logger.warning("Failed to store conversation: #{inspect(reason)}")
        end

        Logger.info("Recorded ask_mimo conversation in memory (context: #{context_id || "none"})")
      rescue
        e ->
          Logger.warning("Failed to record conversation: #{Exception.message(e)}")

          :telemetry.execute([:mimo, :query_interface, :record_error], %{count: 1}, %{
            error: Exception.message(e)
          })
      end
    end)
  end

  # Calculate importance based on query characteristics
  defp calculate_conversation_importance(query) do
    base = 0.5

    # Boost for longer, more detailed queries
    length_boost = if String.length(query) > 100, do: 0.1, else: 0.0

    # Boost for questions about architecture, design, or important topics
    topic_boost =
      cond do
        String.contains?(query, ["architecture", "design", "implement", "how to"]) -> 0.15
        String.contains?(query, ["bug", "error", "fix", "problem"]) -> 0.1
        String.contains?(query, ["remember", "recall", "what did"]) -> 0.1
        true -> 0.0
      end

    min(base + length_boost + topic_boost, 0.85)
  end

  # SPEC-065: Check synthesis for contradictions with stored knowledge
  # Integrated with ContradictionGuard for fail-closed validation
  defp check_for_contradictions(response) when is_binary(response) do
    try do
      case Mimo.Brain.ContradictionGuard.check(response, max_claims: 3) do
        {:ok, []} ->
          %{status: :passed, warnings: []}

        {:ok, warnings} when is_list(warnings) ->
          Logger.info(
            "[QueryInterface] ContradictionGuard found #{length(warnings)} potential conflicts"
          )

          %{status: :warnings, warnings: warnings}

        {:error, reason} ->
          # Fail-closed: report that check couldn't be performed
          Logger.warning("[QueryInterface] ContradictionGuard check failed: #{inspect(reason)}")
          %{status: :check_failed, reason: inspect(reason), warnings: []}
      end
    catch
      :exit, _ ->
        # ContradictionGuard not available (startup, test mode)
        %{status: :unavailable, warnings: []}
    end
  end

  defp check_for_contradictions(_), do: %{status: :skipped, warnings: []}

  # Phase 3: Cross-domain knowledge transfer
  # Find relevant patterns from other programming domains that might apply
  defp get_cross_domain_insights(query, response) do
    # Combine query and response for domain detection
    context = "#{query}\n#{response}"

    case KnowledgeTransfer.find_transfers(context, limit: 2) do
      {:ok, []} ->
        nil

      {:ok, transfers} ->
        # Format transfers for the response
        insights =
          Enum.map(transfers, fn t ->
            %{
              from_domain: t.source_domain,
              to_domain: t.target_domain,
              concept: t.concept,
              insight: "In #{t.source_domain}: #{t.source_pattern}",
              suggestion: "In #{t.target_domain}: #{t.target_pattern}",
              confidence: t.confidence
            }
          end)

        %{
          detected_domain: KnowledgeTransfer.detect_domain(context),
          detected_concepts: KnowledgeTransfer.detect_concepts(context),
          transfers: insights
        }
    end
  rescue
    _ -> nil
  end

  # Extract entity-like patterns from query for Observer
  defp extract_entities_from_query(query) do
    # Extract potential entity patterns:
    # - CamelCase words (likely module/class names)
    # - snake_case words (likely function names)
    # - word:word patterns (explicit entity references)

    camel_case =
      Regex.scan(~r/\b([A-Z][a-z]+(?:[A-Z][a-z]+)+)\b/, query)
      |> Enum.map(fn [_, match] -> String.downcase(match) end)

    snake_case =
      Regex.scan(~r/\b([a-z]+_[a-z_]+)\b/, query)
      |> Enum.map(fn [_, match] -> match end)

    explicit =
      Regex.scan(~r/\b([a-z]+:[a-z_]+)\b/i, query)
      |> Enum.map(fn [_, match] -> String.downcase(match) end)

    (camel_case ++ snake_case ++ explicit)
    |> Enum.uniq()
    # Limit to 5 entities for performance
    |> Enum.take(5)
  end

  # Get proactive suggestions from SemanticStore Observer
  defp get_observer_suggestions(entities, conversation_history) do
    if Enum.empty?(entities) do
      []
    else
      try do
        case Mimo.SemanticStore.Observer.observe(entities, conversation_history) do
          {:ok, suggestions} ->
            # Format suggestions for JSON serialization
            Enum.map(suggestions, fn s ->
              %{
                type: s.type,
                entity: s.entity,
                predicate: s.predicate,
                related: s[:target] || s[:source],
                confidence: s.confidence,
                text: s.text
              }
            end)

          _ ->
            []
        end
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end
    end
  end
end
