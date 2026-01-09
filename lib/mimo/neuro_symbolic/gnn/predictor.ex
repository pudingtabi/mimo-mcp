defmodule Mimo.NeuroSymbolic.GnnPredictor do
  @moduledoc """
  Graph-based predictor using memory embeddings.

  Phase 1: Uses existing embedding infrastructure for real predictions.
  This is not a true GNN yet, but provides real computation instead of stubs.

  ## Capabilities

  - `train/2` - Compute and cache cluster centroids from memory embeddings
  - `predict_links/2` - Find potential links based on embedding similarity
  - `cluster_similar/2` - Group nodes by embedding proximity

  ## Future Evolution

  As Mimo learns more, this module will evolve:
  - Phase 2: Message passing between connected nodes
  - Phase 3: Learnable aggregation functions
  - Phase 4: Full GNN with backpropagation (requires external training)
  """

  require Logger

  alias Mimo.Brain.Engram
  alias Mimo.Repo
  alias Mimo.Vector.Math, as: VectorMath

  import Ecto.Query

  # Model state stored in ETS for persistence across calls
  @model_table :gnn_predictor_model

  @doc """
  Train the predictor by computing cluster centroids from memory embeddings.

  This is Phase 1 "training" - we compute k-means style centroids from all
  memory embeddings, which can then be used for clustering and link prediction.

  ## Options

  - `:k` - Number of clusters (default: 10)
  - `:sample_size` - Max memories to sample for training (default: 1000)

  ## Returns

  `{:ok, model}` where model contains centroids and metadata.
  """
  @spec train(map(), integer()) :: {:ok, map()} | {:error, term()}
  def train(opts \\ %{}, _epochs \\ 100) do
    k = Map.get(opts, :k, 10)
    sample_size = Map.get(opts, :sample_size, 1000)

    Logger.info("[GnnPredictor] Training with k=#{k}, sample_size=#{sample_size}")

    # Get memories with embeddings (need full engram to dequantize)
    engrams =
      from(e in Engram,
        where: not is_nil(e.embedding_int8),
        order_by: [desc: e.importance],
        limit: ^sample_size
      )
      |> Repo.all()

    # Extract embeddings using proper dequantization
    memories_with_embeddings =
      engrams
      |> Enum.map(fn engram ->
        case Engram.get_embedding(engram) do
          {:ok, emb} when is_list(emb) and emb != [] ->
            %{id: engram.id, embedding: emb, category: engram.category}

          _ ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    if length(memories_with_embeddings) < k do
      {:error, "Not enough memories with embeddings (#{length(memories_with_embeddings)} < #{k})"}
    else
      # Extract embeddings
      embeddings = Enum.map(memories_with_embeddings, & &1.embedding)

      # Compute centroids using k-means++ initialization then Lloyd's algorithm
      centroids = compute_centroids(embeddings, k)

      # Assign each memory to its nearest centroid
      assignments = assign_to_clusters(memories_with_embeddings, centroids)

      # Build model
      model = %{
        version: 1,
        trained_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        k: k,
        sample_size: length(memories_with_embeddings),
        centroids: centroids,
        cluster_sizes: count_cluster_sizes(assignments, k)
      }

      # Store in ETS for later use
      ensure_model_table()
      :ets.insert(@model_table, {:current_model, model})

      Logger.info(
        "[GnnPredictor] Training complete. #{k} clusters from #{length(memories_with_embeddings)} memories"
      )

      {:ok, model}
    end
  end

  @doc """
  Predict potential links between nodes based on embedding similarity.

  Finds node pairs that are semantically similar but not yet connected
  in the knowledge graph.

  ## Parameters

  - `model` - The trained model (or nil to use cached)
  - `node_ids` - List of node IDs to find links for (memory IDs)

  ## Returns

  List of predicted links: `[%{from: id, to: id, score: float, reason: string}]`
  """
  @spec predict_links(map() | nil, [integer()]) :: [map()]
  def predict_links(model, node_ids) when is_list(node_ids) do
    model = model || get_cached_model()

    if is_nil(model) do
      Logger.warning("[GnnPredictor] No model available, run train/2 first")
      []
    else
      do_predict_links(node_ids)
    end
  end

  def predict_links(_, _), do: []

  @doc """
  Cluster memories by embedding similarity.

  Groups memories into clusters based on their semantic embeddings.
  Uses the trained centroids for assignment.

  ## Parameters

  - `model` - The trained model (or nil to use cached)
  - `node_type` - Atom representing what to cluster (:memory, :all)

  ## Returns

  List of clusters: `[%{cluster_id: int, centroid: [...], members: [ids], category_breakdown: %{}}]`
  """
  @spec cluster_similar(map() | nil, atom()) :: [map()]
  def cluster_similar(model, node_type \\ :memory) do
    model = model || get_cached_model()

    if is_nil(model) do
      Logger.warning("[GnnPredictor] No model available, run train/2 first")
      []
    else
      do_cluster_similar(model, node_type)
    end
  end

  # ============================================================================
  # Private Implementation
  # ============================================================================

  defp ensure_model_table do
    if :ets.info(@model_table) == :undefined do
      :ets.new(@model_table, [:named_table, :set, :public])
    end
  end

  defp get_cached_model do
    ensure_model_table()

    case :ets.lookup(@model_table, :current_model) do
      [{:current_model, model}] -> model
      [] -> nil
    end
  end

  # K-means++ initialization + Lloyd's algorithm
  defp compute_centroids(embeddings, k) do
    # K-means++ initialization
    initial_centroids = kmeans_plus_plus_init(embeddings, k)

    # Lloyd's algorithm (iterate to refine)
    refine_centroids(embeddings, initial_centroids, max_iterations: 10)
  end

  defp kmeans_plus_plus_init(embeddings, k) do
    # Pick first centroid randomly
    first = Enum.random(embeddings)
    centroids = [first]

    # Pick remaining centroids weighted by distance
    Enum.reduce(2..k, centroids, fn _i, acc ->
      # Compute distances to nearest centroid for each point
      distances =
        Enum.map(embeddings, fn emb ->
          min_dist =
            Enum.map(acc, fn c -> 1.0 - cosine_similarity(emb, c) end)
            |> Enum.min()

          # Square for probability weighting
          {emb, min_dist * min_dist}
        end)

      # Weighted random selection
      total = Enum.reduce(distances, 0, fn {_, d}, sum -> sum + d end)

      if total == 0 do
        [Enum.random(embeddings) | acc]
      else
        threshold = :rand.uniform() * total
        {selected, _} = weighted_select(distances, threshold)
        [selected | acc]
      end
    end)
  end

  defp weighted_select([{emb, dist} | rest], threshold) do
    if threshold <= dist do
      {emb, dist}
    else
      weighted_select(rest, threshold - dist)
    end
  end

  defp weighted_select([], _), do: {[], 0}

  defp refine_centroids(embeddings, centroids, opts) do
    max_iter = Keyword.get(opts, :max_iterations, 10)
    refine_centroids_loop(embeddings, centroids, 0, max_iter)
  end

  defp refine_centroids_loop(_embeddings, centroids, iter, max_iter) when iter >= max_iter do
    centroids
  end

  defp refine_centroids_loop(embeddings, centroids, iter, max_iter) do
    # Assign each embedding to nearest centroid
    assignments =
      Enum.map(embeddings, fn emb ->
        {idx, _} =
          centroids
          |> Enum.with_index()
          |> Enum.max_by(fn {c, _} -> cosine_similarity(emb, c) end)

        {emb, idx}
      end)

    # Compute new centroids as mean of assigned points
    new_centroids =
      0..(length(centroids) - 1)
      |> Enum.map(fn cluster_idx ->
        members =
          assignments
          |> Enum.filter(fn {_, idx} -> idx == cluster_idx end)
          |> Enum.map(fn {emb, _} -> emb end)

        if members == [] do
          Enum.at(centroids, cluster_idx)
        else
          compute_mean_embedding(members)
        end
      end)

    # Check for convergence (centroids didn't change much)
    if centroids_converged?(centroids, new_centroids) do
      new_centroids
    else
      refine_centroids_loop(embeddings, new_centroids, iter + 1, max_iter)
    end
  end

  defp centroids_converged?(old, new) do
    Enum.zip(old, new)
    |> Enum.all?(fn {o, n} -> cosine_similarity(o, n) > 0.999 end)
  end

  defp compute_mean_embedding(embeddings) do
    dim = length(List.first(embeddings))

    Enum.reduce(embeddings, List.duplicate(0.0, dim), fn emb, acc ->
      Enum.zip(emb, acc) |> Enum.map(fn {a, b} -> a + b end)
    end)
    |> Enum.map(&(&1 / length(embeddings)))
  end

  defp assign_to_clusters(memories, centroids) do
    Enum.map(memories, fn mem ->
      {cluster_idx, similarity} =
        centroids
        |> Enum.with_index()
        |> Enum.map(fn {c, idx} -> {idx, cosine_similarity(mem.embedding, c)} end)
        |> Enum.max_by(fn {_, sim} -> sim end)

      Map.merge(mem, %{cluster: cluster_idx, similarity: similarity})
    end)
  end

  defp count_cluster_sizes(assignments, k) do
    counts = Enum.group_by(assignments, & &1.cluster)

    0..(k - 1)
    |> Enum.map(fn i -> {i, length(Map.get(counts, i, []))} end)
    |> Enum.into(%{})
  end

  defp do_predict_links(node_ids) do
    # Get full engrams for the specified nodes to dequantize embeddings
    engrams =
      from(e in Engram,
        where: e.id in ^node_ids and not is_nil(e.embedding_int8)
      )
      |> Repo.all()

    nodes =
      engrams
      |> Enum.map(fn engram ->
        case Engram.get_embedding(engram) do
          {:ok, emb} when is_list(emb) and emb != [] ->
            %{id: engram.id, embedding: emb, category: engram.category}

          _ ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    if nodes == [] do
      []
    else
      # For each node, find similar nodes not in the input set
      nodes
      |> Enum.flat_map(fn node ->
        find_similar_nodes(node, node_ids)
      end)
      |> Enum.sort_by(& &1.score, :desc)
      # Top 20 predictions
      |> Enum.take(20)
    end
  end

  defp find_similar_nodes(node, exclude_ids) do
    # Get candidate engrams (not in exclude list)
    engrams =
      from(e in Engram,
        where: e.id not in ^exclude_ids and not is_nil(e.embedding_int8),
        order_by: [desc: e.importance],
        limit: 100
      )
      |> Repo.all()

    candidates =
      engrams
      |> Enum.map(fn engram ->
        case Engram.get_embedding(engram) do
          {:ok, emb} when is_list(emb) and emb != [] ->
            %{id: engram.id, embedding: emb, category: engram.category}

          _ ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    # Compute similarity and filter
    candidates
    |> Enum.map(fn cand ->
      score = cosine_similarity(node.embedding, cand.embedding)

      %{
        from: node.id,
        to: cand.id,
        score: Float.round(score, 4),
        from_category: node.category,
        to_category: cand.category,
        reason: "embedding_similarity"
      }
    end)
    # Only predictions with >50% similarity
    |> Enum.filter(&(&1.score > 0.5))
  end

  defp do_cluster_similar(model, _node_type) do
    centroids = model.centroids

    # Get all engrams with embeddings
    engrams =
      from(e in Engram,
        where: not is_nil(e.embedding_int8)
      )
      |> Repo.all()

    memories =
      engrams
      |> Enum.map(fn engram ->
        case Engram.get_embedding(engram) do
          {:ok, emb} when is_list(emb) and emb != [] ->
            %{id: engram.id, embedding: emb, category: engram.category}

          _ ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    # Assign to clusters
    assignments = assign_to_clusters(memories, centroids)

    # Group by cluster
    grouped = Enum.group_by(assignments, & &1.cluster)

    # Format output
    Enum.map(0..(length(centroids) - 1), fn cluster_id ->
      members = Map.get(grouped, cluster_id, [])
      categories = Enum.frequencies_by(members, & &1.category)

      %{
        cluster_id: cluster_id,
        size: length(members),
        # Sample
        member_ids: Enum.map(members, & &1.id) |> Enum.take(20),
        category_breakdown: categories,
        avg_similarity: avg_cluster_similarity(members)
      }
    end)
    # Only non-empty clusters
    |> Enum.filter(&(&1.size > 0))
    |> Enum.sort_by(& &1.size, :desc)
  end

  defp avg_cluster_similarity(members) do
    if length(members) < 2 do
      1.0
    else
      sims =
        members
        |> Enum.map(& &1.similarity)
        |> Enum.filter(&is_number/1)

      if sims == [] do
        0.0
      else
        Float.round(Enum.sum(sims) / length(sims), 4)
      end
    end
  end

  # Use Rust NIF if available, fallback to pure Elixir
  defp cosine_similarity(a, b) when is_list(a) and is_list(b) and a != [] and b != [] do
    if VectorMath.nif_loaded?() do
      case VectorMath.cosine_similarity(a, b) do
        {:ok, value} when is_number(value) -> value
        value when is_number(value) -> value
        _ -> cosine_similarity_elixir(a, b)
      end
    else
      cosine_similarity_elixir(a, b)
    end
  end

  defp cosine_similarity(_, _), do: 0.0

  defp cosine_similarity_elixir(a, b) do
    dot = Enum.zip(a, b) |> Enum.reduce(0, fn {x, y}, acc -> acc + x * y end)
    norm_a = :math.sqrt(Enum.reduce(a, 0, fn x, acc -> acc + x * x end))
    norm_b = :math.sqrt(Enum.reduce(b, 0, fn x, acc -> acc + x * x end))

    if norm_a == 0 or norm_b == 0 do
      0.0
    else
      dot / (norm_a * norm_b)
    end
  end
end
