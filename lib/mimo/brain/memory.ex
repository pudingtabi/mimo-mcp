defmodule Mimo.Brain.Memory do
  @moduledoc """
  Local vector memory store using SQLite and embeddings.

  Memory-safe implementation with:
  - O(1) memory usage via streaming (regardless of database size)
  - Configurable batch sizes
  - Content size limits
  - ACID transactions for writes
  - Embedding dimension validation
  - Retry strategies for database operations
  - Int8 quantization for efficient storage (SPEC-031)
  - Binary quantization for fast pre-filtering (SPEC-033)
  - HNSW index for O(log n) ANN search (SPEC-033 Phase 3b)

  ## Search Strategies (SPEC-033)

  The module supports multiple search strategies:
  - `:exact` - Full int8 cosine similarity on all memories (accurate, O(n))
  - `:binary_rescore` - Two-stage: binary Hamming filter → int8 rescore (fast, O(n) but faster)
  - `:hnsw` - HNSW approximate nearest neighbor search (very fast, O(log n))
  - `:auto` - Automatically select based on memory count

  ## Strategy Selection (Auto Mode)

  | Memory Count | Strategy Used | Performance |
  |--------------|---------------|-------------|
  | < 500        | :exact        | Fast enough for small sets |
  | 500 - 999    | :binary_rescore | Two-stage search |
  | >= 1000      | :hnsw         | O(log n) ANN search |

  ## Two-Stage Search Architecture

  For medium memory stores (500-999 memories), the two-stage search provides
  significant speedup:

  1. **Stage 1: Binary Pre-filter**
     - Compute Hamming distance on 32-byte binary embeddings
     - Select top N candidates (N = limit * candidates_multiplier)
     - ~10x faster than int8 cosine similarity

  2. **Stage 2: Int8 Rescore**
     - Compute full int8 cosine similarity only on candidates
     - Re-rank and apply final threshold
     - Maintains >95% recall vs exact search

  ## HNSW Index (SPEC-033 Phase 3b)

  For large memory stores (>=1000 memories), the HNSW index provides:
  - O(log n) query time instead of O(n)
  - ~100x speedup at 10K+ memories
  - >95% recall@10 vs exact search
  - Automatic index management via HnswIndex GenServer
  """
  import Ecto.Query
  require Logger
  alias Mimo.Awakening.Hooks, as: AwakeningHooks
  alias Mimo.Brain.EmbeddingManager
  alias Mimo.Brain.EmotionalScorer
  alias Mimo.Brain.Engram
  alias Mimo.Brain.HnswIndex
  alias Mimo.Brain.MemoryIntegrator
  alias Mimo.Brain.NoveltyDetector
  alias Mimo.Brain.ReasoningBridge
  alias Mimo.ErrorHandling.RetryStrategies
  alias Mimo.Repo
  alias Mimo.Brain.AccessTracker
  alias Mimo.Brain.Forgetting
  alias Mimo.Brain.LLM
  alias Mimo.Cache.Classifier
  alias Mimo.Synapse.Linker, as: SynapseLinker
  alias Mimo.Synapse.Orchestrator, as: SynapseOrchestrator
  alias Mimo.Vector.Math

  # Configuration constants
  @max_memory_batch_size 1000
  # 100KB max per memory
  @max_content_size 100_000
  # Safety limit for embedding dimensions
  @max_embedding_dim 4096

  # SPEC-033: Search strategy thresholds
  # Threshold for using binary pre-filter (memory count)
  @binary_search_threshold 500
  # Threshold for using HNSW index (memory count)
  @hnsw_search_threshold 1000
  # How many extra candidates to fetch in binary stage (multiplier of limit)
  @candidates_multiplier 10

  @doc """
  Search memories by semantic similarity.

  Uses adaptive strategy based on memory count:
  - <500 memories: exact search (full int8 cosine on all)
  - 500-999 memories: two-stage search (binary pre-filter + int8 rescore)
  - >=1000 memories: HNSW index search (O(log n) ANN)

  ## Options

    * `:limit` - Maximum results to return (default: 10)
    * `:min_similarity` - Minimum similarity threshold 0-1 (default: 0.3)
    * `:strategy` - Search strategy `:auto`, `:exact`, `:binary_rescore`, or `:hnsw` (default: :auto)
    * `:recency_boost` - Weight for recency in scoring 0-1 (default: 0.0)
    * `:category` - Filter by category (optional)
    * `:project_id` - Filter by project (optional)
    * `:tags` - Filter by tags (optional)

  ## Examples

      search_memories("project architecture", limit: 5)
      search_memories("error handling", min_similarity: 0.5)
      search_memories("SPEC-025 completion", recency_boost: 0.3)
      search_memories("auth bug", strategy: :hnsw, limit: 20)
  """
  def search_memories(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    min_similarity = Keyword.get(opts, :min_similarity, 0.3)
    strategy = Keyword.get(opts, :strategy, :auto)
    recency_boost = Keyword.get(opts, :recency_boost, 0.0)

    case generate_embedding(query) do
      {:ok, query_embedding} ->
        # Quantize query embedding for search
        results =
          case Math.quantize_int8(query_embedding) do
            {:ok, {query_int8, _scale, _offset}} ->
              # Determine search strategy
              actual_strategy = select_strategy(strategy, opts)

              case actual_strategy do
                :hnsw ->
                  hnsw_search(query_int8, limit, min_similarity, recency_boost, opts)

                :binary_rescore ->
                  two_stage_search(
                    query_embedding,
                    query_int8,
                    limit,
                    min_similarity,
                    recency_boost,
                    opts
                  )

                :exact ->
                  exact_search(query_int8, limit, min_similarity, recency_boost, opts)
              end

            {:error, _reason} ->
              # Fallback to streaming search with float32
              stream_search(
                query_embedding,
                limit,
                min_similarity,
                @max_memory_batch_size,
                recency_boost
              )
          end

        # SPEC-012: Track memory access for adaptive decay reinforcement
        if results != [] do
          ids = Enum.map(results, & &1[:id]) |> Enum.reject(&is_nil/1)

          if ids != [] do
            Logger.debug("AccessTracker: tracking #{length(ids)} memory accesses")
            AccessTracker.track_many(ids)
          end
        end

        results

      {:error, reason} ->
        Logger.error("Embedding generation failed: #{inspect(reason)}")
        []
    end
  rescue
    e in DBConnection.OwnershipError ->
      # Expected in test mode when background processes don't have sandbox access
      Logger.debug("Memory search skipped (sandbox mode): #{Exception.message(e)}")
      []

    e in DBConnection.ConnectionError ->
      # Can also occur in sandbox mode with connection issues
      Logger.debug("Memory search skipped (connection): #{Exception.message(e)}")
      []

    e ->
      Logger.error("Memory search failed: #{Exception.message(e)}")
      []
  end

  @doc """
  Search memories using a pre-computed embedding vector.
  Avoids redundant embedding generation when caller already has one.

  ## Options

    * `:limit` - Maximum results to return (default: 10)
    * `:min_similarity` - Minimum similarity threshold 0-1 (default: 0.3)
    * `:strategy` - Search strategy `:auto`, `:exact`, `:binary_rescore`, or `:hnsw` (default: :auto)
    * `:recency_boost` - Weight for recency in scoring 0-1 (default: 0.0)

  ## Examples

      {:ok, embedding} = LLM.generate_embedding("query")
      search_with_embedding(embedding, limit: 5)
  """
  def search_with_embedding(embedding, opts \\ []) when is_list(embedding) do
    limit = Keyword.get(opts, :limit, 10)
    min_similarity = Keyword.get(opts, :min_similarity, 0.3)
    strategy = Keyword.get(opts, :strategy, :auto)
    recency_boost = Keyword.get(opts, :recency_boost, 0.0)

    results =
      case Math.quantize_int8(embedding) do
        {:ok, {query_int8, _scale, _offset}} ->
          actual_strategy = select_strategy(strategy, opts)

          case actual_strategy do
            :hnsw ->
              hnsw_search(query_int8, limit, min_similarity, recency_boost, opts)

            :binary_rescore ->
              two_stage_search(embedding, query_int8, limit, min_similarity, recency_boost, opts)

            :exact ->
              exact_search(query_int8, limit, min_similarity, recency_boost, opts)
          end

        {:error, _reason} ->
          stream_search(embedding, limit, min_similarity, @max_memory_batch_size, recency_boost)
      end

    # SPEC-012: Track memory access for adaptive decay reinforcement
    if results != [] do
      ids = Enum.map(results, & &1[:id]) |> Enum.reject(&is_nil/1)
      if ids != [], do: AccessTracker.track_many(ids)
    end

    {:ok, results}
  rescue
    e in DBConnection.OwnershipError ->
      # Expected in test mode when background processes don't have sandbox access
      Logger.debug("Memory search with embedding skipped (sandbox mode): #{Exception.message(e)}")
      {:ok, []}

    e in DBConnection.ConnectionError ->
      # Can also occur in sandbox mode with connection issues
      Logger.debug("Memory search with embedding skipped (connection): #{Exception.message(e)}")
      {:ok, []}

    e ->
      Logger.error("Memory search with embedding failed: #{Exception.message(e)}")
      {:ok, []}
  end

  @doc """
  Count total memories in the store.

  Useful for strategy selection and statistics.

  ## Examples

      count_memories()
      #=> 1234
  """
  def count_memories do
    Repo.one(from(e in Engram, select: count(e.id))) || 0
  end

  @doc """
  Determine which search strategy to use based on memory count.

  This function exposes the strategy selection logic for testing and
  allows callers to understand which strategy will be used for a given
  memory count.

  ## Arguments

    * `count` - Number of memories in the store
    * `explicit_strategy` - Optional explicit strategy override (nil for auto)

  ## Returns

    * `:exact` - For small memory counts (<500)
    * `:binary_rescore` - For medium counts (500-999) or when HNSW unavailable
    * `:hnsw` - For large counts (>=1000) when HNSW index is available

  ## Examples

      determine_strategy(100, nil)    #=> :exact
      determine_strategy(500, nil)    #=> :binary_rescore
      determine_strategy(1000, nil)   #=> :hnsw (if available)
      determine_strategy(100, :hnsw)  #=> :hnsw (explicit override)
  """
  def determine_strategy(count, explicit_strategy) when is_integer(count) do
    do_determine_strategy(count, explicit_strategy)
  end

  # Explicit strategy override - use it directly
  defp do_determine_strategy(_count, strategy) when strategy in [:exact, :binary_rescore, :hnsw] do
    strategy
  end

  # Auto-select based on count thresholds
  defp do_determine_strategy(count, _) when count >= @hnsw_search_threshold do
    if hnsw_available?(), do: :hnsw, else: :binary_rescore
  end

  defp do_determine_strategy(count, _) when count >= @binary_search_threshold do
    :binary_rescore
  end

  defp do_determine_strategy(_count, _), do: :exact

  # Check if HNSW index is available
  defp hnsw_available? do
    HnswIndex.should_use_hnsw?()
  rescue
    _ -> false
  end

  @doc """
  Store a new memory with its embedding.
  Includes validation and ACID transaction guarantees.
  Uses retry strategy for transient database failures.

  ## Options

    * `:importance` - Importance score 0-1 (default: 0.5)

  ## Examples

      persist_memory("User prefers dark mode", "observation")
      persist_memory("API key rotated", "action", importance: 0.9)
  """
  def persist_memory(content, category, importance \\ 0.5) do
    persist_memory(content, category, importance, [])
  end

  def persist_memory(content, category, importance, opts) when is_list(opts) do
    # SPEC-STABILITY: Generate embedding OUTSIDE the WriteSerializer transaction
    # Embedding generation calls Ollama (network I/O) and can take 5-10 seconds.
    # If we hold the WriteSerializer lock during this time, other writes will fail
    # with "Database busy" errors.
    category_str = to_string(category)

    with :ok <- validate_content_size(content),
         :ok <- validate_content_quality(content),
         {:ok, embedding} <- generate_embedding(content),
         :ok <- validate_embedding_dimension(embedding) do
      # Now that we have the embedding, enter the fast path inside WriteSerializer
      do_persist_with_embedding(content, category_str, importance, embedding, opts)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Fast path: embedding already generated, just do the DB insert
  defp do_persist_with_embedding(content, category_str, importance, embedding, opts) do
    try do
      Mimo.Brain.WriteSerializer.transaction(fn ->
        RetryStrategies.with_sqlite_retry(
          fn ->
            do_persist_memory_with_tmc_and_embedding(
              content,
              category_str,
              importance,
              embedding,
              opts
            )
          end,
          max_retries: 3,
          base_delay: 200,
          on_retry: fn attempt, reason ->
            Logger.warning("Memory persist retry #{attempt}: #{inspect(reason)}")
          end
        )
      end)
      |> case do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    rescue
      _ ->
        # Fallback to direct call if WriteSerializer unavailable
        RetryStrategies.with_sqlite_retry(
          fn ->
            do_persist_memory_with_tmc_and_embedding(
              content,
              category_str,
              importance,
              embedding,
              opts
            )
          end,
          max_retries: 5,
          base_delay: 500,
          on_retry: fn attempt, reason ->
            Logger.warning("Memory persist retry (fallback) #{attempt}: #{inspect(reason)}")
          end
        )
    end
  end

  # SPEC-034: TMC-aware persistence with pre-generated embedding
  # SPEC-STABILITY: This version takes embedding as parameter to avoid slow network I/O
  # inside the WriteSerializer transaction lock.
  defp do_persist_memory_with_tmc_and_embedding(content, category_str, importance, embedding, opts) do
    # Classify the content using NoveltyDetector (uses the pre-generated embedding)
    case NoveltyDetector.classify_with_embedding(content, category_str, embedding) do
      {:new, []} ->
        # No similar memories (or TMC disabled) - proceed with normal persistence
        do_persist_memory_fast(content, category_str, importance, embedding, opts)

      {:redundant, existing} ->
        # Near-duplicate found - reinforce existing memory
        Logger.debug("TMC: Redundant memory detected, reinforcing existing ##{existing.id}")
        _result = MemoryIntegrator.execute(:redundant, content, existing, importance: importance)
        {:ok, existing.id}

      {:ambiguous, similar_memories} ->
        # Similar memories found - ask LLM to decide
        [best_match | _] = similar_memories
        target = best_match.engram

        Logger.debug(
          "TMC: Ambiguous case with #{length(similar_memories)} similar memories, deciding for ##{target.id}"
        )

        {:ok, %{decision: decision}} =
          MemoryIntegrator.decide(content, target, category: category_str, importance: importance)

        Logger.debug("TMC: LLM decided #{decision} for target ##{target.id}")

        case MemoryIntegrator.execute(decision, content, target,
               category: category_str,
               importance: importance
             ) do
          {:ok, :skipped} ->
            {:ok, target.id}

          {:ok, %Engram{id: id}} ->
            {:ok, id}

          {:ok, :new} ->
            do_persist_memory_fast(content, category_str, importance, embedding, opts)

          {:error, _} = error ->
            error
        end
    end
  rescue
    # If NoveltyDetector.classify_with_embedding doesn't exist, fall back to simple insert
    UndefinedFunctionError ->
      do_persist_memory_fast(content, category_str, importance, embedding, opts)
  end

  # SPEC-STABILITY: Fast insert path with pre-computed embedding
  # No embedding generation, no duplicate check (already validated by caller)
  defp do_persist_memory_fast(content, category_str, importance, embedding, opts) do
    project_id = LLM.detect_project(content)
    tags = auto_generate_tags(content)
    valid_from = Keyword.get(opts, :valid_from)
    valid_until = Keyword.get(opts, :valid_until)
    validity_source = Keyword.get(opts, :validity_source)

    # SPEC-031: Quantize to int8 for efficient storage
    {embedding_to_store, quantized_attrs} = quantize_embedding_for_storage(embedding)

    changeset =
      Engram.changeset(
        %Engram{},
        Map.merge(
          %{
            content: content,
            category: category_str,
            importance: importance,
            embedding: embedding_to_store,
            project_id: project_id,
            tags: tags,
            valid_from: valid_from,
            valid_until: valid_until,
            validity_source: validity_source
          },
          quantized_attrs
        )
      )

    case Repo.insert(changeset) do
      {:ok, engram} ->
        log_memory_event(:stored, engram.id, category_str, project_id, tags)
        # SPEC-STABILITY: Spawn post-insert hooks as async tasks to avoid
        # holding DB connections during the WriteSerializer transaction.
        # These hooks may do their own DB writes which would cause "Database busy"
        spawn(fn ->
          notify_memory_stored(engram)
          AwakeningHooks.memory_stored(engram)
          maybe_auto_protect(engram, importance)
        end)

        {:ok, engram.id}

      {:error, changeset} ->
        {:error, changeset.errors}
    end
  end

  # SPEC-034: TMC-aware persistence
  defp reasoning_memory_enabled? do
    Application.get_env(:mimo, :reasoning_memory_enabled, false)
  end

  @doc """
  Store multiple memories atomically.
  All memories are stored or none are (transaction).
  """
  def persist_memories(memories) when is_list(memories) do
    # SPEC-STABILITY: Wrap in WriteSerializer to serialize SQLite writes
    Mimo.Brain.WriteSerializer.transaction(fn ->
      do_persist_memories(memories, [])
    end)
  end

  # Process memories recursively, collecting IDs
  defp do_persist_memories([], acc), do: {:ok, Enum.reverse(acc)}

  defp do_persist_memories([memory | rest], acc) do
    content = Map.get(memory, :content) || Map.get(memory, "content")
    category = Map.get(memory, :category) || Map.get(memory, "category", "fact")
    importance = Map.get(memory, :importance) || Map.get(memory, "importance", 0.5)

    with :ok <- validate_content_size(content),
         {:ok, embedding} <- generate_embedding(content),
         :ok <- validate_embedding_dimension(embedding) do
      # SPEC-031 + SPEC-033: Quantize to int8 and binary
      {embedding_to_store, quantized_attrs} = quantize_embedding_for_storage(embedding)

      changeset =
        Engram.changeset(
          %Engram{},
          Map.merge(
            %{
              content: content,
              category: category,
              importance: importance,
              embedding: embedding_to_store
            },
            quantized_attrs
          )
        )

      case Repo.insert(changeset) do
        {:ok, engram} -> do_persist_memories(rest, [engram.id | acc])
        {:error, changeset} -> {:error, {:insert_failed, changeset.errors}}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Clean up old, low-importance memories.
  """
  def cleanup_old(days_old) do
    cutoff = DateTime.add(DateTime.utc_now(), -days_old * 24 * 60 * 60, :second)

    {count, _} =
      Repo.delete_all(
        from(e in Engram,
          where: e.inserted_at < ^cutoff and e.importance < 0.5
        )
      )

    Logger.info("Cleaned up #{count} old memories")
    {:ok, count}
  end

  @doc """
  Get memory count for monitoring.
  """
  def count do
    Repo.one(from(e in Engram, select: count(e.id)))
  end

  @doc """
  Alias for persist_memory - store a memory with metadata.
  Used by SemanticStore.Resolver for entity anchors.
  """
  def store(attrs) when is_map(attrs) do
    content = attrs[:content] || attrs["content"]
    type = attrs[:type] || attrs["type"] || "fact"
    ref = attrs[:ref] || attrs["ref"]
    metadata = attrs[:metadata] || attrs["metadata"] || %{}
    importance = attrs[:importance] || attrs["importance"] || 0.8

    # SPEC-105: Apply emotional salience scoring
    # Boost importance for emotionally charged content
    {final_importance, final_metadata} =
      case EmotionalScorer.score(content || "") do
        {:ok, %{importance_boost: boost, score: emotional_score}} when boost > 0 ->
          boosted = min(1.0, importance + boost)
          enhanced_meta = Map.put(metadata, "emotional_score", emotional_score)
          {boosted, enhanced_meta}

        _ ->
          {importance, metadata}
      end

    # Q1 2026 Phase 3: Auto-inject session tagging from process context
    # This enables multi-agent session isolation and filtering
    enhanced_metadata = inject_session_context(final_metadata)

    # SPEC-STABILITY: Wrap in WriteSerializer to serialize SQLite writes
    # This prevents "Database busy" errors under concurrent load
    Mimo.Brain.WriteSerializer.transaction(fn ->
      persist_memory_with_metadata(content, type, ref, enhanced_metadata, final_importance)
    end)
  end

  # Inject session context into memory metadata.
  # Automatically captures agent type, session ID, and other context
  # from the process dictionary. This enables:
  # - Session-level memory isolation
  # - Agent-specific memory filtering
  # - Multi-agent collaboration tracking
  #
  # The process dictionary keys used:
  # - :mimo_session_id - Unique session identifier
  # - :mimo_agent_type - Agent type (e.g., "mimo-cognitive-agent")
  # - :mimo_model_id - Model identifier (e.g., "claude-opus-4")
  defp inject_session_context(metadata) when is_map(metadata) do
    session_context = %{}

    # Capture session ID if present
    session_context =
      case Process.get(:mimo_session_id) do
        nil -> session_context
        session_id -> Map.put(session_context, "session_id", session_id)
      end

    # Capture agent type if present
    session_context =
      case Process.get(:mimo_agent_type) do
        nil -> session_context
        agent_type -> Map.put(session_context, "agent_type", agent_type)
      end

    # Capture model ID if present
    session_context =
      case Process.get(:mimo_model_id) do
        nil -> session_context
        model_id -> Map.put(session_context, "model_id", model_id)
      end

    # Merge with existing metadata (existing metadata takes precedence)
    Map.merge(session_context, metadata)
  end

  defp inject_session_context(metadata), do: metadata

  # SPEC-STABILITY: This function is called inside WriteSerializer.transaction
  # which already wraps with Repo.transaction. DO NOT add another Repo.transaction.
  defp persist_memory_with_metadata(content, type, ref, metadata, importance) do
    with :ok <- validate_content_size(content),
         :ok <- validate_content_quality(content),
         {:ok, embedding} <- generate_embedding(content),
         :ok <- validate_embedding_dimension(embedding) do
      # SPEC-031 + SPEC-033: Quantize to int8 and binary
      {embedding_to_store, quantized_attrs} =
        case Math.quantize_int8(embedding) do
          {:ok, {int8_binary, scale, offset}} ->
            binary_attrs =
              case Math.int8_to_binary(int8_binary) do
                {:ok, binary} -> %{embedding_binary: binary}
                {:error, _} -> %{}
              end

            {[],
             Map.merge(
               %{
                 embedding_int8: int8_binary,
                 embedding_scale: scale,
                 embedding_offset: offset
               },
               binary_attrs
             )}

          {:error, _reason} ->
            {embedding, %{}}
        end

      # Auto-protect high-importance and entity_anchor memories
      # This ensures valuable memories are never deleted by Forgetting
      auto_protected = importance >= 0.8 or type == "entity_anchor"

      changeset =
        Engram.changeset(
          %Engram{},
          Map.merge(
            %{
              content: content,
              category: type,
              importance: importance,
              embedding: embedding_to_store,
              protected: auto_protected,
              metadata: Map.merge(metadata, %{"ref" => ref, "type" => type})
            },
            quantized_attrs
          )
        )

      case Repo.insert(changeset) do
        {:ok, engram} ->
          # Auto-link memory to knowledge graph (async, fire-and-forget)
          spawn(fn -> maybe_auto_link_memory(engram.id, content) end)
          {:ok, engram.id}

        {:error, changeset} ->
          {:error, changeset.errors}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    type_filter = Keyword.get(opts, :type)
    min_similarity = Keyword.get(opts, :min_similarity, 0.3)
    enable_reasoning = Keyword.get(opts, :enable_reasoning, false)
    rerank = Keyword.get(opts, :rerank, false)

    # SPEC-058: Optional query analysis with reasoning
    {search_query, query_analysis, enhanced_opts} =
      maybe_analyze_query(query, opts, enable_reasoning)

    results =
      search_memories(search_query,
        limit: limit * 2,
        min_similarity: min_similarity,
        time_filter: Keyword.get(enhanced_opts, :time_filter)
      )

    results
    |> maybe_filter_by_type(type_filter)
    |> maybe_rerank(query, query_analysis, rerank)
    |> Enum.take(limit)
    |> Enum.map(&add_score_field/1)
    |> then(&{:ok, &1})
  end

  # SPEC-058: Query analysis with reasoning (if enabled)
  defp maybe_analyze_query(query, opts, false), do: {query, %{}, opts}

  defp maybe_analyze_query(query, opts, true) do
    if reasoning_memory_enabled?() do
      do_analyze_query(query, opts)
    else
      {query, %{}, opts}
    end
  end

  defp do_analyze_query(query, opts) do
    case ReasoningBridge.analyze_query(query) do
      {:ok, analysis} ->
        expanded_query = expand_query_terms(query, analysis["expanded_terms"])
        enhanced_opts = apply_time_filter(opts, analysis["time_context"])
        {expanded_query, analysis, enhanced_opts}

      _ ->
        {query, %{}, opts}
    end
  end

  defp expand_query_terms(query, terms) when is_list(terms) and terms != [] do
    [query | terms] |> Enum.join(" ")
  end

  defp expand_query_terms(query, _), do: query

  defp apply_time_filter(opts, nil), do: opts
  defp apply_time_filter(opts, time_ctx), do: Keyword.put(opts, :time_filter, time_ctx)

  defp maybe_filter_by_type(results, nil), do: results

  defp maybe_filter_by_type(results, type_filter) do
    Enum.filter(results, fn r ->
      r[:category] == type_filter or r[:metadata]["type"] == type_filter
    end)
  end

  defp maybe_rerank(results, _query, _analysis, false), do: results
  defp maybe_rerank(results, _query, _analysis, true) when length(results) <= 3, do: results

  defp maybe_rerank(results, query, query_analysis, true) do
    if reasoning_memory_enabled?() do
      do_rerank(results, query, query_analysis)
    else
      results
    end
  end

  defp do_rerank(results, query, query_analysis) do
    engram_like = Enum.map(results, fn r -> %Engram{id: r[:id], content: r[:content]} end)
    reranked = ReasoningBridge.rerank(query, engram_like, query_analysis)
    reranked_ids = Enum.map(reranked, & &1.id)

    Enum.sort_by(results, fn r ->
      case Enum.find_index(reranked_ids, &(&1 == r[:id])) do
        nil -> 999
        idx -> idx
      end
    end)
  end

  defp add_score_field(result) do
    Map.put(result, :score, result[:similarity] || 0.0)
  end

  @doc """
  Get a single memory by ID.
  """
  def get_memory(id) do
    case Repo.get(Engram, id) do
      nil -> {:error, :not_found}
      engram -> {:ok, engram}
    end
  end

  @doc """
  Update memory importance.
  """
  def update_importance(id, importance)
      when is_number(importance) and importance >= 0 and importance <= 1 do
    case Repo.get(Engram, id) do
      nil ->
        {:error, :not_found}

      engram ->
        changeset = Engram.changeset(engram, %{importance: importance})
        Repo.update(changeset)
    end
  end

  @doc """
  Get recent memories ordered by insertion time.
  Used by hybrid retrieval for recency-weighted search.

  ## Options

    * `:limit` - Maximum results (default: 10)
    * `:category` - Filter by category
  """
  def get_recent(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    category = Keyword.get(opts, :category)

    query =
      from(e in Engram,
        order_by: [desc: e.inserted_at],
        limit: ^limit,
        select: %{
          id: e.id,
          content: e.content,
          category: e.category,
          importance: e.importance,
          access_count: e.access_count,
          last_accessed_at: e.last_accessed_at,
          decay_rate: e.decay_rate,
          protected: e.protected,
          metadata: e.metadata,
          embedding: e.embedding,
          inserted_at: e.inserted_at
        }
      )

    query =
      if category do
        from(e in query, where: e.category == ^category)
      else
        query
      end

    {:ok, Repo.all(query)}
  rescue
    e ->
      Logger.error("Get recent failed: #{Exception.message(e)}")
      {:error, e}
  end

  @doc """
  Alias for get_recent/1 - returns recent engrams for Awakening integration.
  """
  @spec recent_engrams(non_neg_integer()) :: {:ok, list()} | {:error, term()}
  def recent_engrams(limit \\ 10) do
    get_recent(limit: limit)
  end

  @doc """
  Persist a memory with full metadata and embedding.
  Used by Consolidator for working memory → long-term transfer.

  ## Parameters

    * `content` - Memory content
    * `category` - Memory category
    * `importance` - Importance score (0-1)
    * `embedding` - Pre-computed embedding vector (optional)
    * `metadata` - Additional metadata map
  """
  def persist_memory(content, category, importance, embedding, metadata \\ %{}) do
    # SPEC-STABILITY: Wrap in WriteSerializer to serialize SQLite writes
    # Note: WriteSerializer.transaction uses Repo.transaction internally,
    # which wraps results as {:ok, inner_result} or {:error, reason}.
    # We need to unwrap this to maintain the original API contract.
    case Mimo.Brain.WriteSerializer.transaction(fn ->
           RetryStrategies.with_retry(
             fn -> do_persist_memory_full(content, category, importance, embedding, metadata) end,
             max_retries: 3,
             base_delay: 100,
             on_retry: fn attempt, reason ->
               Logger.warning("Memory persist retry #{attempt}: #{inspect(reason)}")
             end
           )
         end) do
      # Unwrap the Repo.transaction wrapping
      {:ok, {:ok, engram}} -> {:ok, engram}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
      other -> other
    end
  end

  @doc """
  SPEC-099: Batch store multiple memories efficiently.

  This function batches embedding generation and database inserts for
  significantly improved performance when storing multiple memories.

  Performance comparison (100 memories):
  - Sequential: 100 × (200ms embed + 50ms db) = ~25 seconds
  - Batched:    1 × (500ms batch embed) + 1 × (100ms batch insert) = ~600ms

  ## Parameters

    * `memories` - List of memory maps with required keys:
      * `:content` - Memory content (required)
      * `:category` - Memory category (required)
      * `:importance` - Importance score (default: 0.5)
      * `:metadata` - Additional metadata (default: %{})
    * `opts` - Options
      * `:batch_size` - Max embeddings per batch (default: 100)

  ## Returns

      {:ok, %{stored: count, ids: [id], failed: count}}
      {:error, reason}
  """
  @spec store_batch([map()], keyword()) :: {:ok, map()} | {:error, term()}
  def store_batch(memories, opts \\ []) when is_list(memories) do
    if Enum.empty?(memories) do
      {:ok, %{stored: 0, ids: [], failed: 0}}
    else
      batch_size = Keyword.get(opts, :batch_size, 100)
      do_store_batch(memories, batch_size)
    end
  end

  defp do_store_batch(memories, batch_size) do
    # Phase 1: Validate all content upfront
    case validate_batch_content(memories) do
      {:error, reason} ->
        {:error, reason}

      :ok ->
        # Phase 2: Batch generate embeddings
        contents = Enum.map(memories, & &1[:content])

        case batch_generate_embeddings(contents, batch_size) do
          {:error, reason} ->
            {:error, {:embedding_failed, reason}}

          {:ok, embeddings} ->
            # Phase 3: Prepare and batch insert
            now = NaiveDateTime.utc_now()

            entries =
              memories
              |> Enum.zip(embeddings)
              |> Enum.map(fn {memory, embedding} ->
                prepare_batch_entry(memory, embedding, now)
              end)
              |> Enum.filter(&(&1 != nil))

            # Phase 4: Batch insert via WriteSerializer
            case batch_insert_entries(entries) do
              {:ok, inserted_ids} ->
                # Phase 5: Add to HNSW index in batch
                batch_add_to_index(entries, inserted_ids)

                {:ok,
                 %{
                   stored: length(inserted_ids),
                   ids: inserted_ids,
                   failed: length(memories) - length(inserted_ids)
                 }}

              {:error, reason} ->
                {:error, {:insert_failed, reason}}
            end
        end
    end
  end

  defp validate_batch_content(memories) do
    Enum.reduce_while(memories, :ok, fn memory, _acc ->
      content = memory[:content]

      cond do
        is_nil(content) ->
          {:halt, {:error, :missing_content}}

        not is_binary(content) ->
          {:halt, {:error, :invalid_content_type}}

        byte_size(content) > @max_content_size ->
          {:halt, {:error, :content_too_large}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp batch_generate_embeddings(contents, batch_size) do
    # Split into batches to avoid overloading embedding API
    contents
    |> Enum.chunk_every(batch_size)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc_embeddings} ->
      case EmbeddingManager.generate_batch(batch) do
        {:ok, embeddings, _provider} ->
          {:cont, {:ok, acc_embeddings ++ embeddings}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp prepare_batch_entry(memory, embedding, now) do
    category = to_string(memory[:category] || "fact")
    importance = memory[:importance] || 0.5
    metadata = memory[:metadata] || %{}
    content = memory[:content]

    # Quantize embedding
    {_embedding_to_store, quantized_attrs} = quantize_embedding_for_storage(embedding)

    # Build base entry (without :id which is auto-generated)
    base = %{
      content: content,
      category: category,
      importance: importance,
      metadata: metadata,
      last_accessed_at: now,
      inserted_at: now,
      updated_at: now
    }

    # Merge quantized attributes
    Map.merge(base, quantized_attrs)
  end

  defp batch_insert_entries(entries) do
    Mimo.Brain.WriteSerializer.transaction(fn ->
      case Repo.insert_all(Engram, entries, returning: [:id]) do
        {count, returned} when count > 0 ->
          ids = Enum.map(returned, & &1.id)
          {:ok, ids}

        {0, _} ->
          {:ok, []}
      end
    end)
    |> case do
      {:ok, {:ok, ids}} -> {:ok, ids}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp batch_add_to_index(entries, ids) do
    # Prepare vectors for HNSW
    vectors =
      entries
      |> Enum.zip(ids)
      |> Enum.filter(fn {entry, _id} ->
        Map.has_key?(entry, :embedding_int8) and entry.embedding_int8 != nil
      end)
      |> Enum.map(fn {entry, id} ->
        {id, entry.embedding_int8}
      end)

    if length(vectors) > 0 do
      HnswIndex.add_batch(vectors)
    end

    :ok
  rescue
    # HNSW might not be running in tests
    _ -> :ok
  end

  # SPEC-STABILITY: This function is called inside WriteSerializer.transaction
  # which already wraps with Repo.transaction. DO NOT add another Repo.transaction.
  defp do_persist_memory_full(content, category, importance, embedding, metadata) do
    # Ensure category is a string for Ecto
    category_str = to_string(category)

    with :ok <- validate_content_size(content),
         {:ok, final_embedding} <- resolve_embedding(content, embedding) do
      # SPEC-031 + SPEC-033: Quantize to int8 and binary
      {embedding_to_store, quantized_attrs} = quantize_embedding_for_storage(final_embedding)

      changeset =
        Engram.changeset(
          %Engram{},
          Map.merge(
            %{
              content: content,
              category: category_str,
              importance: importance,
              embedding: embedding_to_store,
              metadata: metadata,
              last_accessed_at: NaiveDateTime.utc_now()
            },
            quantized_attrs
          )
        )

      case Repo.insert(changeset) do
        {:ok, engram} ->
          log_memory_event(:stored, engram.id, category_str)
          notify_memory_stored(engram)
          AwakeningHooks.memory_stored(engram)
          {:ok, engram}

        {:error, changeset} ->
          {:error, changeset.errors}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Resolve embedding - use provided or generate new
  defp resolve_embedding(_content, emb) when is_list(emb) and emb != [], do: {:ok, emb}

  defp resolve_embedding(content, _) do
    case generate_embedding(content) do
      {:ok, emb} when is_list(emb) and emb != [] ->
        {:ok, emb}

      {:ok, []} ->
        Logger.warning("Embedding generation returned empty list for content")
        {:error, {:empty_embedding, "Embedding generation returned empty result"}}

      {:error, reason} ->
        Logger.warning("Embedding generation failed: #{inspect(reason)}")
        {:error, {:embedding_failed, reason}}
    end
  end

  # Determine which search strategy to use (internal)
  defp select_strategy(:auto, opts) do
    category = Keyword.get(opts, :category)

    # OPTIMIZATION: For category-specific searches, use exact search with SQL pre-filtering.
    # This guarantees correct results (no post-filter false negatives).
    # All categories are currently < 10K (verified: largest is fact=3,424).
    # exact_search with category filter takes ~30ms (verified via SQLite timing).
    # See: docs/specs/MEMORY_SCALABILITY_MASTER_PLAN.md
    if category != nil do
      :exact
    else
      # No category filter - use HNSW for full corpus search if available
      if HnswIndex.should_use_hnsw?() do
        :hnsw
      else
        # HNSW not available, check binary embedding counts
        count =
          Repo.one(
            from(e in Engram,
              where: not is_nil(e.embedding_binary),
              select: count(e.id)
            )
          ) || 0

        cond do
          count >= @hnsw_search_threshold -> :binary_rescore
          count >= @binary_search_threshold -> :binary_rescore
          true -> :exact
        end
      end
    end
  rescue
    # If HnswIndex GenServer isn't running, fall back to other strategies
    _ -> select_strategy_without_hnsw(opts)
  end

  defp select_strategy(strategy, _opts) when strategy in [:exact, :binary_rescore, :hnsw] do
    strategy
  end

  defp select_strategy(_, opts), do: select_strategy_without_hnsw(opts)

  # Fallback strategy selection when HNSW is not available
  defp select_strategy_without_hnsw(opts) do
    category = Keyword.get(opts, :category)
    # Convert atom category to string for database query
    category_str = if is_atom(category) and category != nil, do: to_string(category), else: category

    count =
      if category_str do
        Repo.one(
          from(e in Engram,
            where: e.category == ^category_str and not is_nil(e.embedding_binary),
            select: count(e.id)
          )
        ) || 0
      else
        Repo.one(
          from(e in Engram,
            where: not is_nil(e.embedding_binary),
            select: count(e.id)
          )
        ) || 0
      end

    if count >= @binary_search_threshold, do: :binary_rescore, else: :exact
  end

  @doc """
  HNSW search: O(log n) approximate nearest neighbor search.

  Uses the HNSW index for very fast search on large memory stores.
  Falls back to binary_rescore if HNSW search fails.
  """
  def hnsw_search(query_int8, limit, min_similarity, recency_boost, opts) do
    include_superseded = Keyword.get(opts, :include_superseded, false)

    case HnswIndex.search(query_int8, limit * @candidates_multiplier) do
      {:ok, results} when results != [] ->
        # Convert HNSW results to our format with full metadata
        candidate_ids = Enum.map(results, fn {key, _distance} -> key end)

        # Fetch full engram data and rescore with recency if needed
        rescore_hnsw_candidates(
          candidate_ids,
          query_int8,
          limit,
          min_similarity,
          recency_boost,
          include_superseded
        )

      {:ok, []} ->
        # No results from HNSW, try two-stage search
        Logger.debug("HNSW returned no results, falling back to binary_rescore")
        two_stage_search_fallback(query_int8, limit, min_similarity, recency_boost, opts)

      {:error, :not_initialized} ->
        Logger.debug("HNSW index not initialized, falling back to binary_rescore")
        two_stage_search_fallback(query_int8, limit, min_similarity, recency_boost, opts)

      {:error, :below_threshold} ->
        # Not enough vectors for HNSW, use binary_rescore
        two_stage_search_fallback(query_int8, limit, min_similarity, recency_boost, opts)

      {:error, reason} ->
        Logger.warning("HNSW search failed: #{inspect(reason)}, falling back")
        two_stage_search_fallback(query_int8, limit, min_similarity, recency_boost, opts)
    end
  end

  # Rescore HNSW candidates with accurate similarity and recency
  defp rescore_hnsw_candidates(
         candidate_ids,
         query_int8,
         limit,
         min_similarity,
         recency_boost,
         include_superseded
       ) do
    now = DateTime.utc_now()

    # Fetch candidate engrams with their metadata
    base_query =
      from(e in Engram,
        where: e.id in ^candidate_ids,
        select: %{
          id: e.id,
          content: e.content,
          category: e.category,
          importance: e.importance,
          metadata: e.metadata,
          embedding_int8: e.embedding_int8,
          inserted_at: e.inserted_at,
          access_count: e.access_count,
          last_accessed_at: e.last_accessed_at,
          decay_rate: e.decay_rate,
          protected: e.protected
        }
      )

    candidates =
      base_query
      |> maybe_filter_superseded(include_superseded)
      |> maybe_filter_archived(false)
      |> Repo.all()

    # Score each candidate with int8 cosine similarity (for accurate similarity value)
    candidates
    |> Enum.map(fn engram ->
      similarity =
        case engram.embedding_int8 do
          nil ->
            0.0

          int8 when byte_size(int8) > 0 ->
            case Math.cosine_similarity_int8(query_int8, int8) do
              {:ok, sim} -> sim
              {:error, _} -> 0.0
            end

          _ ->
            0.0
        end

      recency_score = calculate_recency_score(engram.inserted_at, now)

      score =
        if recency_boost > 0 do
          (1.0 - recency_boost) * similarity + recency_boost * recency_score
        else
          similarity
        end

      %{
        id: engram.id,
        content: engram.content,
        category: engram.category,
        importance: engram.importance,
        metadata: engram.metadata || %{},
        inserted_at: engram.inserted_at,
        similarity: similarity,
        recency_score: recency_score,
        score: score
      }
    end)
    |> Enum.filter(fn %{similarity: sim} -> sim >= min_similarity end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
  end

  # Fallback when HNSW isn't available
  defp two_stage_search_fallback(query_int8, limit, min_similarity, recency_boost, opts) do
    # Dequantize int8 to float to enable binary pre-filtering
    # This adds some overhead but maintains O(n) vs O(n²) advantage of binary search
    case Math.dequantize_int8(query_int8, 1.0, 0.0) do
      {:ok, query_float} ->
        # Use two_stage_search which has binary pre-filtering
        two_stage_search(query_float, query_int8, limit, min_similarity, recency_boost, opts)

      {:error, _reason} ->
        # Only fall back to exact search if dequantization fails
        exact_search(query_int8, limit, min_similarity, recency_boost, opts)
    end
  end

  @doc """
  Two-stage search: Binary pre-filter → Int8 rescore.

  Stage 1: Fast Hamming distance on binary embeddings to get candidates
  Stage 2: Accurate int8 cosine similarity to rescore and rank
  """
  def two_stage_search(query_float, query_int8, limit, min_similarity, recency_boost, opts) do
    candidates = limit * @candidates_multiplier
    category = Keyword.get(opts, :category)
    project_id = Keyword.get(opts, :project_id)
    include_superseded = Keyword.get(opts, :include_superseded, false)

    # Generate binary embedding from float query
    case Math.to_binary(query_float) do
      {:ok, query_binary} ->
        # Stage 1: Get candidates via Hamming distance
        candidate_ids =
          hamming_prefilter(query_binary, candidates, category, project_id, include_superseded)

        if candidate_ids == [] do
          # Fallback to exact search if no candidates
          exact_search(query_int8, limit, min_similarity, recency_boost, opts)
        else
          # Stage 2: Rescore candidates with int8 cosine
          rescore_candidates(candidate_ids, query_int8, limit, min_similarity, recency_boost)
        end

      {:error, _reason} ->
        # Fallback to exact search
        exact_search(query_int8, limit, min_similarity, recency_boost, opts)
    end
  end

  # Maximum embeddings to load per batch to prevent OOM
  @hamming_batch_size 10_000

  # Stage 1: Fast Hamming pre-filter with chunked loading for memory safety
  defp hamming_prefilter(query_binary, candidates, category, project_id, include_superseded) do
    # Build base query for binary embeddings
    # Note: Use select_merge with map for subquery compatibility
    base_query =
      from(e in Engram,
        where: not is_nil(e.embedding_binary),
        select: %{id: e.id, embedding_binary: e.embedding_binary}
      )

    query =
      base_query
      |> maybe_filter_category(category)
      |> maybe_filter_project(project_id)
      |> maybe_filter_superseded(include_superseded)
      |> maybe_filter_archived(false)

    # Get total count using a separate count query
    count_query =
      from(e in Engram,
        where: not is_nil(e.embedding_binary)
      )
      |> maybe_filter_category(category)
      |> maybe_filter_project(project_id)
      |> maybe_filter_superseded(include_superseded)
      |> maybe_filter_archived(false)
      |> select([e], count(e.id))

    total_count = Repo.one(count_query) || 0

    if total_count == 0 do
      []
    else
      if total_count <= @hamming_batch_size do
        # Small enough to process in one batch
        engrams = Repo.all(query)
        # Convert map results to tuples for compatibility
        engram_tuples = Enum.map(engrams, fn %{id: id, embedding_binary: eb} -> {id, eb} end)
        process_hamming_batch(query_binary, engram_tuples, candidates)
      else
        # Process in chunks to prevent OOM, merge top candidates
        process_hamming_chunked(query, query_binary, candidates, total_count)
      end
    end
  end

  # Process all embeddings when count is small
  defp process_hamming_batch(query_binary, engrams, candidates) do
    # Build corpus and ID map
    {corpus, id_map} =
      Enum.reduce(engrams, {[], %{}}, fn {id, binary}, {corpus_acc, map_acc} ->
        idx = length(corpus_acc)
        {corpus_acc ++ [binary], Map.put(map_acc, idx, id)}
      end)

    # Fast Hamming search using NIF
    case Math.top_k_hamming(query_binary, corpus, candidates) do
      {:ok, results} ->
        Enum.map(results, fn {idx, _distance} -> Map.get(id_map, idx) end)
        |> Enum.reject(&is_nil/1)

      {:error, _reason} ->
        # Return all IDs on error (will be rescored anyway)
        Enum.map(engrams, fn {id, _} -> id end)
    end
  end

  # Process in chunks when memory store is large
  defp process_hamming_chunked(query, query_binary, candidates, total_count) do
    num_chunks = div(total_count, @hamming_batch_size) + 1
    candidates_per_chunk = max(div(candidates, num_chunks) * 2, 100)

    # Process each chunk and collect top candidates
    all_results =
      0..(num_chunks - 1)
      |> Enum.flat_map(&process_single_chunk(&1, query, query_binary, candidates_per_chunk))

    # Sort by distance and take top candidates globally
    all_results
    |> Enum.sort_by(fn {_id, distance} -> distance end)
    |> Enum.take(candidates)
    |> Enum.map(fn {id, _} -> id end)
  end

  defp process_single_chunk(chunk_idx, query, query_binary, candidates_per_chunk) do
    offset = chunk_idx * @hamming_batch_size
    chunk_query = from(q in subquery(query), limit: ^@hamming_batch_size, offset: ^offset)
    engrams = Repo.all(chunk_query)

    if engrams == [],
      do: [],
      else: hamming_search_chunk(engrams, query_binary, candidates_per_chunk)
  end

  defp hamming_search_chunk(engrams, query_binary, candidates_per_chunk) do
    {corpus, id_map} = build_corpus_and_id_map(engrams)

    case Math.top_k_hamming(query_binary, corpus, candidates_per_chunk) do
      {:ok, results} ->
        results
        |> Enum.map(fn {idx, distance} -> {Map.get(id_map, idx), distance} end)
        |> Enum.reject(fn {id, _} -> is_nil(id) end)

      {:error, _} ->
        engrams |> Enum.take(candidates_per_chunk) |> Enum.map(fn %{id: id} -> {id, 256} end)
    end
  end

  defp build_corpus_and_id_map(engrams) do
    Enum.reduce(engrams, {[], %{}}, fn %{id: id, embedding_binary: binary}, {corpus_acc, map_acc} ->
      idx = length(corpus_acc)
      {corpus_acc ++ [binary], Map.put(map_acc, idx, id)}
    end)
  end

  # Stage 2: Int8 rescore on candidates
  defp rescore_candidates(candidate_ids, query_int8, limit, min_similarity, recency_boost) do
    now = DateTime.utc_now()

    # Fetch candidate engrams with their int8 embeddings
    candidates =
      from(e in Engram,
        where: e.id in ^candidate_ids,
        select: %{
          id: e.id,
          content: e.content,
          category: e.category,
          importance: e.importance,
          metadata: e.metadata,
          embedding_int8: e.embedding_int8,
          inserted_at: e.inserted_at,
          access_count: e.access_count,
          last_accessed_at: e.last_accessed_at,
          decay_rate: e.decay_rate,
          protected: e.protected
        }
      )
      |> Repo.all()

    # Score each candidate with int8 cosine similarity
    candidates
    |> Enum.map(fn engram ->
      similarity =
        case engram.embedding_int8 do
          nil ->
            0.0

          int8 when byte_size(int8) > 0 ->
            case Math.cosine_similarity_int8(query_int8, int8) do
              {:ok, sim} -> sim
              {:error, _} -> 0.0
            end

          _ ->
            0.0
        end

      recency_score = calculate_recency_score(engram.inserted_at, now)

      score =
        if recency_boost > 0 do
          (1.0 - recency_boost) * similarity + recency_boost * recency_score
        else
          similarity
        end

      %{
        id: engram.id,
        content: engram.content,
        category: engram.category,
        importance: engram.importance,
        metadata: engram.metadata || %{},
        inserted_at: engram.inserted_at,
        similarity: similarity,
        recency_score: recency_score,
        score: score
      }
    end)
    |> Enum.filter(fn %{similarity: sim} -> sim >= min_similarity end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
  end

  # Exact search using int8 embeddings (O(n) but accurate)
  defp exact_search(query_int8, limit, min_similarity, recency_boost, opts) do
    category = Keyword.get(opts, :category)
    project_id = Keyword.get(opts, :project_id)
    include_superseded = Keyword.get(opts, :include_superseded, false)
    now = DateTime.utc_now()

    # Build query for int8 embeddings
    base_query =
      from(e in Engram,
        where: not is_nil(e.embedding_int8),
        select: %{
          id: e.id,
          content: e.content,
          category: e.category,
          importance: e.importance,
          metadata: e.metadata,
          embedding_int8: e.embedding_int8,
          inserted_at: e.inserted_at,
          access_count: e.access_count,
          last_accessed_at: e.last_accessed_at,
          decay_rate: e.decay_rate,
          protected: e.protected
        }
      )

    query =
      base_query
      |> maybe_filter_category(category)
      |> maybe_filter_project(project_id)
      |> maybe_filter_superseded(include_superseded)
      |> maybe_filter_archived(false)

    # Fetch all and compute similarity
    Repo.all(query)
    |> Enum.map(fn engram ->
      similarity =
        case Math.cosine_similarity_int8(query_int8, engram.embedding_int8) do
          {:ok, sim} -> sim
          {:error, _} -> 0.0
        end

      recency_score = calculate_recency_score(engram.inserted_at, now)

      score =
        if recency_boost > 0 do
          (1.0 - recency_boost) * similarity + recency_boost * recency_score
        else
          similarity
        end

      %{
        id: engram.id,
        content: engram.content,
        category: engram.category,
        importance: engram.importance,
        metadata: engram.metadata || %{},
        inserted_at: engram.inserted_at,
        similarity: similarity,
        recency_score: recency_score,
        score: score
      }
    end)
    |> Enum.filter(fn %{similarity: sim} -> sim >= min_similarity end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
  end

  defp maybe_filter_category(query, nil), do: query

  defp maybe_filter_category(query, category) do
    # Convert atom to string for Ecto - category column is :string type
    category_str = if is_atom(category), do: to_string(category), else: category
    from(e in query, where: e.category == ^category_str)
  end

  defp maybe_filter_project(query, nil), do: query

  defp maybe_filter_project(query, project_id) do
    from(e in query, where: e.project_id == ^project_id)
  end

  # SPEC-034: Filter out superseded memories by default
  # include_superseded: true => don't filter
  defp maybe_filter_superseded(query, true), do: query

  defp maybe_filter_superseded(query, _) do
    from(e in query, where: is_nil(e.superseded_at))
  end

  # Filter out archived memories by default (archive-not-delete strategy)
  # include_archived: true => don't filter (for recovery/diagnostics)
  defp maybe_filter_archived(query, include_archived) when include_archived == true, do: query

  defp maybe_filter_archived(query, _) do
    from(e in query, where: e.archived == false or is_nil(e.archived))
  end

  # O(1) memory streaming implementation with optional recency boost
  # Used as fallback when int8/binary embeddings are not available
  defp stream_search(query_embedding, limit, min_similarity, batch_size, recency_boost) do
    base_query = from(e in Engram, select: e)
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      base_query
      |> Repo.stream(max_rows: batch_size)
      |> Stream.map(&calculate_similarity_wrapper(&1, query_embedding, now, recency_boost))
      |> Stream.filter(&(&1.similarity >= min_similarity))
      |> Enum.reduce([], fn item, acc ->
        insert_into_top_k(item, acc, limit)
      end)
      |> Enum.sort_by(& &1.score, :desc)
    end)
    |> case do
      {:ok, results} -> results
      {:error, _} -> []
    end
  end

  defp insert_into_top_k(item, acc, k) when length(acc) < k do
    [item | acc]
  end

  defp insert_into_top_k(item, acc, _k) do
    {min_item, min_idx} =
      acc
      |> Enum.with_index()
      |> Enum.min_by(fn {i, _idx} -> i.score end)

    if item.score > min_item.score do
      List.replace_at(acc, min_idx, item)
    else
      acc
    end
  end

  defp calculate_similarity_wrapper(engram, query_embedding, now, recency_boost) do
    embedding =
      case Engram.get_embedding(engram) do
        {:ok, emb} -> emb
        {:error, _} -> engram.embedding || []
      end

    similarity = calculate_similarity(query_embedding, embedding)
    recency_score = calculate_recency_score(engram.inserted_at, now)

    score =
      if recency_boost > 0 do
        (1.0 - recency_boost) * similarity + recency_boost * recency_score
      else
        similarity
      end

    %{
      id: engram.id,
      content: engram.content,
      category: engram.category,
      importance: engram.importance,
      metadata: engram.metadata || %{},
      inserted_at: engram.inserted_at,
      similarity: similarity,
      recency_score: recency_score,
      score: score
    }
  end

  defp calculate_recency_score(nil, _now), do: 0.5

  defp calculate_recency_score(inserted_at, now) do
    inserted_dt =
      case inserted_at do
        %NaiveDateTime{} -> DateTime.from_naive!(inserted_at, "Etc/UTC")
        %DateTime{} -> inserted_at
        _ -> now
      end

    seconds_diff = DateTime.diff(now, inserted_dt, :second)
    days_diff = seconds_diff / 86_400.0
    half_life_days = 7.0
    :math.pow(0.5, days_diff / half_life_days)
  end

  defp calculate_similarity(vec1, vec2) when is_list(vec1) and is_list(vec2) do
    len1 = length(vec1)
    len2 = length(vec2)

    if len1 == 0 or len2 == 0 do
      0.0
    else
      {v1, v2} =
        if len1 != len2 do
          min_len = min(len1, len2)
          {Enum.take(vec1, min_len), Enum.take(vec2, min_len)}
        else
          {vec1, vec2}
        end

      dot = Enum.zip(v1, v2) |> Enum.reduce(0.0, fn {a, b}, acc -> acc + a * b end)
      mag1 = :math.sqrt(Enum.reduce(v1, 0.0, fn x, acc -> acc + x * x end))
      mag2 = :math.sqrt(Enum.reduce(v2, 0.0, fn x, acc -> acc + x * x end))

      if mag1 == 0.0 or mag2 == 0.0, do: 0.0, else: dot / (mag1 * mag2)
    end
  end

  defp calculate_similarity(_, _), do: 0.0

  # SPEC-065 FIX: Content quality filter to prevent test data pollution
  @test_patterns ~w(test Test TEST unique123 placeholder dummy sample example lorem ipsum)
  @min_content_length 10

  defp validate_content_quality(content) when is_binary(content) do
    content_lower = String.downcase(content)

    cond do
      # Reject very short content
      String.length(content) < @min_content_length ->
        {:error, {:content_too_short, String.length(content), @min_content_length}}

      # Reject obvious test patterns in production
      Mix.env() == :prod and contains_test_pattern?(content_lower) ->
        {:error, :test_data_in_production}

      # Check for generic/low-value content
      generic_content?(content_lower) ->
        {:error, :content_too_generic}

      true ->
        :ok
    end
  end

  defp validate_content_quality(_), do: {:error, :invalid_content_type}

  defp contains_test_pattern?(content) do
    Enum.any?(@test_patterns, fn pattern ->
      # Only match whole words, not substrings
      String.contains?(content, pattern) and
        (String.starts_with?(content, pattern) or
           String.contains?(content, " #{pattern}") or
           String.ends_with?(content, pattern))
    end)
  end

  defp generic_content?(content) do
    # Content that's too generic to be useful
    generic_patterns = [
      ~r/^user\s+(frequently\s+)?interacts?\s+with/i,
      ~r/^tagged\s+content\.?$/i,
      ~r/^[a-z]+\s+content\.?$/i
    ]

    Enum.any?(generic_patterns, fn pattern ->
      Regex.match?(pattern, content)
    end)
  end

  defp validate_content_size(content) when is_binary(content) do
    if byte_size(content) > @max_content_size do
      {:error, {:content_too_large, byte_size(content), @max_content_size}}
    else
      :ok
    end
  end

  defp validate_content_size(_), do: {:error, :invalid_content_type}

  defp validate_embedding_dimension(embedding) when is_list(embedding) do
    dim = length(embedding)

    cond do
      dim == 0 -> {:error, :empty_embedding}
      dim > @max_embedding_dim -> {:error, {:embedding_too_large, dim, @max_embedding_dim}}
      true -> :ok
    end
  end

  defp validate_embedding_dimension(_), do: {:error, :invalid_embedding_type}

  # SPEC-031 + SPEC-033: Quantize embedding to int8 and binary for storage.
  # Returns {embedding_to_store, quantized_attrs} tuple.
  # This helper eliminates repeated nested case patterns throughout the module.
  defp quantize_embedding_for_storage(embedding) do
    case Math.quantize_int8(embedding) do
      {:ok, {int8_binary, scale, offset}} ->
        binary_attrs = generate_binary_attrs(int8_binary)

        # Successfully quantized - store int8 and binary
        {[],
         Map.merge(
           %{
             embedding_int8: int8_binary,
             embedding_scale: scale,
             embedding_offset: offset
           },
           binary_attrs
         )}

      {:error, reason} ->
        # Quantization failed - fall back to float32
        Logger.warning("Int8 quantization failed: #{inspect(reason)}, storing float32")
        {embedding, %{}}
    end
  end

  # Generate binary embedding from int8 for fast pre-filtering
  defp generate_binary_attrs(int8_binary) do
    case Math.int8_to_binary(int8_binary) do
      {:ok, binary} -> %{embedding_binary: binary}
      {:error, _} -> %{}
    end
  end

  defp generate_embedding(text) do
    Classifier.get_or_compute_embedding(text, fn ->
      case LLM.generate_embedding(text) do
        {:ok, embedding} ->
          {:ok, embedding}

        {:error, reason} ->
          # CRITICAL: Do NOT fall back to garbage embeddings
          # Better to fail storage than corrupt the memory store with unsearchable embeddings
          Logger.error(
            "Embedding generation failed: #{inspect(reason)} - memory will NOT be stored"
          )

          {:error, {:embedding_failed, reason}}
      end
    end)
  end

  # Fallback embedding removed - it created garbage that corrupted semantic search
  # If you need embedding-less storage, create a separate "pending_embedding" table

  defp log_memory_event(event, id, category, project_id \\ "global", tags \\ []) do
    :telemetry.execute(
      [:mimo, :brain, :memory, event],
      %{count: 1},
      %{
        id: id,
        category: category,
        project_id: project_id,
        tags: tags,
        timestamp: System.system_time(:second)
      }
    )
  end

  defp auto_generate_tags(content) do
    case LLM.auto_tag(content) do
      {:ok, tags} -> tags
      {:error, _} -> []
    end
  end

  defp notify_memory_stored(engram) do
    if Process.whereis(SynapseOrchestrator) do
      SynapseOrchestrator.on_memory_stored(engram)
    end
  rescue
    e ->
      Logger.warning("Failed to notify orchestrator of memory storage: #{Exception.message(e)}")
  end

  defp maybe_auto_protect(engram, importance) when importance >= 0.85 do
    try do
      Forgetting.protect(engram.id)
      Logger.debug("[Memory] Auto-protected high-importance memory ##{engram.id}")
    rescue
      e ->
        Logger.warning("[Memory] Failed to auto-protect ##{engram.id}: #{Exception.message(e)}")
    end
  end

  defp maybe_auto_protect(_engram, _importance), do: :ok

  @doc """
  Get the complete supersession chain for a memory.

  Returns a list of engrams in chronological order (oldest to newest),
  representing the full evolution of a piece of knowledge.

  ## Examples

      # If memory B superseded A, and C superseded B:
      iex> Memory.get_chain(c_id)
      [%Engram{id: a_id}, %Engram{id: b_id}, %Engram{id: c_id}]
  """
  @spec get_chain(integer()) :: [Engram.t()]
  def get_chain(engram_id) when is_integer(engram_id) do
    case Repo.get(Engram, engram_id) do
      nil -> []
      engram -> build_chain(engram)
    end
  end

  defp build_chain(engram) do
    # First, walk backward to find the original (with cycle detection)
    original = walk_chain_backward(engram, MapSet.new([engram.id]))
    # Then walk forward from original to build complete chain (with cycle detection)
    walk_chain_forward(original, [], MapSet.new())
  end

  defp walk_chain_backward(%Engram{supersedes_id: nil} = engram, _visited), do: engram

  defp walk_chain_backward(%Engram{supersedes_id: predecessor_id} = engram, visited) do
    # Cycle detection: if we've seen this ID before, stop to prevent infinite loop
    if MapSet.member?(visited, predecessor_id) do
      Logger.warning(
        "TMC cycle detected at engram #{engram.id} -> #{predecessor_id}, stopping traversal"
      )

      engram
    else
      case Repo.get(Engram, predecessor_id) do
        # Broken chain - return current as original
        nil -> engram
        predecessor -> walk_chain_backward(predecessor, MapSet.put(visited, predecessor_id))
      end
    end
  end

  defp walk_chain_forward(nil, acc, _visited), do: Enum.reverse(acc)

  defp walk_chain_forward(engram, acc, visited) do
    # Cycle detection: if we've seen this ID before, stop to prevent infinite loop
    if MapSet.member?(visited, engram.id) do
      Logger.warning("TMC cycle detected at engram #{engram.id}, stopping forward traversal")
      Enum.reverse(acc)
    else
      # Find what supersedes this engram (if anything)
      successor = Repo.one(from(e in Engram, where: e.supersedes_id == ^engram.id))
      walk_chain_forward(successor, [engram | acc], MapSet.put(visited, engram.id))
    end
  end

  @doc """
  Get the current (active, not superseded) version in a memory chain.

  Given any memory ID in a chain, returns the most recent, non-superseded version.

  ## Examples

      # If memory B superseded A, and C superseded B:
      iex> Memory.get_current(a_id)
      %Engram{id: c_id}
  """
  @spec get_current(integer()) :: Engram.t() | nil
  def get_current(engram_id) when is_integer(engram_id) do
    case Repo.get(Engram, engram_id) do
      nil -> nil
      engram -> walk_to_current(engram)
    end
  end

  defp walk_to_current(engram), do: walk_to_current(engram, MapSet.new([engram.id]))

  defp walk_to_current(engram, visited) do
    # Find what supersedes this engram
    case Repo.one(from(e in Engram, where: e.supersedes_id == ^engram.id)) do
      # This is the current version
      nil ->
        engram

      successor ->
        # Cycle detection
        if MapSet.member?(visited, successor.id) do
          Logger.warning(
            "TMC cycle detected walking to current from #{engram.id}, returning #{engram.id}"
          )

          engram
        else
          walk_to_current(successor, MapSet.put(visited, successor.id))
        end
    end
  end

  @doc """
  Get the original (oldest) version in a memory chain.

  Given any memory ID in a chain, returns the oldest, original version.

  ## Examples

      # If memory B superseded A, and C superseded B:
      iex> Memory.get_original(c_id)
      %Engram{id: a_id}
  """
  @spec get_original(integer()) :: Engram.t() | nil
  def get_original(engram_id) when is_integer(engram_id) do
    case Repo.get(Engram, engram_id) do
      nil -> nil
      engram -> walk_chain_backward(engram, MapSet.new([engram.id]))
    end
  end

  @doc """
  Check if an engram has been superseded by a newer version.

  ## Examples

      iex> Memory.superseded?(old_engram_id)
      true
  """
  @spec superseded?(integer()) :: boolean()
  def superseded?(engram_id) when is_integer(engram_id) do
    case Repo.get(Engram, engram_id) do
      nil -> false
      engram -> Engram.superseded?(engram)
    end
  end

  @doc """
  Get the chain length (number of versions) for a memory.

  ## Examples

      iex> Memory.chain_length(c_id)
      3  # Original -> Update 1 -> Update 2
  """
  @spec chain_length(integer()) :: non_neg_integer()
  def chain_length(engram_id) when is_integer(engram_id) do
    engram_id
    |> get_chain()
    |> length()
  end

  # Asynchronously links a new memory to the knowledge graph.
  # This improves graph density without blocking memory storage.
  defp maybe_auto_link_memory(engram_id, content) when is_integer(engram_id) do
    # Only auto-link if content is substantial
    if String.length(content || "") > 20 do
      try do
        # Use the Synapse Linker to create edges
        SynapseLinker.link_memory(engram_id, threshold: 0.6, max_links: 3)
      rescue
        e ->
          Logger.debug("[Memory] Auto-link failed for #{engram_id}: #{inspect(e)}")
          :ok
      end
    end

    :ok
  end

  defp maybe_auto_link_memory(_, _), do: :ok
end
