defmodule Mimo.Synapse.QueryEngine do
  @moduledoc """
  Hybrid query engine combining graph traversal with vector search.

  Implements Graph RAG: uses the graph structure to retrieve
  more relevant and contextual information for LLM queries.

  ## Algorithm

  1. Generate embedding for query text
  2. Find semantically similar seed nodes (vector search)
  3. Expand context via graph traversal (BFS from seeds)
  4. Rank nodes by combined score (similarity + graph structure)
  5. Assemble coherent context for LLM

  ## Example

      # Hybrid query
      {:ok, result} = QueryEngine.query("How does authentication work?")

      # Code-focused query
      {:ok, result} = QueryEngine.query_code("JWT validation")

      # Get context around a node
      {:ok, context} = QueryEngine.node_context(node_id)
  """

  require Logger
  alias Mimo.Synapse.{Graph, Traversal}
  alias Mimo.Repo

  import Ecto.Query

  @type query_result :: %{
          nodes: [Graph.GraphNode.t()],
          edges: [Graph.GraphEdge.t()],
          context: String.t(),
          relevance_scores: map()
        }

  # ============================================
  # Hybrid Search
  # ============================================

  @doc """
  Execute a hybrid query: vector search + graph expansion.

  ## Steps

  1. Generate embedding for query
  2. Find semantically similar nodes
  3. Expand via graph traversal
  4. Rank and assemble context

  ## Options

    - `:max_nodes` - Maximum nodes in result (default: 20)
    - `:expansion_hops` - Graph expansion depth (default: 2)
    - `:node_types` - Filter by node types (default: all)
    - `:similarity_threshold` - Minimum similarity for seed nodes (default: 0.5)

  ## Returns

  `{:ok, %{nodes: [...], edges: [...], context: "...", relevance_scores: %{...}}}`
  """
  @spec query(String.t(), keyword()) :: {:ok, query_result()} | {:error, term()}
  def query(query_text, opts \\ []) do
    max_nodes = Keyword.get(opts, :max_nodes, 20)
    expansion_hops = Keyword.get(opts, :expansion_hops, 2)
    node_types = Keyword.get(opts, :node_types, Graph.node_types())
    _similarity_threshold = Keyword.get(opts, :similarity_threshold, 0.5)

    # Step 1: Find seed nodes via text search (vector search would be better)
    seed_nodes = find_seed_nodes(query_text, node_types, max_nodes)

    # Step 2: Expand graph context from seeds
    expanded_context = expand_graph_context(seed_nodes, expansion_hops)

    # Step 3: Rank nodes
    ranked_nodes = rank_nodes(seed_nodes ++ expanded_context, query_text)

    # Step 4: Get edges between result nodes
    result_node_ids = Enum.take(ranked_nodes, max_nodes) |> Enum.map(& &1.node.id)
    edges = get_connecting_edges(result_node_ids)

    # Step 5: Assemble context string
    context = assemble_context(ranked_nodes, max_nodes)

    # Build relevance scores map
    relevance_scores =
      ranked_nodes
      |> Enum.take(max_nodes)
      |> Enum.map(fn %{node: node, score: score} -> {node.id, score} end)
      |> Map.new()

    {:ok,
     %{
       nodes: Enum.take(ranked_nodes, max_nodes) |> Enum.map(& &1.node),
       edges: edges,
       context: context,
       relevance_scores: relevance_scores
     }}
  end

  @doc """
  Query for code-related information.

  Prioritizes code nodes (functions, modules, files).
  """
  @spec query_code(String.t(), keyword()) :: {:ok, query_result()}
  def query_code(query_text, opts \\ []) do
    opts =
      Keyword.merge(opts,
        node_types: [:function, :module, :file, :external_lib]
      )

    query(query_text, opts)
  end

  @doc """
  Query for conceptual information.

  Prioritizes concepts and memories.
  """
  @spec query_concepts(String.t(), keyword()) :: {:ok, query_result()}
  def query_concepts(query_text, opts \\ []) do
    opts =
      Keyword.merge(opts,
        node_types: [:concept, :memory]
      )

    query(query_text, opts)
  end

  # ============================================
  # Context Retrieval
  # ============================================

  @doc """
  Find all code related to a concept.

  Traverses from concept to all implementing code.
  """
  @spec code_for_concept(String.t(), keyword()) :: {:ok, [Graph.GraphNode.t()]} | {:error, term()}
  def code_for_concept(concept_name, opts \\ []) do
    max_results = Keyword.get(opts, :max_results, 50)

    case Graph.get_node(:concept, concept_name) do
      nil ->
        {:error, :concept_not_found}

      concept_node ->
        # Find all nodes that implement this concept
        implementing_nodes =
          Graph.incoming_edges(concept_node.id, types: [:implements])
          |> Enum.map(& &1.source_node)
          |> Enum.take(max_results)

        # Also traverse from implementing nodes
        expanded =
          implementing_nodes
          |> Enum.flat_map(fn node ->
            Traversal.bfs(node.id, max_depth: 1, direction: :both)
            |> Enum.map(& &1.node)
          end)
          |> Enum.uniq_by(& &1.id)
          |> Enum.take(max_results)

        {:ok, implementing_nodes ++ expanded}
    end
  end

  @doc """
  Get the full context around a specific node.

  Returns the node, its neighbors, and formatted context.
  """
  @spec node_context(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def node_context(node_id, opts \\ []) do
    hops = Keyword.get(opts, :hops, 2)

    case Graph.get_node_by_id(node_id) do
      nil ->
        {:error, :node_not_found}

      node ->
        # Get ego graph
        subgraph = Traversal.ego_graph(node_id, hops: hops)

        # Format context
        context = format_node_context_string(node, subgraph)

        {:ok,
         %{
           node: node,
           neighbors: subgraph.nodes,
           edges: subgraph.edges,
           context: context
         }}
    end
  end

  @doc """
  Find related nodes by multiple criteria.

  Combines text search, type filtering, and graph proximity.
  """
  @spec find_related(String.t(), keyword()) :: [Graph.GraphNode.t()]
  def find_related(query_text, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    node_types = Keyword.get(opts, :node_types, Graph.node_types())
    from_node_id = Keyword.get(opts, :from_node_id)

    # Text search
    text_matches = Graph.search_nodes(query_text, types: node_types, limit: limit)

    # If starting from a specific node, add graph neighbors
    graph_matches =
      if from_node_id do
        Traversal.bfs(from_node_id, max_depth: 2, direction: :both)
        |> Enum.map(& &1.node)
        |> Enum.filter(&(&1.node_type in node_types))
      else
        []
      end

    # Combine and deduplicate
    (text_matches ++ graph_matches)
    |> Enum.uniq_by(& &1.id)
    |> Enum.take(limit)
  end

  # ============================================
  # Graph Exploration
  # ============================================

  @doc """
  Explore the graph from a starting query.

  Returns a structured exploration result with:
  - Matched nodes
  - Related concepts
  - Connected code
  - Relevant memories
  """
  @spec explore(String.t(), keyword()) :: {:ok, map()}
  def explore(query_text, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    # Find matching nodes across all types
    concepts = Graph.search_nodes(query_text, types: [:concept], limit: limit)
    code = Graph.search_nodes(query_text, types: [:function, :module, :file], limit: limit)
    libs = Graph.search_nodes(query_text, types: [:external_lib], limit: limit)
    memories = Graph.search_nodes(query_text, types: [:memory], limit: limit)

    # Get connections between found nodes
    all_ids = Enum.map(concepts ++ code ++ libs ++ memories, & &1.id)
    edges = get_connecting_edges(all_ids)

    {:ok,
     %{
       query: query_text,
       concepts: format_nodes_simple(concepts),
       code: format_nodes_simple(code),
       libraries: format_nodes_simple(libs),
       memories: format_nodes_simple(memories),
       connections: length(edges),
       total_found: length(all_ids)
     }}
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp find_seed_nodes(query_text, node_types, limit) do
    # Use text search to find seed nodes
    # TODO: Replace with vector similarity when embeddings are available
    Graph.search_nodes(query_text, types: node_types, limit: limit)
    |> Enum.map(fn node ->
      %{
        node: node,
        score: text_match_score(node.name, query_text),
        depth: 0,
        source: :seed
      }
    end)
  end

  defp expand_graph_context(seed_nodes, hops) do
    seed_ids = Enum.map(seed_nodes, & &1.node.id)

    seed_nodes
    |> Enum.flat_map(fn %{node: node} ->
      Traversal.bfs(node.id, max_depth: hops, direction: :both)
      |> Enum.reject(fn %{node: n} -> n.id in seed_ids end)
      |> Enum.map(fn %{node: n, depth: d} ->
        %{
          node: n,
          score: decay_factor(d),
          depth: d,
          source: :expansion
        }
      end)
    end)
    |> Enum.uniq_by(& &1.node.id)
  end

  defp decay_factor(depth) do
    # Score decays with distance from seed
    :math.pow(0.7, depth)
  end

  defp rank_nodes(nodes, query_text) do
    nodes
    |> Enum.map(fn entry ->
      text_score = text_match_score(entry.node.name, query_text)
      type_boost = node_type_boost(entry.node.node_type)

      combined_score = entry.score * 0.4 + text_score * 0.4 + type_boost * 0.2

      %{entry | score: combined_score}
    end)
    |> Enum.sort_by(& &1.score, :desc)
  end

  defp text_match_score(node_name, query_text) do
    node_lower = String.downcase(node_name)
    query_words = query_text |> String.downcase() |> String.split(~r/\s+/)

    matches =
      query_words
      |> Enum.count(fn word -> String.contains?(node_lower, word) end)

    matches / max(length(query_words), 1)
  end

  defp node_type_boost(:function), do: 1.0
  defp node_type_boost(:module), do: 0.9
  defp node_type_boost(:concept), do: 0.8
  defp node_type_boost(:memory), do: 0.7
  defp node_type_boost(:file), do: 0.6
  defp node_type_boost(:external_lib), do: 0.5
  defp node_type_boost(_), do: 0.5

  defp assemble_context(ranked_nodes, max_nodes) do
    ranked_nodes
    |> Enum.take(max_nodes)
    |> Enum.map(&format_node_for_context/1)
    |> Enum.join("\n\n---\n\n")
  end

  defp format_node_for_context(%{node: node, score: score, depth: depth}) do
    type_label = node.node_type |> to_string() |> String.capitalize()

    header = "## #{type_label}: #{node.name}"
    score_info = "Relevance: #{Float.round(score, 2)} | Depth: #{depth}"

    details =
      case node.node_type do
        :function ->
          props = node.properties || %{}
          file = props["file_path"] || "unknown"
          line = props["start_line"] || "?"
          sig = props["signature"] || ""
          doc = props["doc"] || ""
          "File: #{file}:#{line}\n#{sig}\n#{doc}"

        :module ->
          props = node.properties || %{}
          file = props["file_path"] || "unknown"
          "File: #{file}"

        :file ->
          props = node.properties || %{}
          lang = props["language"] || "unknown"
          "Language: #{lang}"

        :external_lib ->
          props = node.properties || %{}
          eco = props["ecosystem"] || "unknown"
          ver = props["version"] || "?"
          "#{eco}@#{ver}"

        :memory ->
          props = node.properties || %{}
          preview = props["content_preview"] || ""
          "Preview: #{preview}"

        :concept ->
          node.description || ""

        _ ->
          ""
      end

    [header, score_info, details]
    |> Enum.filter(&(&1 != ""))
    |> Enum.join("\n")
  end

  defp format_node_context_string(center_node, subgraph) do
    center_info =
      format_node_for_context(%{
        node: center_node,
        score: 1.0,
        depth: 0
      })

    neighbor_info =
      subgraph.nodes
      |> Enum.reject(&(&1.id == center_node.id))
      |> Enum.take(10)
      |> Enum.map(fn node ->
        "- #{node.node_type}: #{node.name}"
      end)
      |> Enum.join("\n")

    edge_info =
      subgraph.edges
      |> Enum.take(10)
      |> Enum.map(fn edge ->
        "- #{edge.source_node.name} --[#{edge.edge_type}]--> #{edge.target_node.name}"
      end)
      |> Enum.join("\n")

    """
    #{center_info}

    ### Neighbors (#{length(subgraph.nodes) - 1})
    #{neighbor_info}

    ### Connections (#{length(subgraph.edges)})
    #{edge_info}
    """
  end

  defp get_connecting_edges(node_ids) when length(node_ids) < 2, do: []

  defp get_connecting_edges(node_ids) do
    Mimo.Synapse.GraphEdge
    |> where([e], e.source_node_id in ^node_ids and e.target_node_id in ^node_ids)
    |> preload([:source_node, :target_node])
    |> Repo.all()
  end

  defp format_nodes_simple(nodes) do
    Enum.map(nodes, fn node ->
      %{
        id: node.id,
        name: node.name,
        type: node.node_type,
        properties: node.properties
      }
    end)
  end
end
