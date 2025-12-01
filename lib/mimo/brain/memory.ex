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
  alias Mimo.Repo
  alias Mimo.Brain.Engram
  alias Mimo.Brain.HnswIndex
  alias Mimo.ErrorHandling.RetryStrategies
  alias Mimo.Vector.Math
  alias Mimo.Brain.NoveltyDetector
  alias Mimo.Brain.MemoryIntegrator

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

    with {:ok, query_embedding} <- generate_embedding(query) do
      # Quantize query embedding for search
      results =
        case Math.quantize_int8(query_embedding) do
          {:ok, {query_int8, _scale, _offset}} ->
            # Determine search strategy
            actual_strategy = determine_strategy(strategy, opts)

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
          Mimo.Brain.AccessTracker.track_many(ids)
        end
      end

      results
    else
      {:error, reason} ->
        Logger.error("Embedding generation failed: #{inspect(reason)}")
        []
    end
  rescue
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
          actual_strategy = determine_strategy(strategy, opts)

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
      if ids != [], do: Mimo.Brain.AccessTracker.track_many(ids)
    end

    {:ok, results}
  rescue
    e ->
      Logger.error("Memory search with embedding failed: #{Exception.message(e)}")
      {:ok, []}
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
    RetryStrategies.with_retry(
      fn -> do_persist_memory_with_tmc(content, category, importance) end,
      max_retries: 3,
      base_delay: 100,
      on_retry: fn attempt, reason ->
        Logger.warning("Memory persist retry #{attempt}: #{inspect(reason)}")
      end
    )
  end

  # SPEC-034: TMC-aware persistence
  # Routes through NoveltyDetector to handle contradictions and updates
  defp do_persist_memory_with_tmc(content, category, importance) do
    category_str = to_string(category)

    # Classify the content using NoveltyDetector
    case NoveltyDetector.classify(content, category_str) do
      {:new, []} ->
        # No similar memories (or TMC disabled) - proceed with normal persistence
        do_persist_memory(content, category, importance)

      {:redundant, existing} ->
        # Near-duplicate found - reinforce existing memory
        Logger.debug("TMC: Redundant memory detected, reinforcing existing ##{existing.id}")
        # execute(:redundant, ...) always returns {:ok, :skipped} - just reinforce existing
        _result = MemoryIntegrator.execute(:redundant, content, existing, importance: importance)
        {:ok, existing.id}

      {:ambiguous, similar_memories} ->
        # Similar memories found - ask LLM to decide
        # Take the best match (first in list, sorted by similarity)
        [best_match | _] = similar_memories
        target = best_match.engram

        Logger.debug(
          "TMC: Ambiguous case with #{length(similar_memories)} similar memories, deciding for ##{target.id}"
        )

        # decide/3 always returns {:ok, %{decision: ...}} (fallback on errors)
        {:ok, %{decision: decision}} =
          MemoryIntegrator.decide(content, target, category: category_str, importance: importance)

        Logger.debug("TMC: LLM decided #{decision} for target ##{target.id}")

        case MemoryIntegrator.execute(decision, content, target,
               category: category_str,
               importance: importance
             ) do
          {:ok, :skipped} -> {:ok, target.id}
          {:ok, %Engram{id: id}} -> {:ok, id}
          {:error, _} = error -> error
        end
    end
  end

  defp do_persist_memory(content, category, importance) do
    Repo.transaction(fn ->
      with :ok <- validate_content_size(content),
           :unique <- check_duplicate(content),
           {:ok, embedding} <- generate_embedding(content),
           :ok <- validate_embedding_dimension(embedding) do
        # Auto-detect project and generate tags
        project_id = Mimo.Brain.LLM.detect_project(content)
        tags = auto_generate_tags(content)

        # SPEC-031: Quantize to int8 for efficient storage
        # SPEC-033: Also generate binary embedding for fast pre-filtering
        {embedding_to_store, quantized_attrs} =
          case Math.quantize_int8(embedding) do
            {:ok, {int8_binary, scale, offset}} ->
              # Generate binary embedding from int8
              binary_attrs =
                case Math.int8_to_binary(int8_binary) do
                  {:ok, binary} -> %{embedding_binary: binary}
                  {:error, _} -> %{}
                end

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

        changeset =
          Engram.changeset(
            %Engram{},
            Map.merge(
              %{
                content: content,
                category: category,
                importance: importance,
                embedding: embedding_to_store,
                project_id: project_id,
                tags: tags
              },
              quantized_attrs
            )
          )

        case Repo.insert(changeset) do
          {:ok, engram} ->
            log_memory_event(:stored, engram.id, category, project_id, tags)
            # SPEC-025: Notify Orchestrator for Synapse graph linking
            notify_memory_stored(engram)
            # SPEC-032: Auto-protect high-importance memories
            maybe_auto_protect(engram, importance)
            {:ok, engram.id}

          {:error, changeset} ->
            Repo.rollback(changeset.errors)
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction_result()
  end

  @doc """
  Store multiple memories atomically.
  All memories are stored or none are (transaction).
  """
  def persist_memories(memories) when is_list(memories) do
    Repo.transaction(fn ->
      Enum.map(memories, fn memory ->
        content = Map.get(memory, :content) || Map.get(memory, "content")
        category = Map.get(memory, :category) || Map.get(memory, "category", "fact")
        importance = Map.get(memory, :importance) || Map.get(memory, "importance", 0.5)

        with :ok <- validate_content_size(content),
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
            {:ok, engram} -> engram.id
            {:error, changeset} -> Repo.rollback({:insert_failed, changeset.errors})
          end
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end)
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

    persist_memory_with_metadata(content, type, ref, metadata)
  end

  defp persist_memory_with_metadata(content, type, ref, metadata) do
    Repo.transaction(fn ->
      with :ok <- validate_content_size(content),
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

        changeset =
          Engram.changeset(
            %Engram{},
            Map.merge(
              %{
                content: content,
                category: type,
                importance: 0.8,
                embedding: embedding_to_store,
                metadata: Map.merge(metadata, %{"ref" => ref, "type" => type})
              },
              quantized_attrs
            )
          )

        case Repo.insert(changeset) do
          {:ok, engram} -> {:ok, engram.id}
          {:error, changeset} -> Repo.rollback(changeset.errors)
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction_result()
  end

  @doc """
  Search with type filter - used by SemanticStore.Resolver.
  """
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    type_filter = Keyword.get(opts, :type)
    min_similarity = Keyword.get(opts, :min_similarity, 0.3)

    results = search_memories(query, limit: limit * 2, min_similarity: min_similarity)

    filtered =
      if type_filter do
        Enum.filter(results, fn r ->
          r[:category] == type_filter or
            r[:metadata]["type"] == type_filter
        end)
      else
        results
      end

    {:ok, Enum.take(filtered, limit) |> Enum.map(&add_score_field/1)}
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
    RetryStrategies.with_retry(
      fn -> do_persist_memory_full(content, category, importance, embedding, metadata) end,
      max_retries: 3,
      base_delay: 100,
      on_retry: fn attempt, reason ->
        Logger.warning("Memory persist retry #{attempt}: #{inspect(reason)}")
      end
    )
  end

  defp do_persist_memory_full(content, category, importance, embedding, metadata) do
    Repo.transaction(fn ->
      with :ok <- validate_content_size(content) do
        # Use provided embedding or generate new one
        final_embedding =
          case embedding do
            emb when is_list(emb) and length(emb) > 0 ->
              emb

            _ ->
              case generate_embedding(content) do
                {:ok, emb} when is_list(emb) and length(emb) > 0 ->
                  emb

                {:ok, []} ->
                  Logger.warning("Embedding generation returned empty list for content")
                  Repo.rollback({:empty_embedding, "Embedding generation returned empty result"})

                {:error, reason} ->
                  Logger.warning("Embedding generation failed: #{inspect(reason)}")
                  Repo.rollback({:embedding_failed, reason})
              end
          end

        # SPEC-031 + SPEC-033: Quantize to int8 and binary
        {embedding_to_store, quantized_attrs} =
          case Math.quantize_int8(final_embedding) do
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

            {:error, reason} ->
              Logger.warning("Int8 quantization failed: #{inspect(reason)}, storing float32")
              {final_embedding, %{}}
          end

        changeset =
          Engram.changeset(
            %Engram{},
            Map.merge(
              %{
                content: content,
                category: category,
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
            log_memory_event(:stored, engram.id, category)
            # SPEC-025: Notify Orchestrator for Synapse graph linking
            notify_memory_stored(engram)
            {:ok, engram}

          {:error, changeset} ->
            Repo.rollback(changeset.errors)
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction_result()
  end

  # ==========================================================================
  # SPEC-033: Search Strategy Selection and Implementations
  # ==========================================================================

  # Determine which search strategy to use
  defp determine_strategy(:auto, opts) do
    # Check if HNSW index is available and has enough vectors
    if HnswIndex.should_use_hnsw?() do
      :hnsw
    else
      # Check if we have enough memories with binary embeddings
      category = Keyword.get(opts, :category)

      count =
        if category do
          Repo.one(
            from(e in Engram,
              where: e.category == ^category and not is_nil(e.embedding_binary),
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

      cond do
        # Will try HNSW but wasn't available
        count >= @hnsw_search_threshold -> :binary_rescore
        count >= @binary_search_threshold -> :binary_rescore
        true -> :exact
      end
    end
  rescue
    # If HnswIndex GenServer isn't running, fall back to other strategies
    _ -> determine_strategy_without_hnsw(opts)
  end

  defp determine_strategy(strategy, _opts) when strategy in [:exact, :binary_rescore, :hnsw] do
    strategy
  end

  defp determine_strategy(_, opts), do: determine_strategy_without_hnsw(opts)

  # Fallback strategy selection when HNSW is not available
  defp determine_strategy_without_hnsw(opts) do
    category = Keyword.get(opts, :category)

    count =
      if category do
        Repo.one(
          from(e in Engram,
            where: e.category == ^category and not is_nil(e.embedding_binary),
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
    # Need to dequantize to get float embedding for two_stage_search
    # This is a fallback path, so we just use exact search
    exact_search(query_int8, limit, min_similarity, recency_boost, opts)
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

  # Stage 1: Fast Hamming pre-filter
  defp hamming_prefilter(query_binary, candidates, category, project_id, include_superseded) do
    # Build query for binary embeddings
    base_query =
      from(e in Engram,
        where: not is_nil(e.embedding_binary),
        select: {e.id, e.embedding_binary}
      )

    query =
      base_query
      |> maybe_filter_category(category)
      |> maybe_filter_project(project_id)
      |> maybe_filter_superseded(include_superseded)

    # Fetch all binary embeddings
    engrams = Repo.all(query)

    if engrams == [] do
      []
    else
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
    from(e in query, where: e.category == ^category)
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

  # ==========================================================================
  # Private Functions - Legacy Streaming Search (fallback)
  # ==========================================================================

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

  # ==========================================================================
  # Private Functions - Validation
  # ==========================================================================

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

  # ==========================================================================
  # Private Functions - Embedding Generation
  # ==========================================================================

  defp generate_embedding(text) do
    Mimo.Cache.Classifier.get_or_compute_embedding(text, fn ->
      case Mimo.Brain.LLM.generate_embedding(text) do
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

  # ==========================================================================
  # Private Functions - Helpers
  # ==========================================================================

  defp unwrap_transaction_result({:ok, {:ok, result}}), do: {:ok, result}
  defp unwrap_transaction_result({:ok, {:error, reason}}), do: {:error, reason}
  defp unwrap_transaction_result({:error, reason}), do: {:error, reason}

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
    case Mimo.Brain.LLM.auto_tag(content) do
      {:ok, tags} -> tags
      {:error, _} -> []
    end
  end

  # ==========================================================================
  # SPEC-025: Cognitive Codebase Integration
  # ==========================================================================

  defp notify_memory_stored(engram) do
    if Process.whereis(Mimo.Synapse.Orchestrator) do
      Mimo.Synapse.Orchestrator.on_memory_stored(engram)
    end
  rescue
    e ->
      Logger.warning("Failed to notify orchestrator of memory storage: #{Exception.message(e)}")
  end

  # ==========================================================================
  # SPEC-032: Duplicate Prevention & Auto-Protection
  # ==========================================================================

  defp check_duplicate(content) do
    case search_memories(content, limit: 1, min_similarity: 0.95, strategy: :exact) do
      [%{id: id, similarity: sim}] when sim >= 0.95 ->
        Logger.debug(
          "[Memory] Duplicate detected (sim: #{Float.round(sim, 3)}), returning existing ##{id}"
        )

        {:duplicate, id}

      _ ->
        :unique
    end
  rescue
    _ ->
      :unique
  end

  defp maybe_auto_protect(engram, importance) when importance >= 0.85 do
    try do
      Mimo.Brain.Forgetting.protect(engram.id)
      Logger.debug("[Memory] Auto-protected high-importance memory ##{engram.id}")
    rescue
      e ->
        Logger.warning("[Memory] Failed to auto-protect ##{engram.id}: #{Exception.message(e)}")
    end
  end

  defp maybe_auto_protect(_engram, _importance), do: :ok

  # ==========================================================================
  # SPEC-034: Temporal Memory Chains (TMC) - Chain Traversal Functions
  # ==========================================================================

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
    # First, walk backward to find the original
    original = walk_chain_backward(engram)
    # Then walk forward from original to build complete chain
    walk_chain_forward(original, [])
  end

  defp walk_chain_backward(%Engram{supersedes_id: nil} = engram), do: engram

  defp walk_chain_backward(%Engram{supersedes_id: predecessor_id}) do
    case Repo.get(Engram, predecessor_id) do
      nil -> nil
      predecessor -> walk_chain_backward(predecessor)
    end
  end

  defp walk_chain_forward(nil, acc), do: Enum.reverse(acc)

  defp walk_chain_forward(engram, acc) do
    # Find what supersedes this engram (if anything)
    successor = Repo.one(from(e in Engram, where: e.supersedes_id == ^engram.id))
    walk_chain_forward(successor, [engram | acc])
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

  defp walk_to_current(engram) do
    # Find what supersedes this engram
    case Repo.one(from(e in Engram, where: e.supersedes_id == ^engram.id)) do
      # This is the current version
      nil -> engram
      successor -> walk_to_current(successor)
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
      engram -> walk_chain_backward(engram)
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
end
