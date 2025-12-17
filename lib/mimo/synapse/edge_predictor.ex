defmodule Mimo.Synapse.EdgePredictor do
  @moduledoc """
  Predicts potential graph edges using embedding similarity.

  ## Neuroscience Foundation: Pattern Completion

  The hippocampus performs pattern completion - given a partial cue,
  it reconstructs related memories. This module implements a computational
  analog using embedding similarity to predict which memories should be
  connected but aren't yet.

  Reference: O'Reilly & McClelland (1994) - Hippocampal Conjunctive Encoding

  ## Machine Learning Approach: k-NN Edge Prediction

  1. For each memory, find k nearest neighbors by embedding similarity
  2. If similarity > threshold AND no edge exists, predict potential edge
  3. Rank predictions by similarity score
  4. Create edges based on prediction confidence

  ## Algorithm

  ```
  For each memory M:
    neighbors = kNN(M.embedding, k=10)
    For each neighbor N:
      if similarity(M, N) > 0.7 AND !edge_exists(M, N):
        predicted_edges.add((M, N, similarity))
  ```

  ## Usage

  ```elixir
  # Get top predicted edges for a memory
  predictions = EdgePredictor.predict_for(memory_id, limit: 5)

  # Auto-create edges for highly similar memories
  EdgePredictor.materialize_predictions(min_similarity: 0.8)
  ```
  """

  require Logger

  import Ecto.Query
  alias Mimo.{Repo, Brain.Engram}
  alias Mimo.Synapse.{GraphNode, GraphEdge}
  alias Mimo.Vector.Math, as: VectorMath

  # ==========================================================================
  # Configuration
  # ==========================================================================

  # Minimum cosine similarity to consider an edge
  @similarity_threshold 0.7

  # Number of nearest neighbors to consider
  @k_neighbors 10

  # Initial edge weight for predicted edges
  @predicted_edge_weight 0.2

  # Edge type for predicted edges (uses existing :relates_to from schema)
  @edge_type :relates_to

  # ==========================================================================
  # Public API
  # ==========================================================================

  @doc """
  Predict potential edges for a specific memory.

  Returns a list of {memory_id, similarity_score} tuples for memories
  that are semantically similar but not yet connected.

  ## Options

    - `:limit` - Maximum predictions to return (default: 5)
    - `:min_similarity` - Minimum similarity threshold (default: 0.7)
  """
  @spec predict_for(integer(), keyword()) :: [{integer(), float()}]
  def predict_for(memory_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)
    min_sim = Keyword.get(opts, :min_similarity, @similarity_threshold)

    # Get the source memory with embedding
    case get_memory_with_embedding(memory_id) do
      nil ->
        []

      source ->
        # Find similar memories
        similar = find_similar_memories(source, @k_neighbors * 2)

        # Filter out already-connected memories
        existing_edges = get_existing_edge_targets(memory_id)

        similar
        |> Enum.reject(fn {id, _sim} -> id == memory_id || id in existing_edges end)
        |> Enum.filter(fn {_id, sim} -> sim >= min_sim end)
        |> Enum.take(limit)
    end
  end

  @doc """
  Predict edges for all memories with embeddings.

  Returns a map of source_id => [{target_id, similarity}, ...]

  ## Options

    - `:batch_size` - Process memories in batches (default: 100)
    - `:min_similarity` - Minimum similarity (default: 0.7)
    - `:limit_per_memory` - Max predictions per memory (default: 3)
  """
  @spec predict_all(keyword()) :: map()
  def predict_all(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 100)
    min_sim = Keyword.get(opts, :min_similarity, @similarity_threshold)
    limit_per = Keyword.get(opts, :limit_per_memory, 3)

    # Get all memory IDs with embeddings
    memory_ids = get_memories_with_embeddings(batch_size)

    Enum.reduce(memory_ids, %{}, fn id, acc ->
      predictions = predict_for(id, limit: limit_per, min_similarity: min_sim)

      if predictions != [] do
        Map.put(acc, id, predictions)
      else
        acc
      end
    end)
  end

  @doc """
  Materialize predicted edges into the graph.

  Creates actual graph edges for high-confidence predictions.

  ## Options

    - `:min_similarity` - Only materialize if similarity >= threshold (default: 0.8)
    - `:max_edges` - Maximum edges to create (default: 50)
    - `:dry_run` - If true, return predictions without creating edges (default: false)

  Returns the number of edges created.
  """
  @spec materialize_predictions(keyword()) :: {:ok, integer()} | {:error, term()}
  def materialize_predictions(opts \\ []) do
    min_sim = Keyword.get(opts, :min_similarity, 0.8)
    max_edges = Keyword.get(opts, :max_edges, 50)
    dry_run = Keyword.get(opts, :dry_run, false)

    predictions = predict_all(min_similarity: min_sim, limit_per_memory: 3)

    # Flatten and sort by similarity
    all_predictions =
      predictions
      |> Enum.flat_map(fn {source_id, targets} ->
        Enum.map(targets, fn {target_id, sim} -> {source_id, target_id, sim} end)
      end)
      |> Enum.sort_by(fn {_s, _t, sim} -> sim end, :desc)
      |> Enum.take(max_edges)

    if dry_run do
      {:ok, length(all_predictions)}
    else
      created =
        Enum.reduce(all_predictions, 0, fn {source_id, target_id, similarity}, count ->
          case create_predicted_edge(source_id, target_id, similarity) do
            :ok -> count + 1
            :exists -> count
            :error -> count
          end
        end)

      Logger.info("EdgePredictor: materialized #{created} predicted edges")
      {:ok, created}
    end
  end

  @doc """
  Get prediction statistics.
  """
  def stats do
    # Count edges created by edge_predictor (identified by source field)
    predicted_edge_count =
      Repo.one(
        from(e in GraphEdge,
          where: e.source == "edge_predictor",
          select: count(e.id)
        )
      ) || 0

    total_engrams_with_embeddings =
      Repo.one(
        from(e in Engram,
          where: not is_nil(e.embedding),
          select: count(e.id)
        )
      ) || 0

    %{
      predicted_edges_created: predicted_edge_count,
      engrams_with_embeddings: total_engrams_with_embeddings,
      similarity_threshold: @similarity_threshold,
      edge_type: @edge_type
    }
  end

  # ==========================================================================
  # Private Implementation
  # ==========================================================================

  defp get_memory_with_embedding(memory_id) do
    Repo.one(
      from(e in Engram,
        where: e.id == ^memory_id and not is_nil(e.embedding),
        select: %{id: e.id, embedding: e.embedding}
      )
    )
  end

  defp get_memories_with_embeddings(limit) do
    Repo.all(
      from(e in Engram,
        where: not is_nil(e.embedding),
        select: e.id,
        limit: ^limit
      )
    )
  end

  defp find_similar_memories(source, limit) do
    # Get all embeddings (in production, use HNSW index for efficiency)
    candidates =
      Repo.all(
        from(e in Engram,
          where: e.id != ^source.id and not is_nil(e.embedding),
          select: %{id: e.id, embedding: e.embedding},
          limit: 500
        )
      )

    source_emb = normalize_embedding(source.embedding)

    if source_emb do
      candidates
      |> Enum.map(fn c ->
        target_emb = normalize_embedding(c.embedding)

        similarity =
          if target_emb && length(target_emb) == length(source_emb) do
            VectorMath.cosine_similarity(source_emb, target_emb)
          else
            0.0
          end

        {c.id, similarity}
      end)
      |> Enum.filter(fn {_id, sim} -> sim > 0 end)
      |> Enum.sort_by(fn {_id, sim} -> sim end, :desc)
      |> Enum.take(limit)
    else
      []
    end
  end

  defp normalize_embedding(embedding) when is_list(embedding), do: embedding
  defp normalize_embedding(%{data: data}) when is_list(data), do: data
  defp normalize_embedding(_), do: nil

  defp get_existing_edge_targets(memory_id) do
    node_name = "memory:#{memory_id}"

    # Get the graph node for this memory
    case Repo.one(from(n in GraphNode, where: n.name == ^node_name, select: n.id)) do
      nil ->
        []

      node_id ->
        # Get all connected node IDs
        Repo.all(
          from(e in GraphEdge,
            where: e.source_node_id == ^node_id,
            join: t in GraphNode,
            on: e.target_node_id == t.id,
            select: t.name
          )
        )
        |> Enum.flat_map(fn name ->
          case String.split(name, ":") do
            ["memory", id_str] ->
              case Integer.parse(id_str) do
                {id, ""} -> [id]
                _ -> []
              end

            _ ->
              []
          end
        end)
    end
  end

  defp create_predicted_edge(source_id, target_id, similarity) do
    source_node = ensure_node("memory:#{source_id}", source_id)
    target_node = ensure_node("memory:#{target_id}", target_id)

    if source_node && target_node do
      # Check if edge already exists
      existing =
        Repo.one(
          from(e in GraphEdge,
            where:
              e.source_node_id == ^source_node and
                e.target_node_id == ^target_node,
            limit: 1
          )
        )

      if existing do
        :exists
      else
        case Repo.insert(%GraphEdge{
               source_node_id: source_node,
               target_node_id: target_node,
               edge_type: @edge_type,
               weight: @predicted_edge_weight + similarity * 0.3,
               properties: %{
                 "source" => "edge_predictor",
                 "similarity" => similarity,
                 "predicted_at" => DateTime.utc_now() |> DateTime.to_iso8601()
               },
               source: "edge_predictor"
             }) do
          {:ok, _} -> :ok
          _ -> :error
        end
      end
    else
      :error
    end
  end

  defp ensure_node(name, memory_id) do
    case Repo.one(from(n in GraphNode, where: n.name == ^name, select: n.id)) do
      nil ->
        case Repo.insert(%GraphNode{
               node_type: :concept,
               name: name,
               properties: %{"memory_id" => memory_id, "source" => "edge_predictor"}
             }) do
          {:ok, node} -> node.id
          _ -> nil
        end

      id ->
        id
    end
  end
end
