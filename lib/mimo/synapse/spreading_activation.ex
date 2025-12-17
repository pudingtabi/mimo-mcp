defmodule Mimo.Synapse.SpreadingActivation do
  @moduledoc """
  Spreading Activation retrieval with attention-weighted graph traversal.

  Combines neuroscience principles with machine learning techniques:

  ## Neuroscience Foundation: Spreading Activation (Collins & Loftus, 1975)

  Activation spreads from source nodes through the associative network,
  decaying with distance. Related concepts get activated proportionally
  to their connection strength.

  ## Machine Learning Enhancement: Attention Mechanism

  Instead of using raw edge weights, we compute attention scores that
  combine multiple signals:

  1. **Edge Weight** - Learned from Hebbian co-activation (LTP)
  2. **Embedding Similarity** - Semantic relatedness via cosine similarity
  3. **Recency** - Temporal relevance of target node
  4. **Access Frequency** - Usage-based importance

  Attention is normalized via softmax to create a probability distribution
  over neighbors, ensuring activation sums are bounded.

  ## Algorithm

  ```
  For each hop:
    For each active node:
      attention_scores = softmax([score(neighbor) for neighbor in neighbors])
      For each neighbor:
        neighbor.activation += node.activation × attention × decay_factor
  ```

  ## References

  - Collins & Loftus (1975) - Spreading Activation Theory
  - Vaswani et al. (2017) - Attention Is All You Need
  - Anderson (1983) - ACT-R Cognitive Architecture
  """

  require Logger

  import Ecto.Query
  alias Mimo.Repo
  alias Mimo.Synapse.{GraphNode, GraphEdge}
  alias Mimo.Vector.Math, as: VectorMath

  # ==========================================================================
  # Hyperparameters
  # ==========================================================================

  # Activation decays by this factor per hop
  @decay_factor 0.7

  # Softmax temperature: lower = sharper attention, higher = more uniform
  @temperature 1.0

  # Minimum activation to continue spreading
  @activation_threshold 0.01

  # Weight factors for attention scoring
  @edge_weight_factor 0.4
  @embedding_sim_factor 0.3
  @recency_factor 0.2
  @access_factor 0.1

  # ==========================================================================
  # Public API
  # ==========================================================================

  @doc """
  Activate nodes starting from a query, spreading through the graph.

  ## Parameters

    - `query_embedding` - Vector embedding of the query
    - `start_node_ids` - Initial nodes to activate (from vector search)
    - `opts` - Options:
      - `:max_hops` - Maximum spreading distance (default: 3)
      - `:top_k` - Number of results to return (default: 10)
      - `:include_start` - Include start nodes in results (default: true)

  ## Returns

  List of `{node_id, activation_score}` tuples, sorted by activation.

  ## Example

      # Get initial nodes from vector search
      start_nodes = VectorSearch.search(query_embedding, limit: 5)

      # Spread activation through graph
      results = SpreadingActivation.activate(query_embedding, start_node_ids)
  """
  @spec activate(list(), [String.t()], keyword()) :: [{String.t(), float()}]
  def activate(query_embedding, start_node_ids, opts \\ []) do
    max_hops = Keyword.get(opts, :max_hops, 3)
    top_k = Keyword.get(opts, :top_k, 10)
    include_start = Keyword.get(opts, :include_start, true)

    # Initialize activation from start nodes
    initial_activation = initialize_activation(query_embedding, start_node_ids)

    # Spread through network
    final_activation = spread(initial_activation, query_embedding, max_hops)

    # Filter and rank results
    final_activation
    |> maybe_filter_start_nodes(start_node_ids, include_start)
    |> Enum.sort_by(fn {_id, score} -> score end, :desc)
    |> Enum.take(top_k)
  end

  @doc """
  Activate from memory IDs (converts to graph nodes internally).
  """
  @spec activate_from_memories(list(), [integer()], keyword()) :: [{integer(), float()}]
  def activate_from_memories(query_embedding, memory_ids, opts \\ []) do
    # Convert memory IDs to graph node IDs
    node_ids = memory_ids_to_node_ids(memory_ids)

    # Run spreading activation
    results = activate(query_embedding, node_ids, opts)

    # Convert back to memory IDs
    results
    |> Enum.map(fn {node_id, score} -> {node_id_to_memory_id(node_id), score} end)
    |> Enum.reject(fn {mem_id, _} -> is_nil(mem_id) end)
  end

  # ==========================================================================
  # Core Algorithm
  # ==========================================================================

  defp initialize_activation(query_embedding, start_node_ids) do
    # Load nodes with embeddings
    nodes = load_nodes_with_data(start_node_ids)

    # Compute initial activation based on similarity to query
    Enum.reduce(nodes, %{}, fn node, acc ->
      similarity = compute_similarity(query_embedding, node)
      # Initial activation is similarity score
      Map.put(acc, node.id, max(0.1, similarity))
    end)
  end

  defp spread(activation, _query_embedding, 0), do: activation
  defp spread(activation, _query_embedding, _hops) when map_size(activation) == 0, do: activation

  defp spread(activation, query_embedding, hops_remaining) do
    # Get all active nodes above threshold
    active_nodes =
      activation
      |> Enum.filter(fn {_id, score} -> score >= @activation_threshold end)
      |> Enum.map(fn {id, _score} -> id end)

    if active_nodes == [] do
      activation
    else
      # Get neighbors for all active nodes
      neighbors_map = get_neighbors_batch(active_nodes)

      # Compute new activations
      new_activation =
        Enum.reduce(active_nodes, activation, fn node_id, acc ->
          source_activation = Map.get(acc, node_id, 0)
          neighbors = Map.get(neighbors_map, node_id, [])

          if neighbors == [] do
            acc
          else
            # Compute attention-weighted activation spread
            spread_to_neighbors(acc, node_id, source_activation, neighbors, query_embedding)
          end
        end)

      # Recurse with remaining hops
      spread(new_activation, query_embedding, hops_remaining - 1)
    end
  end

  defp spread_to_neighbors(activation, source_id, source_activation, neighbors, query_embedding) do
    # Compute attention scores for all neighbors
    attention_scores = compute_attention(source_id, neighbors, query_embedding)

    # Spread activation proportionally
    Enum.reduce(Enum.zip(neighbors, attention_scores), activation, fn {neighbor, attention}, acc ->
      # New activation = current + (source × attention × decay)
      propagated = source_activation * attention * @decay_factor
      current = Map.get(acc, neighbor.id, 0)
      Map.put(acc, neighbor.id, current + propagated)
    end)
  end

  # ==========================================================================
  # Attention Mechanism (ML Component)
  # ==========================================================================

  defp compute_attention(source_id, neighbors, query_embedding) do
    # Compute raw scores for each neighbor
    raw_scores =
      Enum.map(neighbors, fn neighbor ->
        compute_attention_score(source_id, neighbor, query_embedding)
      end)

    # Apply softmax normalization
    softmax(raw_scores)
  end

  defp compute_attention_score(_source_id, neighbor, query_embedding) do
    # Multi-factor attention score
    edge_weight_val = neighbor.edge_weight || 0.5
    embedding_sim_val = compute_similarity(query_embedding, neighbor)
    recency_val = compute_recency_score(neighbor)
    access_val = compute_access_score(neighbor)

    # Get learned weights from AttentionLearner (falls back to defaults if unavailable)
    learned = Mimo.Brain.AttentionLearner.get_weights()

    # Weighted combination using learned weights
    score =
      Map.get(learned, :edge_weight, @edge_weight_factor) * edge_weight_val +
        Map.get(learned, :embedding_sim, @embedding_sim_factor) * embedding_sim_val +
        Map.get(learned, :recency, @recency_factor) * recency_val +
        Map.get(learned, :access, @access_factor) * access_val

    # Ensure positive
    max(0.01, score)
  end

  @doc """
  Softmax function with temperature scaling.

  softmax(x_i) = exp(x_i / T) / Σ exp(x_j / T)

  Temperature controls sharpness:
  - T < 1: Sharper distribution (winner-take-all)
  - T = 1: Standard softmax
  - T > 1: Flatter distribution (more uniform)
  """
  def softmax(scores, temperature \\ @temperature) do
    # Subtract max for numerical stability
    max_score = Enum.max(scores, fn -> 0 end)

    exp_scores =
      Enum.map(scores, fn s ->
        :math.exp((s - max_score) / temperature)
      end)

    sum = Enum.sum(exp_scores)

    if sum == 0 do
      # Uniform distribution fallback
      n = length(scores)
      List.duplicate(1.0 / max(n, 1), n)
    else
      Enum.map(exp_scores, &(&1 / sum))
    end
  end

  # ==========================================================================
  # Similarity & Scoring Helpers
  # ==========================================================================

  defp compute_similarity(query_embedding, node) when is_list(query_embedding) do
    node_embedding = get_node_embedding(node)

    if node_embedding && length(node_embedding) == length(query_embedding) do
      VectorMath.cosine_similarity(query_embedding, node_embedding)
    else
      # Default similarity when embeddings unavailable
      0.5
    end
  end

  defp compute_similarity(_, _), do: 0.5

  defp get_node_embedding(%{embedding: emb}) when is_list(emb) and emb != [], do: emb
  defp get_node_embedding(%{properties: %{"embedding" => emb}}) when is_list(emb), do: emb
  defp get_node_embedding(_), do: nil

  defp compute_recency_score(%{last_accessed_at: nil}), do: 0.5

  defp compute_recency_score(%{last_accessed_at: accessed_at}) do
    # Exponential decay based on time since access
    seconds_ago = DateTime.diff(DateTime.utc_now(), accessed_at, :second)
    days_ago = seconds_ago / 86_400

    # Half-life of 7 days
    :math.exp(-0.1 * days_ago)
  end

  defp compute_recency_score(_), do: 0.5

  defp compute_access_score(%{access_count: count}) when is_integer(count) and count > 0 do
    # Logarithmic scaling of access count
    # Normalize to ~1 at 100 accesses
    (:math.log(1 + count) / :math.log(1 + 100))
    |> min(1.0)
  end

  defp compute_access_score(_), do: 0.3

  # ==========================================================================
  # Database Helpers
  # ==========================================================================

  defp load_nodes_with_data(node_ids) when is_list(node_ids) do
    Repo.all(
      from(n in GraphNode,
        where: n.id in ^node_ids,
        select: %{
          id: n.id,
          name: n.name,
          node_type: n.node_type,
          properties: n.properties
        }
      )
    )
  end

  defp get_neighbors_batch(node_ids) do
    # Get all edges from these nodes with target node data
    edges =
      Repo.all(
        from(e in GraphEdge,
          join: t in GraphNode,
          on: e.target_node_id == t.id,
          where: e.source_node_id in ^node_ids,
          select: %{
            source_id: e.source_node_id,
            id: t.id,
            name: t.name,
            node_type: t.node_type,
            properties: t.properties,
            edge_weight: e.weight,
            edge_type: e.edge_type,
            last_accessed_at: e.last_accessed_at,
            access_count: e.access_count
          }
        )
      )

    # Group by source node
    Enum.group_by(edges, & &1.source_id)
  end

  defp memory_ids_to_node_ids(memory_ids) do
    node_names = Enum.map(memory_ids, &"memory:#{&1}")

    Repo.all(
      from(n in GraphNode,
        where: n.name in ^node_names,
        select: n.id
      )
    )
  end

  defp node_id_to_memory_id(node_id) do
    case Repo.one(from(n in GraphNode, where: n.id == ^node_id, select: n.name)) do
      "memory:" <> id_str ->
        case Integer.parse(id_str) do
          {id, ""} -> id
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp maybe_filter_start_nodes(activation, _start_ids, true), do: activation

  defp maybe_filter_start_nodes(activation, start_ids, false) do
    start_set = MapSet.new(start_ids)
    Enum.reject(activation, fn {id, _} -> MapSet.member?(start_set, id) end)
  end
end
