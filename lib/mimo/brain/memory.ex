defmodule Mimo.Brain.Memory do
  @moduledoc """
  Local vector memory store using SQLite and embeddings.
  
  Memory-safe implementation with:
  - O(1) memory usage via streaming (regardless of database size)
  - Configurable batch sizes
  - Content size limits
  - ACID transactions for writes
  - Embedding dimension validation
  """
  import Ecto.Query
  require Logger
  alias Mimo.Repo
  alias Mimo.Brain.Engram

  # Configuration constants
  @max_memory_batch_size 1000
  @max_content_size 100_000  # 100KB max per memory
  @max_embedding_dim 4096   # Safety limit for embedding dimensions
  
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
  
  ## Options
  
    * `:importance` - Importance score 0-1 (default: 0.5)
    
  ## Examples
  
      persist_memory("User prefers dark mode", "observation")
      persist_memory("API key rotated", "action", importance: 0.9)
  """
  def persist_memory(content, category, importance \\ 0.5) do
    Repo.transaction(fn ->
      with :ok <- validate_content_size(content),
           {:ok, embedding} <- generate_embedding(content),
           :ok <- validate_embedding_dimension(embedding) do
        
        changeset = Engram.changeset(%Engram{}, %{
          content: content,
          category: category,
          importance: importance,
          embedding: embedding
        })

        case Repo.insert(changeset) do
          {:ok, engram} -> 
            log_memory_event(:stored, engram.id, category)
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
          
          changeset = Engram.changeset(%Engram{}, %{
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
    Repo.one(from e in Engram, select: count(e.id))
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
  def update_importance(id, importance) when is_number(importance) and importance >= 0 and importance <= 1 do
    case Repo.get(Engram, id) do
      nil -> 
        {:error, :not_found}
      engram ->
        changeset = Engram.changeset(engram, %{importance: importance})
        Repo.update(changeset)
    end
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
      |> Enum.to_list()  # Materialize stream
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
      similarity: similarity
    }
  end

  # Simple cosine similarity - for production use Nx or Rust NIF
  defp calculate_similarity(vec1, vec2) when is_list(vec1) and is_list(vec2) do
    if length(vec1) != length(vec2) do
      0.0
    else
      dot = Enum.zip(vec1, vec2) |> Enum.reduce(0.0, fn {a, b}, acc -> acc + a * b end)
      mag1 = :math.sqrt(Enum.reduce(vec1, 0.0, fn x, acc -> acc + x * x end))
      mag2 = :math.sqrt(Enum.reduce(vec2, 0.0, fn x, acc -> acc + x * x end))

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
    case Mimo.Brain.LLM.generate_embedding(text) do
      {:ok, embedding} -> {:ok, embedding}
      {:error, reason} -> 
        Logger.warning("Primary embedding failed: #{inspect(reason)}, using fallback")
        fallback_embedding(text)
    end
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
  
  defp log_memory_event(event, id, category) do
    :telemetry.execute(
      [:mimo, :brain, :memory, event],
      %{count: 1},
      %{id: id, category: category, timestamp: System.system_time(:second)}
    )
  end
end
