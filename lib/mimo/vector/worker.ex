defmodule Mimo.Vector.Worker do
  @moduledoc """
  Worker module for processing vector operations.
  
  Provides convenience functions for common vector search patterns
  used throughout the Mimo system.
  """

  alias Mimo.Vector.Math

  @doc """
  Searches for similar vectors and returns results with metadata.
  
  ## Parameters
  
    - `query` - Query embedding vector
    - `corpus` - List of `{id, embedding}` tuples
    - `opts` - Options:
      - `:limit` - Maximum number of results (default: 10)
      - `:min_similarity` - Minimum similarity threshold (default: 0.0)
  
  ## Returns
  
  List of `{id, similarity}` tuples sorted by similarity descending.
  """
  @spec search([float()], [{term(), [float()]}], keyword()) :: [{term(), float()}]
  def search(query, corpus, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    min_similarity = Keyword.get(opts, :min_similarity, 0.0)

    {ids, embeddings} = Enum.unzip(corpus)

    case Math.batch_similarity(query, embeddings) do
      {:ok, similarities} ->
        ids
        |> Enum.zip(similarities)
        |> Enum.filter(fn {_id, sim} -> sim >= min_similarity end)
        |> Enum.sort_by(fn {_id, sim} -> sim end, :desc)
        |> Enum.take(limit)

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Async search using Task.Supervisor.
  
  Returns a Task that can be awaited.
  """
  @spec async_search([float()], [{term(), [float()]}], keyword()) :: Task.t()
  def async_search(query, corpus, opts \\ []) do
    Task.Supervisor.async(Mimo.Vector.TaskSupervisor, fn ->
      search(query, corpus, opts)
    end)
  end

  @doc """
  Performs a batch of searches in parallel.
  
  ## Parameters
  
    - `queries` - List of `{query_id, embedding}` tuples
    - `corpus` - Shared corpus for all queries
    - `opts` - Search options
  
  ## Returns
  
  Map of `query_id => [{id, similarity}, ...]`
  """
  @spec batch_search([{term(), [float()]}], [{term(), [float()]}], keyword()) ::
          %{term() => [{term(), float()}]}
  def batch_search(queries, corpus, opts \\ []) do
    queries
    |> Task.async_stream(
      fn {query_id, embedding} ->
        {query_id, search(embedding, corpus, opts)}
      end,
      max_concurrency: System.schedulers_online(),
      ordered: false
    )
    |> Enum.reduce(%{}, fn {:ok, {query_id, results}}, acc ->
      Map.put(acc, query_id, results)
    end)
  end
end
