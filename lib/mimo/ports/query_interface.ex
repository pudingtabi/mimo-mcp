defmodule Mimo.QueryInterface do
  @moduledoc """
  Port: QueryInterface

  Abstract port for natural language queries routed through the Meta-Cognitive Router.
  This port is protocol-agnostic - adapters (HTTP, MCP, CLI) call these functions.

  Part of the Universal Aperture architecture - isolates Mimo Core from protocol concerns.
  """
  require Logger

  alias Mimo.TaskHelper

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
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)

    task =
      TaskHelper.async_with_callers(fn ->
        # Classify the query through Meta-Cognitive Router
        router_decision = Mimo.MetaCognitiveRouter.classify(query)

        # Search memories based on router decision
        memories = search_by_decision(query, router_decision)

        # Get proactive suggestions from Observer (semantic graph insights)
        # Extract entity-like patterns from query for Observer
        entities = extract_entities_from_query(query)
        proactive_suggestions = get_observer_suggestions(entities, [])

        # If LLM services are unavailable, return memory-only results without error
        if not Mimo.Brain.LLM.available?() or
             Application.get_env(:mimo_mcp, :skip_external_apis, false) do
          {:ok,
           %{
             query_id: UUID.uuid4(),
             router_decision: router_decision,
             results: memories,
             synthesis: nil,
             synthesis_error: ":no_api_key",
             proactive_suggestions: proactive_suggestions,
             context_id: context_id
           }}
        else
          # Prefer LLM synthesis when available to enrich answers
          synthesis_result = Mimo.Brain.LLM.consult_chief_of_staff(query, memories.episodic || [])

          case synthesis_result do
            {:ok, response} ->
              # SPEC-065: Check synthesis for contradictions with stored knowledge
              contradiction_check = check_for_contradictions(response)

              # Record the conversation in memory (async, don't block response)
              record_conversation(query, response, context_id)

              {:ok,
               %{
                 query_id: UUID.uuid4(),
                 router_decision: router_decision,
                 results: memories,
                 synthesis: response,
                 # Add contradiction check results
                 contradiction_check: contradiction_check,
                 proactive_suggestions: proactive_suggestions,
                 context_id: context_id
               }}

            {:error, :no_api_key} ->
              Logger.warning("LLM unavailable (no API key); returning memories only")

              {:ok,
               %{
                 query_id: UUID.uuid4(),
                 router_decision: router_decision,
                 results: memories,
                 synthesis: nil,
                 synthesis_error: ":no_api_key",
                 proactive_suggestions: proactive_suggestions,
                 context_id: context_id
               }}

            {:error, reason} ->
              Logger.warning("LLM synthesis failed: #{inspect(reason)}, returning memories only")
              # Return memories without synthesis if LLM fails (circuit breaker, timeout, etc.)
              {:ok,
               %{
                 query_id: UUID.uuid4(),
                 router_decision: router_decision,
                 results: memories,
                 synthesis: nil,
                 synthesis_error: inspect(reason),
                 proactive_suggestions: proactive_suggestions,
                 context_id: context_id
               }}
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

  defp search_by_decision(query, decision) do
    # ALWAYS search episodic memory - it contains the richest context
    # The router decision only affects HOW MUCH we search, not WHETHER we search
    episodic = search_episodic_always(query, decision)
    semantic = search_semantic(query, decision)
    procedural = search_procedural(query, decision)

    %{
      episodic: episodic,
      semantic: semantic,
      procedural: procedural
    }
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
