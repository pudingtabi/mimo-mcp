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

  alias Mimo.Brain.{AccessTracker, Engram, HybridScorer, LLM, Memory, VocabularyIndex}
  alias Mimo.Repo
  alias Mimo.SemanticStore
  alias Mimo.Synapse.SpreadingActivation
  import Ecto.Query

  @default_vector_limit 20
  @default_graph_limit 10
  @default_keyword_limit 15
  @default_final_limit 10

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
    # Time filter support - filter by date range
    from_date = Keyword.get(opts, :from_date)
    to_date = Keyword.get(opts, :to_date)

    :telemetry.execute(
      [:mimo, :memory, :hybrid_search, :started],
      %{},
      %{strategy: strategy, limit: limit}
    )

    # Get query embedding for vector search
    query_embedding = get_query_embedding(query)

    # Configure weights based on strategy
    weights = get_strategy_weights(strategy)

    # Parallel retrieval from multiple sources with graceful timeout handling
    # Use Task.Supervisor for proper supervision and sandbox allowance propagation
    tasks = [
      {:vector, async_with_callers(fn -> vector_search(query, query_embedding, opts) end)},
      {:graph, async_with_callers(fn -> graph_search(query, opts) end)},
      {:recency, async_with_callers(fn -> recency_search(opts) end)},
      {:keyword, async_with_callers(fn -> keyword_search(query, opts) end)},
      {:spreading, async_with_callers(fn -> spreading_search(query_embedding, opts) end)}
    ]

    results =
      tasks
      |> Enum.map(fn {_name, task} -> task end)
      |> Task.yield_many(10_000)
      |> Enum.zip(tasks)
      |> Enum.map(fn
        {{_task, {:ok, result}}, _} ->
          result

        {{task, nil}, {name, _}} ->
          Task.shutdown(task, :brutal_kill)
          Logger.warning("[HybridRetriever] #{name} search timed out")
          []

        {{_task, {:exit, reason}}, {name, _}} ->
          Logger.warning("[HybridRetriever] #{name} search crashed: #{inspect(reason)}")
          []
      end)
      |> List.flatten()
      |> deduplicate()
      |> apply_filters(filters)
      |> apply_time_filter(from_date, to_date)
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
    keyword_results = keyword_search(query, opts)
    spreading_results = spreading_search(query_embedding, opts)

    all_results =
      (vector_results ++ graph_results ++ recency_results ++ keyword_results ++ spreading_results)
      |> deduplicate()

    %{
      query: query,
      strategy: strategy,
      weights: weights,
      sources: %{
        vector: length(vector_results),
        graph: length(graph_results),
        recency: length(recency_results),
        keyword: length(keyword_results),
        spreading: length(spreading_results)
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

  defp keyword_search(query, opts) do
    limit = Keyword.get(opts, :keyword_limit, @default_keyword_limit)

    # Use FTS5 VocabularyIndex for BM25-ranked lexical search
    # Falls back to ILIKE automatically if FTS5 unavailable
    case VocabularyIndex.search(query, limit: limit) do
      {:ok, results} ->
        # Convert to format expected by rest of pipeline
        results
        |> Enum.map(fn {memory, score} ->
          memory
          |> Map.put(:similarity, score)
          |> Map.put(:source, :fts5)
        end)

      {:error, reason} ->
        Logger.warning("[HybridRetriever] VocabularyIndex search failed: #{inspect(reason)}")
        # Fallback to legacy ILIKE search
        keyword_search_fallback(query, opts)
    end
  rescue
    e ->
      Logger.warning("Keyword search failed: #{Exception.message(e)}")
      []
  end

  # Legacy ILIKE-based keyword search (fallback when FTS5 unavailable)
  defp keyword_search_fallback(query, opts) do
    limit = Keyword.get(opts, :keyword_limit, @default_keyword_limit)

    # Extract keywords from query (split on whitespace, filter short words)
    keywords =
      query
      |> String.downcase()
      |> String.split(~r/\s+/, trim: true)
      |> Enum.filter(&(String.length(&1) >= 2))

    if keywords == [] do
      []
    else
      # Build LIKE conditions for each keyword
      # SQLite uses LIKE with COLLATE NOCASE for case-insensitive matching
      base_query =
        from(e in Engram,
          where: e.archived == false or is_nil(e.archived),
          limit: ^limit,
          order_by: [desc: e.importance]
        )

      # Add WHERE conditions for keywords using fragments
      query_with_conditions =
        Enum.reduce(keywords, base_query, fn keyword, acc ->
          pattern = "%#{escape_like(keyword)}%"
          from(e in acc, where: fragment("? LIKE ? COLLATE NOCASE", e.content, ^pattern))
        end)

      # Convert Engram structs to maps with similarity field for compatibility
      Repo.all(query_with_conditions)
      |> Enum.map(fn engram ->
        engram
        |> Map.from_struct()
        # Keyword matches get a high base similarity
        |> Map.put(:similarity, 0.8)
      end)
    end
  rescue
    e ->
      Logger.warning("Keyword search fallback failed: #{Exception.message(e)}")
      []
  end

  # Spreading Activation search: Use Hebbian-learned graph for associative retrieval
  # This implements Collins & Loftus spreading activation through the memory graph
  defp spreading_search(nil, _opts), do: []

  defp spreading_search(query_embedding, opts) do
    limit = Keyword.get(opts, :spreading_limit, 10)

    # First, get seed memories from vector search (top 5)
    seed_memories =
      case Memory.search_with_embedding(query_embedding, limit: 5) do
        {:ok, results} -> Enum.map(results, & &1.id)
        _ -> []
      end

    if seed_memories == [] do
      []
    else
      # Run spreading activation from seed memories
      activated =
        SpreadingActivation.activate_from_memories(
          query_embedding,
          seed_memories,
          max_hops: 2,
          top_k: limit,
          include_start: false
        )

      # Convert activated memory IDs back to full memory records
      activated
      |> Enum.flat_map(fn {memory_id, activation_score} ->
        case Repo.get(Engram, memory_id) do
          nil ->
            []

          engram ->
            [
              engram
              |> Map.from_struct()
              # Use activation score as similarity proxy
              |> Map.put(:similarity, activation_score)
              |> Map.put(:source, :spreading_activation)
            ]
        end
      end)
    end
  rescue
    e ->
      Logger.warning("Spreading activation search failed: #{Exception.message(e)}")
      []
  end

  # Escape special LIKE characters to prevent injection
  defp escape_like(string) do
    string
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

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

  # Time filter - filter memories by date range
  # Applied BEFORE scoring to ensure we have enough candidates in the time window
  defp apply_time_filter(memories, nil, nil), do: memories

  defp apply_time_filter(memories, from_date, to_date) do
    Enum.filter(memories, fn memory ->
      # Support both :inserted_at (long-term) and :created_at (working memory)
      inserted_at = Map.get(memory, :inserted_at) || Map.get(memory, :created_at)

      case inserted_at do
        nil ->
          # No date = include (conservative approach for graph/working memory results)
          true

        dt when is_struct(dt, NaiveDateTime) ->
          from_ok = is_nil(from_date) or NaiveDateTime.compare(dt, to_naive(from_date)) != :lt
          to_ok = is_nil(to_date) or NaiveDateTime.compare(dt, to_naive(to_date)) != :gt
          from_ok and to_ok

        dt when is_struct(dt, DateTime) ->
          # Convert DateTime to NaiveDateTime for comparison
          naive_dt = DateTime.to_naive(dt)
          from_ok = is_nil(from_date) or NaiveDateTime.compare(naive_dt, to_naive(from_date)) != :lt
          to_ok = is_nil(to_date) or NaiveDateTime.compare(naive_dt, to_naive(to_date)) != :gt
          from_ok and to_ok

        _ ->
          # Unknown format - include to avoid false negatives
          true
      end
    end)
  end

  # Convert DateTime/NaiveDateTime to NaiveDateTime for comparison
  defp to_naive(%DateTime{} = dt), do: DateTime.to_naive(dt)
  defp to_naive(%NaiveDateTime{} = dt), do: dt
  defp to_naive(nil), do: nil

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

  # Spawn a task that propagates $callers for Ecto Sandbox allowance in tests.
  # This ensures spawned tasks inherit database connection access from the caller.
  defp async_with_callers(fun) do
    caller = self()
    callers = Process.get(:"$callers", [])

    # Check if TaskSupervisor is available before spawning
    case Mimo.TaskHelper.supervisor_available?(Mimo.TaskSupervisor) do
      true ->
        Task.Supervisor.async(Mimo.TaskSupervisor, fn ->
          # Propagate $callers for Ecto Sandbox allowance
          Process.put(:"$callers", [caller | callers])
          fun.()
        end)

      false ->
        # Fallback: run synchronously with Task.async (unsupervised)
        Task.async(fn ->
          Process.put(:"$callers", [caller | callers])
          fun.()
        end)
    end
  end
end
