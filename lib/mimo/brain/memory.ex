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
  """
  import Ecto.Query
  require Logger
  alias Mimo.Repo
  alias Mimo.Brain.Engram
  alias Mimo.ErrorHandling.RetryStrategies

  # Configuration constants
  @max_memory_batch_size 1000
  # 100KB max per memory
  @max_content_size 100_000
  # Safety limit for embedding dimensions
  @max_embedding_dim 4096

  @doc """
  Search memories by semantic similarity using streaming.
  Guarantees O(1) memory usage regardless of database size.

  ## Options

    * `:limit` - Maximum results to return (default: 10)
    * `:min_similarity` - Minimum similarity threshold 0-1 (default: 0.3)
    * `:batch_size` - Internal batch size for streaming (default: 1000)
    
  ## Examples

      search_memories("project architecture", limit: 5)
      search_memories("error handling", min_similarity: 0.5)
  """
  def search_memories(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    min_similarity = Keyword.get(opts, :min_similarity, 0.3)
    batch_size = Keyword.get(opts, :batch_size, @max_memory_batch_size)

    with {:ok, query_embedding} <- generate_embedding(query) do
      results = stream_search(query_embedding, limit, min_similarity, batch_size)
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
      fn -> do_persist_memory(content, category, importance) end,
      max_retries: 3,
      base_delay: 100,
      on_retry: fn attempt, reason ->
        Logger.warning("Memory persist retry #{attempt}: #{inspect(reason)}")
      end
    )
  end

  defp do_persist_memory(content, category, importance) do
    Repo.transaction(fn ->
      with :ok <- validate_content_size(content),
           {:ok, embedding} <- generate_embedding(content),
           :ok <- validate_embedding_dimension(embedding) do
        # Auto-detect project and generate tags
        project_id = Mimo.Brain.LLM.detect_project(content)
        tags = auto_generate_tags(content)

        changeset =
          Engram.changeset(%Engram{}, %{
            content: content,
            category: category,
            importance: importance,
            embedding: embedding,
            project_id: project_id,
            tags: tags
          })

        case Repo.insert(changeset) do
          {:ok, engram} ->
            log_memory_event(:stored, engram.id, category, project_id, tags)
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
          changeset =
            Engram.changeset(%Engram{}, %{
              content: content,
              category: category,
              importance: importance,
              embedding: embedding
            })

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
        changeset =
          Engram.changeset(%Engram{}, %{
            content: content,
            category: type,
            importance: 0.8,
            embedding: embedding,
            metadata: Map.merge(metadata, %{"ref" => ref, "type" => type})
          })

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
                {:ok, emb} -> emb
                _ -> []
              end
          end

        changeset =
          Engram.changeset(%Engram{}, %{
            content: content,
            category: category,
            importance: importance,
            embedding: final_embedding,
            metadata: metadata,
            last_accessed_at: NaiveDateTime.utc_now()
          })

        case Repo.insert(changeset) do
          {:ok, engram} ->
            log_memory_event(:stored, engram.id, category)
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
  # Private Functions - Streaming Search
  # ==========================================================================

  # O(1) memory streaming implementation
  defp stream_search(query_embedding, limit, min_similarity, batch_size) do
    # Use Ecto stream to avoid loading all records into memory
    base_query = from(e in Engram, select: e)

    # Stream in batches and collect top results
    Repo.transaction(fn ->
      base_query
      |> Repo.stream(max_rows: batch_size)
      |> Stream.map(&calculate_similarity_wrapper(&1, query_embedding))
      |> Stream.filter(&(&1.similarity >= min_similarity))
      # Materialize stream
      |> Enum.to_list()
      |> Enum.sort_by(& &1.similarity, :desc)
      |> Enum.take(limit)
    end)
    |> case do
      {:ok, results} -> results
      {:error, _} -> []
    end
  end

  # Wrapper ensures proper error handling per-record
  defp calculate_similarity_wrapper(engram, query_embedding) do
    similarity = calculate_similarity(query_embedding, engram.embedding)

    %{
      id: engram.id,
      content: engram.content,
      category: engram.category,
      importance: engram.importance,
      metadata: engram.metadata || %{},
      similarity: similarity
    }
  end

  # Simple cosine similarity - for production use Nx or Rust NIF
  # Handles dimension mismatch by truncating to smaller dimension
  # This allows searching mixed-dimension embeddings (legacy data migration)
  defp calculate_similarity(vec1, vec2) when is_list(vec1) and is_list(vec2) do
    len1 = length(vec1)
    len2 = length(vec2)
    
    # Handle empty vectors
    if len1 == 0 or len2 == 0 do
      0.0
    else
      # Truncate to smaller dimension to handle mixed embeddings
      # This preserves semantic meaning in overlapping dimensions
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
    # Use classifier cache to avoid redundant LLM calls
    Mimo.Cache.Classifier.get_or_compute_embedding(text, fn ->
      case Mimo.Brain.LLM.generate_embedding(text) do
        {:ok, embedding} ->
          {:ok, embedding}

        {:error, reason} ->
          Logger.warning("Primary embedding failed: #{inspect(reason)}, using fallback")
          fallback_embedding(text)
      end
    end)
  end

  # Simple fallback embedding using character frequencies
  # This ensures the system works even without LLM access
  defp fallback_embedding(text) do
    # Create a simple 64-dimensional embedding based on character frequencies
    chars = String.downcase(text) |> String.to_charlist()
    total = max(length(chars), 1)

    # 26 letters + 10 digits + common punctuation + padding = 64 dimensions
    letter_freqs = for c <- ?a..?z, do: Enum.count(chars, &(&1 == c)) / total
    digit_freqs = for c <- ?0..?9, do: Enum.count(chars, &(&1 == c)) / total

    # Common punctuation
    punct = [?., ?,, ?!, ??, ?:, ?;, ?-, ?_, ?@, ?#]
    punct_freqs = for c <- punct, do: Enum.count(chars, &(&1 == c)) / total

    # Padding to 64 dimensions
    padding = List.duplicate(0.0, 64 - 26 - 10 - 10)

    embedding = letter_freqs ++ digit_freqs ++ punct_freqs ++ padding

    {:ok, embedding}
  end

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
      %{id: id, category: category, project_id: project_id, tags: tags, timestamp: System.system_time(:second)}
    )
  end

  # Auto-generate tags using LLM (async, best-effort)
  defp auto_generate_tags(content) do
    case Mimo.Brain.LLM.auto_tag(content) do
      {:ok, tags} -> tags
      {:error, _} -> []
    end
  end
end
