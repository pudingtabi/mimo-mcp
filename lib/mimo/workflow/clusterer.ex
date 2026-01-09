defmodule Mimo.Workflow.Clusterer do
  @moduledoc """
  SPEC-053 Phase 1: Workflow Clustering

  Groups similar workflow patterns using graph edit distance
  and hierarchical clustering.

  ## Features

  - Graph representation of workflows
  - Edit distance calculation between workflows
  - Hierarchical clustering with configurable threshold
  - Cluster representatives selection

  ## Algorithm

  1. Convert each pattern's steps to a directed graph
  2. Calculate pairwise graph edit distances
  3. Apply agglomerative clustering
  4. Select representative pattern for each cluster
  """
  require Logger

  alias Mimo.Workflow.Pattern

  # Maximum edit distance for patterns to be in the same cluster
  @default_distance_threshold 0.3

  # Minimum cluster size to keep
  @min_cluster_size 2

  @type graph :: %{
          nodes: [String.t()],
          edges: [{String.t(), String.t()}]
        }

  @type cluster :: %{
          id: String.t(),
          patterns: [Pattern.t()],
          representative: Pattern.t(),
          centroid_distance: float()
        }

  @doc """
  Clusters workflow patterns by similarity.

  ## Options

    * `:threshold` - Maximum distance for same cluster (default: 0.3)
    * `:min_size` - Minimum patterns per cluster (default: 2)

  ## Returns

  A list of clusters, each containing related patterns and a representative.
  """
  @spec cluster_patterns([Pattern.t()], keyword()) :: {:ok, [cluster()]} | {:error, term()}
  def cluster_patterns(patterns, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, @default_distance_threshold)
    min_size = Keyword.get(opts, :min_size, @min_cluster_size)

    if length(patterns) < 2 do
      {:ok, []}
    else
      try do
        # Convert patterns to graphs
        graphs = Enum.map(patterns, fn p -> {p, pattern_to_graph(p)} end)

        # Calculate distance matrix
        distance_matrix = calculate_distance_matrix(graphs)

        # Perform hierarchical clustering
        clusters = hierarchical_cluster(patterns, distance_matrix, threshold)

        # Filter by minimum size and select representatives
        result =
          clusters
          |> Enum.filter(fn c -> length(c.patterns) >= min_size end)
          |> Enum.map(&select_representative/1)

        {:ok, result}
      rescue
        e ->
          Logger.error("Clustering failed: #{inspect(e)}")
          {:error, {:clustering_failed, e}}
      end
    end
  end

  @doc """
  Calculates the similarity between two patterns.

  Returns a value between 0 (identical) and 1 (completely different).
  """
  @spec pattern_distance(Pattern.t(), Pattern.t()) :: float()
  def pattern_distance(pattern1, pattern2) do
    graph1 = pattern_to_graph(pattern1)
    graph2 = pattern_to_graph(pattern2)
    graph_edit_distance(graph1, graph2)
  end

  @doc """
  Finds the most similar existing pattern to a new sequence.
  """
  @spec find_similar_pattern([map()], [Pattern.t()], float()) ::
          {:ok, Pattern.t(), float()} | :no_match
  def find_similar_pattern(sequence, patterns, threshold \\ @default_distance_threshold) do
    temp_pattern = %Pattern{
      id: "temp",
      name: "temp",
      steps: sequence
    }

    temp_graph = pattern_to_graph(temp_pattern)

    patterns
    |> Enum.map(fn p ->
      distance = graph_edit_distance(temp_graph, pattern_to_graph(p))
      {p, distance}
    end)
    |> Enum.filter(fn {_p, d} -> d <= threshold end)
    |> Enum.min_by(fn {_p, d} -> d end, fn -> nil end)
    |> case do
      nil -> :no_match
      {pattern, distance} -> {:ok, pattern, distance}
    end
  end

  defp pattern_to_graph(%Pattern{steps: steps}) do
    steps_to_graph(steps)
  end

  defp steps_to_graph(steps) do
    nodes =
      steps
      |> Enum.with_index()
      |> Enum.map(fn {step, idx} ->
        tool = step["tool"] || step[:tool] || ""
        op = step["operation"] || step[:operation] || ""
        "#{idx}:#{tool}.#{op}"
      end)

    edges =
      nodes
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [from, to] -> {from, to} end)

    %{nodes: nodes, edges: edges}
  end

  defp calculate_distance_matrix(pattern_graphs) do
    indexed = Enum.with_index(pattern_graphs)

    for {{_p1, g1}, i} <- indexed,
        {{_p2, g2}, j} <- indexed,
        i <= j,
        into: %{} do
      distance = if i == j, do: 0.0, else: graph_edit_distance(g1, g2)
      {{i, j}, distance}
    end
  end

  @doc """
  Calculates graph edit distance between two workflow graphs.

  Uses a simplified algorithm based on:
  - Node label differences
  - Edge presence/absence
  - Sequence alignment
  """
  def graph_edit_distance(%{nodes: nodes1, edges: edges1}, %{nodes: nodes2, edges: edges2}) do
    # Extract tool signatures (ignore position)
    sigs1 = Enum.map(nodes1, &extract_signature/1)
    sigs2 = Enum.map(nodes2, &extract_signature/1)

    # Calculate node edit cost (Levenshtein-like for sequences)
    node_distance = sequence_edit_distance(sigs1, sigs2)

    # Calculate edge edit cost
    edge_set1 = MapSet.new(edges1)
    edge_set2 = MapSet.new(edges2)

    edge_diff = MapSet.symmetric_difference(edge_set1, edge_set2) |> MapSet.size()
    total_edges = max(MapSet.size(edge_set1), MapSet.size(edge_set2))

    edge_distance = if total_edges > 0, do: edge_diff / total_edges, else: 0.0

    # Combined distance (weighted)
    node_distance * 0.7 + edge_distance * 0.3
  end

  defp extract_signature(node_label) do
    # Extract "tool.operation" from "idx:tool.operation"
    case String.split(node_label, ":", parts: 2) do
      [_, sig] -> sig
      [sig] -> sig
    end
  end

  defp sequence_edit_distance(seq1, seq2) do
    m = length(seq1)
    n = length(seq2)

    if m == 0 or n == 0 do
      1.0
    else
      # Dynamic programming for edit distance
      dp = init_dp_matrix(m, n)
      dp = fill_dp_matrix(dp, seq1, seq2, m, n)

      # Normalize by max length
      Map.get(dp, {m, n}, m + n) / max(m, n)
    end
  end

  defp init_dp_matrix(m, n) do
    row_init = for i <- 0..m, into: %{}, do: {{i, 0}, i}
    col_init = for j <- 0..n, into: %{}, do: {{0, j}, j}
    Map.merge(row_init, col_init)
  end

  defp fill_dp_matrix(dp, seq1, seq2, m, n) do
    seq1_indexed = seq1 |> Enum.with_index(1) |> Map.new(fn {v, i} -> {i, v} end)
    seq2_indexed = seq2 |> Enum.with_index(1) |> Map.new(fn {v, j} -> {j, v} end)

    for i <- 1..m, j <- 1..n, reduce: dp do
      acc ->
        cost = if seq1_indexed[i] == seq2_indexed[j], do: 0, else: 1

        min_val =
          Enum.min([
            Map.get(acc, {i - 1, j}, i) + 1,
            Map.get(acc, {i, j - 1}, j) + 1,
            Map.get(acc, {i - 1, j - 1}, i + j) + cost
          ])

        Map.put(acc, {i, j}, min_val)
    end
  end

  defp hierarchical_cluster(patterns, distance_matrix, threshold) do
    # Initialize: each pattern is its own cluster
    initial_clusters =
      patterns
      |> Enum.with_index()
      |> Enum.map(fn {p, idx} ->
        %{
          id: "cluster_#{idx}",
          patterns: [p],
          indices: [idx]
        }
      end)

    # Agglomerative clustering
    do_cluster(initial_clusters, distance_matrix, threshold)
  end

  defp do_cluster(clusters, _distance_matrix, _threshold) when length(clusters) <= 1 do
    clusters
  end

  defp do_cluster(clusters, distance_matrix, threshold) do
    # Find closest pair of clusters
    case find_closest_pair(clusters, distance_matrix) do
      nil ->
        clusters

      {c1, c2, distance} when distance <= threshold ->
        # Merge clusters
        merged = merge_clusters(c1, c2)
        remaining = clusters -- [c1, c2]
        do_cluster([merged | remaining], distance_matrix, threshold)

      _ ->
        clusters
    end
  end

  defp find_closest_pair(clusters, distance_matrix) do
    pairs =
      for c1 <- clusters,
          c2 <- clusters,
          c1.id < c2.id do
        distance = cluster_distance(c1, c2, distance_matrix)
        {c1, c2, distance}
      end

    if Enum.empty?(pairs) do
      nil
    else
      Enum.min_by(pairs, fn {_, _, d} -> d end)
    end
  end

  defp cluster_distance(cluster1, cluster2, distance_matrix) do
    # Average linkage
    distances =
      for i <- cluster1.indices,
          j <- cluster2.indices do
        key = if i <= j, do: {i, j}, else: {j, i}
        Map.get(distance_matrix, key, 1.0)
      end

    if Enum.empty?(distances), do: 1.0, else: Enum.sum(distances) / length(distances)
  end

  defp merge_clusters(c1, c2) do
    %{
      id: "#{c1.id}_#{c2.id}",
      patterns: c1.patterns ++ c2.patterns,
      indices: c1.indices ++ c2.indices
    }
  end

  defp select_representative(cluster) do
    # Select the pattern with highest success rate and usage
    representative =
      cluster.patterns
      |> Enum.max_by(fn p ->
        (p.success_rate || 0) * 0.6 + min((p.usage_count || 0) / 100, 1) * 0.4
      end)

    # Calculate centroid distance (average distance to other patterns)
    centroid_distance =
      if length(cluster.patterns) > 1 do
        rep_graph = pattern_to_graph(representative)

        distances =
          cluster.patterns
          |> Enum.reject(&(&1.id == representative.id))
          |> Enum.map(fn p -> graph_edit_distance(rep_graph, pattern_to_graph(p)) end)

        Enum.sum(distances) / length(distances)
      else
        0.0
      end

    %{
      id: cluster.id,
      patterns: cluster.patterns,
      representative: representative,
      centroid_distance: centroid_distance
    }
  end
end
