defmodule Mimo.Brain.HybridRetriever do
  @moduledoc """
  Unified retrieval system combining vector search and knowledge graph.

  Orchestrates multiple retrieval strategies:
  1. Vector similarity search (semantic)
  2. Knowledge graph traversal (relational)
  3. Recency-weighted search (temporal)
  4. Keyword search (lexical)

  Results are merged and scored using HybridScorer.

  ## Configuration

      config :mimo_mcp, :hybrid_retrieval,
        vector_limit: 20,
        graph_limit: 10,
        recency_limit: 10,
        final_limit: 10

  ## Examples

      # Basic hybrid search
      results = HybridRetriever.search("What is authentication?")

      # With options
      results = HybridRetriever.search(query,
        limit: 5,
        strategy: :balanced,
        filters: %{category: "fact"}
      )
  """
  require Logger

  alias Mimo.Brain.{Memory, HybridScorer, AccessTracker, LLM}
  alias Mimo.SemanticStore

  @default_vector_limit 20
  @default_graph_limit 10
  @default_final_limit 10

  # ==========================================================================
  # Public API
  # ==========================================================================

  @doc """
  Perform hybrid search across all memory stores.

  ## Parameters

    * `query` - Search query string
    * `opts` - Search options

  ## Options

    * `:limit` - Maximum results to return (default: 10)
    * `:strategy` - `:balanced`, `:vector_heavy`, `:graph_heavy`, `:recency_heavy`
    * `:filters` - Map of field filters (e.g., `%{category: "fact"}`)
    * `:min_score` - Minimum hybrid score (default: 0.1)
    * `:track_access` - Whether to track access (default: true)

  ## Returns

    List of `{memory, score}` tuples sorted by hybrid score
  """
  @spec search(String.t(), keyword()) :: [{map(), float()}]
  def search(query, opts \\ []) do
    strategy = Keyword.get(opts, :strategy, :balanced)
    limit = Keyword.get(opts, :limit, @default_final_limit)
    min_score = Keyword.get(opts, :min_score, 0.1)
    track_access = Keyword.get(opts, :track_access, true)
    filters = Keyword.get(opts, :filters, %{})

    :telemetry.execute(
      [:mimo, :memory, :hybrid_search, :started],
      %{},
      %{strategy: strategy, limit: limit}
    )

    # Get query embedding for vector search
    query_embedding = get_query_embedding(query)

    # Configure weights based on strategy
    weights = get_strategy_weights(strategy)

    # Parallel retrieval from multiple sources
    results =
      [
        Task.async(fn -> vector_search(query, query_embedding, opts) end),
        Task.async(fn -> graph_search(query, opts) end),
        Task.async(fn -> recency_search(opts) end)
      ]
      |> Task.await_many(10_000)
      |> List.flatten()
      |> deduplicate()
      |> apply_filters(filters)
      |> score_and_rank(query_embedding, weights)
      |> Enum.filter(fn {_, score} -> score >= min_score end)
      |> Enum.take(limit)

    # Track access for decay scoring
    if track_access do
      results
      |> Enum.map(fn {memory, _} -> memory.id end)
      |> AccessTracker.track_many()
    end

    :telemetry.execute(
      [:mimo, :memory, :hybrid_search, :completed],
      %{result_count: length(results)},
      %{strategy: strategy}
    )

    results
  end

  @doc """
  Get just the memories without scores.
  """
  @spec search_memories(String.t(), keyword()) :: [map()]
  def search_memories(query, opts \\ []) do
    search(query, opts)
    |> Enum.map(&elem(&1, 0))
  end

  @doc """
  Explain the search results for debugging.
  """
  @spec explain_search(String.t(), keyword()) :: map()
  def explain_search(query, opts \\ []) do
    strategy = Keyword.get(opts, :strategy, :balanced)
    query_embedding = get_query_embedding(query)
    weights = get_strategy_weights(strategy)

    vector_results = vector_search(query, query_embedding, opts)
    graph_results = graph_search(query, opts)
    recency_results = recency_search(opts)

    all_results =
      (vector_results ++ graph_results ++ recency_results)
      |> deduplicate()

    %{
      query: query,
      strategy: strategy,
      weights: weights,
      sources: %{
        vector: length(vector_results),
        graph: length(graph_results),
        recency: length(recency_results)
      },
      total_unique: length(all_results),
      results:
        all_results
        |> Enum.take(5)
        |> Enum.map(fn memory ->
          %{
            id: memory.id,
            content_preview: String.slice(memory.content, 0..100),
            score_breakdown: HybridScorer.explain(memory, query_embedding, weights: weights)
          }
        end)
    }
  end

  # ==========================================================================
  # Retrieval Strategies
  # ==========================================================================

  defp vector_search(_query, nil, _opts), do: []

  defp vector_search(_query, embedding, opts) do
    limit = Keyword.get(opts, :vector_limit, @default_vector_limit)

    # Use search_with_embedding to avoid re-generating the embedding
    case Memory.search_with_embedding(embedding, limit: limit) do
      {:ok, results} -> results
      _ -> []
    end
  rescue
    e ->
      Logger.warning("Vector search failed: #{Exception.message(e)}")
      []
  end

  defp graph_search(query, opts) do
    limit = Keyword.get(opts, :graph_limit, @default_graph_limit)

    case SemanticStore.query_related(query, limit: limit) do
      {:ok, triples} ->
        # Convert triples to memory-like maps
        triples
        |> Enum.flat_map(&triple_to_memories/1)
        |> Enum.uniq_by(& &1.id)

      _ ->
        []
    end
  rescue
    e ->
      Logger.warning("Graph search failed: #{Exception.message(e)}")
      []
  end

  defp recency_search(opts) do
    limit = Keyword.get(opts, :recency_limit, @default_graph_limit)

    case Memory.get_recent(limit: limit) do
      {:ok, results} -> results
      _ -> []
    end
  rescue
    e ->
      Logger.warning("Recency search failed: #{Exception.message(e)}")
      []
  end

  # ==========================================================================
  # Scoring & Ranking
  # ==========================================================================

  defp score_and_rank(memories, query_embedding, weights) do
    # Pre-compute graph scores for memories
    graph_scores = compute_graph_scores(memories)

    memories
    |> Enum.map(fn memory ->
      graph_score = Map.get(graph_scores, memory.id, 0.0)

      score =
        HybridScorer.score(memory, query_embedding,
          weights: weights,
          graph_score: graph_score
        )

      {memory, score}
    end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
  end

  defp compute_graph_scores(memories) do
    # Compute connectivity scores based on knowledge graph relationships
    memories
    |> Enum.map(fn memory ->
      score =
        case SemanticStore.count_connections(memory.id) do
          {:ok, count} -> min(1.0, count / 10)
          _ -> 0.0
        end

      {memory.id, score}
    end)
    |> Map.new()
  rescue
    e ->
      Logger.warning("Graph scores failed: #{Exception.message(e)}")
      %{}
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  defp get_query_embedding(query) do
    case LLM.generate_embedding(query) do
      {:ok, embedding} -> embedding
      _ -> nil
    end
  rescue
    e ->
      Logger.warning("Query embedding failed: #{Exception.message(e)}")
      nil
  end

  defp get_strategy_weights(:balanced) do
    %{vector: 0.35, recency: 0.25, access: 0.15, importance: 0.15, graph: 0.10}
  end

  defp get_strategy_weights(:vector_heavy) do
    %{vector: 0.50, recency: 0.15, access: 0.10, importance: 0.15, graph: 0.10}
  end

  defp get_strategy_weights(:graph_heavy) do
    %{vector: 0.25, recency: 0.15, access: 0.15, importance: 0.15, graph: 0.30}
  end

  defp get_strategy_weights(:recency_heavy) do
    %{vector: 0.25, recency: 0.40, access: 0.10, importance: 0.15, graph: 0.10}
  end

  defp get_strategy_weights(_), do: get_strategy_weights(:balanced)

  defp deduplicate(memories) do
    memories
    |> Enum.uniq_by(fn
      %{id: id} -> id
      memory -> :erlang.phash2(memory)
    end)
  end

  defp apply_filters(memories, filters) when map_size(filters) == 0, do: memories

  defp apply_filters(memories, filters) do
    Enum.filter(memories, fn memory ->
      Enum.all?(filters, fn {key, value} ->
        Map.get(memory, key) == value
      end)
    end)
  end

  defp triple_to_memories(%{subject: s, predicate: p, object: o} = triple) do
    # Convert graph triple to memory-like map for scoring
    [
      %{
        id: "triple:#{:erlang.phash2(triple)}",
        content: "#{s} #{p} #{o}",
        category: "knowledge",
        importance: 0.5,
        access_count: 0,
        inserted_at: NaiveDateTime.utc_now(),
        metadata: %{"source" => "graph"}
      }
    ]
  end

  defp triple_to_memories(_), do: []
end
