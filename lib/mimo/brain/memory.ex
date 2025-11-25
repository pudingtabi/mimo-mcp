defmodule Mimo.Brain.Memory do
  @moduledoc """
  Local vector memory store using SQLite and embeddings.
  """
  import Ecto.Query
  require Logger
  alias Mimo.Repo
  alias Mimo.Brain.Engram

  @doc """
  Search memories by semantic similarity.
  Uses simple cosine similarity calculation.
  """
  def search_memories(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    _min_similarity = Keyword.get(opts, :min_similarity, 0.3)

    case Mimo.Brain.LLM.generate_embedding(query) do
      {:ok, query_embedding} ->
        # Get all memories and calculate similarity in Elixir
        # (For production, use proper vector DB like pgvector)
        memories = Repo.all(from e in Engram, order_by: [desc: e.importance], limit: ^(limit * 3))
        
        memories
        |> Enum.map(fn engram ->
          similarity = calculate_similarity(query_embedding, engram.embedding)
          %{
            id: engram.id,
            content: engram.content,
            category: engram.category,
            importance: engram.importance,
            similarity: similarity
          }
        end)
        |> Enum.sort_by(& &1.similarity, :desc)
        |> Enum.take(limit)

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
  """
  def persist_memory(content, category, importance \\ 0.5) do
    {:ok, embedding} = Mimo.Brain.LLM.generate_embedding(content)
    
    changeset = Engram.changeset(%Engram{}, %{
      content: content,
      category: category,
      importance: importance,
      embedding: embedding
    })

    case Repo.insert(changeset) do
      {:ok, engram} -> {:ok, engram.id}
      {:error, changeset} -> {:error, changeset.errors}
    end
  end

  @doc """
  Clean up old, low-importance memories.
  """
  def cleanup_old(days_old) do
    cutoff = DateTime.add(DateTime.utc_now(), -days_old * 24 * 60 * 60, :second)
    
    {count, _} = Repo.delete_all(
      from e in Engram,
      where: e.inserted_at < ^cutoff and e.importance < 0.5
    )
    
    Logger.info("Cleaned up #{count} old memories")
    {:ok, count}
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
end
