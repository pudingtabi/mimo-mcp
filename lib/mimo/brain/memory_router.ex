defmodule Mimo.Brain.MemoryRouter do
  @moduledoc """
  Intelligent memory routing based on query analysis.

  Routes queries to optimal memory stores based on:
  - Query type detection (factual, relational, temporal, procedural)
  - Query complexity analysis
  - Available store capabilities

  ## Query Types

    * `:factual` - Direct fact lookup → Vector search
    * `:relational` - Entity relationships → Graph search
    * `:temporal` - Time-based queries → Recency search
    * `:procedural` - How-to/process → Procedural store
    * `:hybrid` - Complex multi-aspect → All stores

  ## Examples

      # Auto-route a query
      {:ok, results} = MemoryRouter.route("How is auth related to users?")

      # Analyze query type
      {:relational, 0.85} = MemoryRouter.analyze("What are the relationships?")

      # Force specific routing
      {:ok, results} = MemoryRouter.route(query, strategy: :graph)
  """
  require Logger

  alias Mimo.Brain.{HybridRetriever, WorkingMemory}
  alias Mimo.ProceduralStore

  # Query type indicators
  # Note: "how" is only procedural when followed by "to" or "do" (how-to patterns)
  @relational_indicators ~w(related relationship connected link between association)
  @temporal_indicators ~w(recent recently latest today yesterday last first newest oldest ago)
  @procedural_indicators ~w(steps process procedure guide tutorial workflow setup configure)
  @procedural_how_patterns ["how to", "how do", "how can", "how should"]
  @factual_indicators ~w(what is define meaning explain describe definition)

  # ==========================================================================
  # Public API
  # ==========================================================================

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
    strategy = Keyword.get(opts, :strategy, :auto)
    limit = Keyword.get(opts, :limit, 10)
    include_working = Keyword.get(opts, :include_working, true)

    # Determine routing strategy
    {query_type, confidence} =
      if strategy == :auto do
        analyze(query)
      else
        {strategy, 1.0}
      end

    :telemetry.execute(
      [:mimo, :memory, :routing],
      %{confidence: confidence},
      %{query_type: query_type, strategy: strategy}
    )

    Logger.debug("Routing query as #{query_type} (confidence: #{Float.round(confidence, 2)})")

    # Execute appropriate retrieval strategy
    results =
      case query_type do
        :relational -> graph_route(query, opts)
        :temporal -> temporal_route(query, opts)
        :procedural -> procedural_route(query, opts)
        :factual -> vector_route(query, opts)
        :hybrid -> hybrid_route(query, opts)
        _ -> hybrid_route(query, opts)
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
    {:ok, Enum.take(results, limit)}
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

    # Score each type
    scores = %{
      relational: score_indicators(words, @relational_indicators),
      temporal: score_indicators(words, @temporal_indicators),
      procedural: max(score_indicators(words, @procedural_indicators), procedural_how_score),
      factual: score_indicators(words, @factual_indicators)
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

    scores = %{
      relational: score_indicators(words, @relational_indicators),
      temporal: score_indicators(words, @temporal_indicators),
      procedural: max(score_indicators(words, @procedural_indicators), procedural_how_score),
      factual: score_indicators(words, @factual_indicators)
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

  # ==========================================================================
  # Routing Strategies
  # ==========================================================================

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

  # ==========================================================================
  # Working Memory Integration
  # ==========================================================================

  defp search_working_memory(query, limit) do
    case WorkingMemory.search(query, limit: limit) do
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

  # ==========================================================================
  # Helpers
  # ==========================================================================

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

  defp get_recommended_stores(:relational), do: [:graph, :vector]
  defp get_recommended_stores(:temporal), do: [:vector, :recency]
  defp get_recommended_stores(:procedural), do: [:procedural, :vector]
  defp get_recommended_stores(:factual), do: [:vector]
  defp get_recommended_stores(:hybrid), do: [:vector, :graph, :recency]
  defp get_recommended_stores(_), do: [:vector]

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
