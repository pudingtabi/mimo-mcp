defmodule Mimo.Brain.MemoryRouter do
  @moduledoc """
  Intelligent memory routing based on query analysis.

  Routes queries to optimal memory stores based on:
  - Query type detection (factual, relational, temporal, procedural)
  - Query complexity analysis
  - Available store capabilities
  - LLM-enhanced understanding (ROADMAP Phase 1b P1)

  ## Query Types

    * `:factual` - Direct fact lookup → Vector search
    * `:relational` - Entity relationships → Graph search
    * `:temporal` - Time-based queries → Recency search
    * `:procedural` - How-to/process → Procedural store
    * `:hybrid` - Complex multi-aspect → All stores

  ## LLM Enhancement

  When enabled, uses LLM for natural language understanding:
  - Extracts time references ("yesterday" → ~D[...])
  - Identifies query intent beyond keywords
  - Expands query terms for better recall
  - Falls back to keyword-based analysis on failure

  ## Examples

      # Auto-route a query
      {:ok, results} = MemoryRouter.route("How is auth related to users?")

      # Analyze query type
      {:relational, 0.85} = MemoryRouter.analyze("What are the relationships?")

      # Force specific routing
      {:ok, results} = MemoryRouter.route(query, strategy: :graph)
  """
  require Logger

  alias Mimo.Brain.LLM
  alias Mimo.Brain.{HybridRetriever, SafeMemory}
  alias Mimo.Cache.SearchResult
  alias Mimo.ProceduralStore

  # Query type indicators
  # Note: "how" is only procedural when followed by "to" or "do" (how-to patterns)
  @relational_indicators ~w(related relationship connected link between association)
  @temporal_indicators ~w(recent recently latest today yesterday last first newest oldest ago)
  @procedural_indicators ~w(steps process procedure guide tutorial workflow setup configure)
  @procedural_how_patterns ["how to", "how do", "how can", "how should"]
  # Note: Single words like "what" or "is" are too common; factual needs "what is" pattern
  @factual_indicators ~w(define meaning explain describe definition)
  @factual_patterns ["what is", "what are", "what does", "what's the", "what are the"]

  # SPEC-092: Strong temporal indicators that should redirect to list operation
  @strong_temporal_indicators ~w(latest newest)
  @strong_temporal_patterns ["most recent", "last created", "just added"]

  # ROADMAP Phase 1b P1: LLM-enhanced query understanding config
  # Enable LLM for complex queries that benefit from natural language understanding
  @llm_analysis_enabled Application.compile_env(:mimo, :llm_query_analysis, true)
  # Minimum query length to trigger LLM analysis (short queries use keyword-based)
  @llm_min_query_length 10

  # ============================================================================
  # ROADMAP Phase 1b P1: LLM-Enhanced Query Understanding
  # ============================================================================

  @doc """
  Use LLM to understand query intent, time references, and topics.

  Returns structured analysis for more accurate routing and retrieval.

  ## Parameters

    * `query` - Natural language query

  ## Returns

    * `{:ok, analysis}` - Structured analysis map
    * `{:error, reason}` - LLM failure (fallback to keyword-based)

  ## Analysis Structure

      %{
        "intent" => "temporal" | "semantic" | "relational" | "procedural" | "aggregation",
        "time_reference" => nil | "yesterday" | "last_week" | ...,
        "topics" => ["keyword1", "keyword2"],
        "expanded_queries" => ["variation1", "variation2"],
        "confidence" => 0.0..1.0
      }
  """
  @spec understand_query_with_llm(String.t()) :: {:ok, map()} | {:error, term()}
  def understand_query_with_llm(query) do
    prompt = """
    Analyze this memory search query and extract structured information.

    Query: "#{query}"

    Respond with ONLY valid JSON (no markdown, no explanation):
    {
      "intent": "semantic|temporal|relational|procedural|aggregation",
      "time_reference": null or one of: "today", "yesterday", "last_week", "last_month", "recent",
      "topics": ["keyword1", "keyword2"],
      "expanded_queries": ["variation1", "variation2"],
      "confidence": 0.0 to 1.0
    }

    Intent definitions:
    - semantic: General knowledge/fact lookup
    - temporal: Time-based queries (recent, yesterday, latest)
    - relational: Queries about connections between entities
    - procedural: How-to, steps, process questions
    - aggregation: Summarize, count, or aggregate multiple memories

    Important:
    - Extract time references from natural language (e.g., "yesterday" → "yesterday")
    - Topics are key concepts to search for
    - Expanded queries are semantic variations that might match relevant memories
    """

    case LLM.complete(prompt, format: :json, raw: true, max_tokens: 200, skip_retry: true) do
      {:ok, json_str} ->
        case Jason.decode(json_str) do
          {:ok, analysis} when is_map(analysis) ->
            # Validate and normalize the response
            normalized = normalize_llm_analysis(analysis)
            Logger.debug("[MemoryRouter] LLM analysis: #{inspect(normalized)}")
            {:ok, normalized}

          {:error, _} ->
            Logger.warning("[MemoryRouter] LLM returned invalid JSON: #{json_str}")
            {:error, :invalid_json}
        end

      {:error, reason} ->
        Logger.debug("[MemoryRouter] LLM analysis failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp normalize_llm_analysis(analysis) do
    # Map LLM intents to our internal types
    intent =
      case Map.get(analysis, "intent", "semantic") do
        "temporal" -> :temporal
        "relational" -> :relational
        "procedural" -> :procedural
        "aggregation" -> :aggregation
        _ -> :factual
      end

    %{
      intent: intent,
      time_reference: Map.get(analysis, "time_reference"),
      topics: Map.get(analysis, "topics", []),
      expanded_queries: Map.get(analysis, "expanded_queries", []),
      confidence: Map.get(analysis, "confidence", 0.5) |> to_float()
    }
  end

  defp to_float(val) when is_float(val), do: val
  defp to_float(val) when is_integer(val), do: val / 1.0
  defp to_float(_), do: 0.5

  @doc """
  Analyze query with LLM enhancement when beneficial, fallback to keywords.

  Uses LLM for complex queries where natural language understanding helps.
  Falls back to fast keyword-based analysis for:
  - Short queries (< 10 chars)
  - When LLM is disabled
  - When LLM fails

  ## Parameters

    * `query` - Natural language query
    * `opts` - Options:
      - `:force_llm` - Always use LLM even for short queries
      - `:skip_llm` - Never use LLM, use keyword-based only

  ## Returns

    `{type, confidence}` tuple compatible with existing analyze/1
  """
  @spec analyze_with_llm(String.t(), keyword()) :: {atom(), float()}
  def analyze_with_llm(query, opts \\ []) do
    force_llm = Keyword.get(opts, :force_llm, false)
    skip_llm = Keyword.get(opts, :skip_llm, false)

    use_llm =
      @llm_analysis_enabled and
        not skip_llm and
        (force_llm or String.length(query) >= @llm_min_query_length)

    if use_llm do
      case understand_query_with_llm(query) do
        {:ok, %{intent: intent, confidence: confidence}} ->
          {intent, confidence}

        {:error, _} ->
          # Fallback to keyword-based
          analyze(query)
      end
    else
      analyze(query)
    end
  end

  @doc """
  SPEC-092: Recommend the appropriate operation based on query intent.

  For queries with strong temporal signals (e.g., "latest plan", "newest memory"),
  recommends redirecting from search to list operation for accurate chronological results.

  ## Returns

    - `{:list, opts, :temporal_redirect}` - Query should use list, not search
    - `{:search, opts, :temporal}` - Use search with recency boost
    - `{:search, opts, :semantic}` - Normal semantic search

  ## Examples

      iex> MemoryRouter.recommend_operation("what is my latest plan?")
      {:list, [sort: :recent, limit: 5], :temporal_redirect}

      iex> MemoryRouter.recommend_operation("recent changes to auth")
      {:search, [strategy: :recency_heavy], :temporal}

      iex> MemoryRouter.recommend_operation("how does auth work?")
      {:search, [strategy: :auto], :semantic}
  """
  @spec recommend_operation(String.t()) :: {atom(), keyword(), atom()}
  def recommend_operation(query) do
    query_lower = String.downcase(query)

    cond do
      has_strong_temporal?(query_lower) ->
        {:list, [sort: :recent, limit: 5], :temporal_redirect}

      has_temporal?(query_lower) ->
        {:search, [strategy: :recency_heavy], :temporal}

      true ->
        {:search, [strategy: :auto], :semantic}
    end
  end

  defp has_strong_temporal?(query) do
    # Check for strong temporal words
    has_word = Enum.any?(@strong_temporal_indicators, &String.contains?(query, &1))
    # Check for strong temporal patterns
    has_pattern = Enum.any?(@strong_temporal_patterns, &String.contains?(query, &1))
    has_word or has_pattern
  end

  defp has_temporal?(query) do
    words = query |> String.replace(~r/[^\w\s]/, "") |> String.split()
    Enum.any?(words, &(&1 in @temporal_indicators))
  end

  @doc """
  Route a query to appropriate memory stores and return results.

  ## Parameters

    * `query` - Natural language query
    * `opts` - Routing options

  ## Options

    * `:strategy` - Force specific strategy (:auto, :vector, :graph, :recency, :hybrid)
    * `:limit` - Max results (default: 10)
    * `:include_working` - Include working memory (default: true)
    * `:filters` - Field filters

  ## Returns

    * `{:ok, results}` - List of matching memories with scores
    * `{:error, reason}` - On failure
  """
  @spec route(String.t(), keyword()) :: {:ok, list()} | {:error, term()}
  def route(query, opts \\ []) do
    # SPEC-073: Check search cache first for fast repeated queries
    skip_cache = Keyword.get(opts, :skip_cache, false)

    if skip_cache do
      do_route(query, opts)
    else
      case SearchResult.get(query, opts) do
        {:ok, cached_results} ->
          Logger.debug("[MemoryRouter] Cache hit for query")
          {:ok, cached_results}

        :miss ->
          do_route(query, opts)
      end
    end
  end

  # Internal routing implementation
  # ROADMAP Phase 1b P1: Now uses LLM-enhanced analysis when available
  # ROADMAP Phase 1b P3: Multi-query expansion for better recall
  defp do_route(query, opts) do
    strategy = Keyword.get(opts, :strategy, :auto)
    limit = Keyword.get(opts, :limit, 10)
    include_working = Keyword.get(opts, :include_working, true)
    use_llm = Keyword.get(opts, :use_llm, @llm_analysis_enabled)
    use_expansion = Keyword.get(opts, :use_expansion, true)

    # Determine routing strategy
    # ROADMAP Phase 1b P1: Use LLM analysis for better intent detection
    # ROADMAP Phase 1b P3: Also get expanded_queries for multi-query search
    {query_type, confidence, expanded_queries} =
      cond do
        strategy != :auto ->
          {strategy, 1.0, []}

        use_llm ->
          case understand_query_with_llm(query) do
            {:ok, %{intent: intent, confidence: conf, expanded_queries: expansions}} ->
              {intent, conf, expansions || []}

            {:error, _} ->
              {type, conf} = analyze(query)
              {type, conf, []}
          end

        true ->
          {type, conf} = analyze(query)
          {type, conf, []}
      end

    :telemetry.execute(
      [:mimo, :memory, :routing],
      %{confidence: confidence, expansion_count: length(expanded_queries)},
      %{query_type: query_type, strategy: strategy}
    )

    Logger.debug(
      "Routing query as #{query_type} (confidence: #{Float.round(confidence, 2)}, expansions: #{length(expanded_queries)})"
    )

    # Execute appropriate retrieval strategy for PRIMARY query
    # ROADMAP Phase 1b P1: Added :aggregation for summarization queries
    primary_results =
      case query_type do
        :relational -> graph_route(query, opts)
        :temporal -> temporal_route(query, opts)
        :procedural -> procedural_route(query, opts)
        :factual -> vector_route(query, opts)
        :aggregation -> aggregation_route(query, opts)
        :hybrid -> hybrid_route(query, opts)
        _ -> hybrid_route(query, opts)
      end

    # ROADMAP Phase 1b P3: Multi-query expansion
    # Run additional searches for expanded queries and merge results
    results =
      if use_expansion and length(expanded_queries) > 0 do
        expand_and_merge(primary_results, expanded_queries, query_type, opts)
      else
        primary_results
      end

    # Optionally include working memory
    results =
      if include_working do
        working = search_working_memory(query, limit)
        merge_results(results, working)
      else
        results
      end

    # Apply limit and return
    final_results = Enum.take(results, limit)

    # SPEC-073: Cache results for fast repeated queries
    SearchResult.put(query, opts, final_results)

    {:ok, final_results}
  rescue
    e in DBConnection.OwnershipError ->
      Logger.debug("[MemoryRouter] Routing skipped (sandbox mode): #{Exception.message(e)}")
      {:error, :sandbox_mode}

    e in DBConnection.ConnectionError ->
      Logger.debug("[MemoryRouter] Routing skipped (connection): #{Exception.message(e)}")
      {:error, :sandbox_mode}

    e ->
      Logger.error("Routing failed: #{Exception.message(e)}")
      {:error, {:routing_failed, e}}
  end

  @doc """
  Analyze a query to determine its type and routing confidence.

  ## Returns

    `{type, confidence}` tuple where:
    - `type` is one of `:factual`, `:relational`, `:temporal`, `:procedural`, `:hybrid`
    - `confidence` is a float between 0.0 and 1.0
  """
  @spec analyze(String.t()) :: {atom(), float()}
  def analyze(query) do
    query_lower = String.downcase(query)
    # Remove punctuation and split into words
    words =
      query_lower
      |> String.replace(~r/[^\w\s]/, "")
      |> String.split()

    # Check for procedural "how to" patterns
    procedural_how_score = if has_how_pattern?(query_lower), do: 0.5, else: 0.0
    # Check for factual "what is" patterns
    factual_pattern_score = if has_factual_pattern?(query_lower), do: 0.5, else: 0.0

    # Score each type
    scores = %{
      relational: score_indicators(words, @relational_indicators),
      temporal: score_indicators(words, @temporal_indicators),
      procedural: max(score_indicators(words, @procedural_indicators), procedural_how_score),
      factual: max(score_indicators(words, @factual_indicators), factual_pattern_score)
    }

    # Find highest scoring type
    {best_type, best_score} =
      scores
      |> Enum.max_by(fn {_, score} -> score end)

    cond do
      # No clear winner - use hybrid
      best_score < 0.1 ->
        {:hybrid, 0.5}

      # Strong signal for a specific type
      best_score >= 0.3 ->
        {best_type, best_score}

      # Moderate signal - might be hybrid
      true ->
        second_score =
          scores
          |> Map.delete(best_type)
          |> Map.values()
          |> Enum.max()

        if second_score > best_score * 0.8 do
          {:hybrid, 0.6}
        else
          {best_type, best_score}
        end
    end
  end

  @doc """
  Get routing explanation for a query.
  """
  @spec explain_routing(String.t()) :: map()
  def explain_routing(query) do
    query_lower = String.downcase(query)
    # Remove punctuation and split into words
    words =
      query_lower
      |> String.replace(~r/[^\w\s]/, "")
      |> String.split()

    # Check for procedural "how to" patterns
    procedural_how_score = if has_how_pattern?(query_lower), do: 0.5, else: 0.0
    # Check for factual "what is" patterns
    factual_pattern_score = if has_factual_pattern?(query_lower), do: 0.5, else: 0.0

    scores = %{
      relational: score_indicators(words, @relational_indicators),
      temporal: score_indicators(words, @temporal_indicators),
      procedural: max(score_indicators(words, @procedural_indicators), procedural_how_score),
      factual: max(score_indicators(words, @factual_indicators), factual_pattern_score)
    }

    {selected_type, confidence} = analyze(query)

    matched_indicators = %{
      relational: find_matched(words, @relational_indicators),
      temporal: find_matched(words, @temporal_indicators),
      procedural: find_matched(words, @procedural_indicators),
      factual: find_matched(words, @factual_indicators)
    }

    %{
      query: query,
      selected_type: selected_type,
      confidence: confidence,
      type_scores: scores,
      matched_indicators: matched_indicators,
      recommended_stores: get_recommended_stores(selected_type)
    }
  end

  defp vector_route(query, opts) do
    case HybridRetriever.search(query, Keyword.merge(opts, strategy: :vector_heavy)) do
      results when is_list(results) -> results
      _ -> []
    end
  end

  defp graph_route(query, opts) do
    case HybridRetriever.search(query, Keyword.merge(opts, strategy: :graph_heavy)) do
      results when is_list(results) -> results
      _ -> []
    end
  end

  defp temporal_route(query, opts) do
    case HybridRetriever.search(query, Keyword.merge(opts, strategy: :recency_heavy)) do
      results when is_list(results) -> results
      _ -> []
    end
  end

  # ROADMAP Phase 1b P1: Aggregation route for summarization queries
  # Returns more results for summarization, with balanced retrieval
  defp aggregation_route(query, opts) do
    # For aggregation/summarization, we want more diverse results
    aggregation_opts =
      opts
      |> Keyword.put(:limit, max(Keyword.get(opts, :limit, 10) * 2, 20))
      |> Keyword.put(:strategy, :balanced)

    case HybridRetriever.search(query, aggregation_opts) do
      results when is_list(results) -> results
      _ -> []
    end
  end

  defp procedural_route(query, opts) do
    limit = Keyword.get(opts, :limit, 10)

    # Search procedural store
    proc_results =
      case ProceduralStore.search(query, limit: limit) do
        {:ok, results} ->
          Enum.map(results, fn r -> {r, 0.8} end)

        _ ->
          []
      end

    # Also search general memories for procedural content
    general_results =
      HybridRetriever.search(query, Keyword.merge(opts, filters: %{category: "action"}))

    merge_results(proc_results, general_results)
  end

  defp hybrid_route(query, opts) do
    HybridRetriever.search(query, Keyword.merge(opts, strategy: :balanced))
  end

  defp search_working_memory(query, limit) do
    case SafeMemory.search(query, limit: limit) do
      results when is_list(results) ->
        # Convert WorkingMemoryItem structs to maps for JSON encoding
        # Add source marker and convert to scored tuples with working memory boost
        Enum.map(results, fn item ->
          item_map =
            item
            |> Map.from_struct()
            # Remove large fields
            |> Map.drop([:embedding])
            |> Map.put(:source, :working_memory)

          {item_map, item.importance + 0.2}
        end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp score_indicators(words, indicators) do
    matched = Enum.count(words, &(&1 in indicators))

    cond do
      matched == 0 -> 0.0
      matched == 1 -> 0.4
      matched == 2 -> 0.6
      matched >= 3 -> 0.8
      true -> 0.0
    end
  end

  defp find_matched(words, indicators) do
    Enum.filter(words, &(&1 in indicators))
  end

  defp has_how_pattern?(query_lower) do
    Enum.any?(@procedural_how_patterns, &String.contains?(query_lower, &1))
  end

  defp has_factual_pattern?(query_lower) do
    Enum.any?(@factual_patterns, &String.contains?(query_lower, &1))
  end

  defp get_recommended_stores(:relational), do: [:graph, :vector]
  defp get_recommended_stores(:temporal), do: [:vector, :recency]
  defp get_recommended_stores(:procedural), do: [:procedural, :vector]
  defp get_recommended_stores(:factual), do: [:vector]
  defp get_recommended_stores(:aggregation), do: [:vector, :graph, :recency]
  defp get_recommended_stores(:hybrid), do: [:vector, :graph, :recency]
  defp get_recommended_stores(_), do: [:vector]

  # ============================================================================
  # ROADMAP Phase 1b P3: Multi-Query Expansion
  # ============================================================================

  @doc false
  # Expand search by running additional queries and merging results.
  # Primary query results get a score boost, expansion results are weighted lower.
  # Limited to max 3 expansions to avoid latency explosion.
  defp expand_and_merge(primary_results, expanded_queries, query_type, opts) do
    # Limit expansions to avoid excessive latency
    expansions = Enum.take(expanded_queries, 3)

    Logger.debug("[MemoryRouter] Expanding with #{length(expansions)} additional queries")

    # Run expansion queries with reduced limit (we're supplementing, not replacing)
    expansion_limit = min(Keyword.get(opts, :limit, 10), 5)

    expansion_opts =
      opts |> Keyword.put(:limit, expansion_limit) |> Keyword.put(:use_expansion, false)

    # Execute expansion queries in parallel for better performance
    expansion_results =
      expansions
      |> Task.async_stream(
        fn exp_query ->
          route_for_type(exp_query, query_type, expansion_opts)
        end,
        timeout: 5_000,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, results} when is_list(results) -> results
        _ -> []
      end)

    # Discount expansion results by 20% (primary query is more relevant)
    discounted_expansions =
      Enum.map(expansion_results, fn
        {item, score} -> {item, score * 0.8}
        item -> {item, 0.4}
      end)

    # Merge with primary results
    merge_results(primary_results, discounted_expansions)
  end

  # Route a single query to the appropriate retrieval function based on type
  defp route_for_type(query, query_type, opts) do
    case query_type do
      :relational -> graph_route(query, opts)
      :temporal -> temporal_route(query, opts)
      :procedural -> procedural_route(query, opts)
      :factual -> vector_route(query, opts)
      :aggregation -> aggregation_route(query, opts)
      :hybrid -> hybrid_route(query, opts)
      _ -> hybrid_route(query, opts)
    end
  end

  defp merge_results(results1, results2) do
    # Merge and deduplicate by id, keeping highest score
    (results1 ++ results2)
    |> Enum.group_by(fn
      {%{id: id}, _} -> id
      {item, _} -> :erlang.phash2(item)
    end)
    |> Enum.map(fn {_id, items} ->
      Enum.max_by(items, &elem(&1, 1))
    end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
  end
end
