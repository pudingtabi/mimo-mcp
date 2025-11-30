defmodule Mimo.Synapse.PathFinder do
  @moduledoc """
  Find paths between any entities in the knowledge web.

  Part of SPEC-025: Cognitive Codebase Integration.

  Provides advanced path-finding and neighborhood queries across the
  Synapse graph, enabling traversal from concepts to code to libraries.

  ## Features

  - **find_path**: Find shortest path between two nodes
  - **all_paths**: Find all paths up to a max length
  - **neighborhood**: Get all nodes within N hops
  - **pattern_query**: Follow specific edge patterns

  ## Example

      # How is this memory related to auth_service.ex?
      {:ok, path} = PathFinder.find_path(memory_id, file_id)

      # What libraries does this function depend on?
      neighbors = PathFinder.neighborhood(function_id, hops: 2, types: [:external_lib])

      # Show all code related to "authentication" concept
      results = PathFinder.pattern_query(:concept, [:implements], :function, start_name: "Authentication")
  """

  require Logger
  import Ecto.Query
  alias Mimo.Repo
  alias Mimo.Synapse.{Graph, GraphEdge, Traversal}

  # ==========================================================================
  # Public API
  # ==========================================================================

  @doc """
  Find shortest path between two nodes.

  Can search by node ID or by type + name.

  ## Options

    - `:max_depth` - Maximum path length (default: 6)
    - `:edge_types` - Filter by edge types (default: all)
    - `:bidirectional` - Search in both directions (default: true)

  ## Examples

      # By IDs
      {:ok, path} = PathFinder.find_path(from_id, to_id)

      # By type and name
      {:ok, path} = PathFinder.find_path(
        {:memory, "engram_123"},
        {:file, "lib/auth.ex"}
      )
  """
  @spec find_path(String.t() | {atom(), String.t()}, String.t() | {atom(), String.t()}, keyword()) ::
          {:ok, list()} | {:error, term()}
  def find_path(from, to, opts \\ []) do
    max_depth = Keyword.get(opts, :max_depth, 6)
    edge_types = Keyword.get(opts, :edge_types, Graph.edge_types())

    with {:ok, from_id} <- resolve_node(from),
         {:ok, to_id} <- resolve_node(to) do
      if from_id == to_id do
        {:ok, %{path: [from_id], nodes: [get_node_info(from_id)], length: 0}}
      else
        case Traversal.shortest_path(from_id, to_id, max_depth: max_depth, edge_types: edge_types) do
          {:ok, path_ids} ->
            nodes = Enum.map(path_ids, &get_node_info/1)
            edges = get_path_edges(path_ids)

            {:ok,
             %{
               path: path_ids,
               nodes: nodes,
               edges: edges,
               length: length(path_ids) - 1
             }}

          {:error, :no_path} ->
            # Try bidirectional search
            case Traversal.shortest_path(to_id, from_id,
                   max_depth: max_depth,
                   edge_types: edge_types
                 ) do
              {:ok, path_ids} ->
                reversed = Enum.reverse(path_ids)
                nodes = Enum.map(reversed, &get_node_info/1)
                edges = get_path_edges(reversed)

                {:ok,
                 %{
                   path: reversed,
                   nodes: nodes,
                   edges: edges,
                   length: length(path_ids) - 1,
                   direction: :reversed
                 }}

              {:error, :no_path} ->
                {:error, :no_path}
            end
        end
      end
    end
  end

  @doc """
  Find all paths between two nodes up to a maximum length.

  ## Options

    - `:max_length` - Maximum path length (default: 5)
    - `:limit` - Maximum number of paths (default: 10)
    - `:edge_types` - Filter by edge types (default: all)

  ## Returns

  List of paths, each containing node IDs.
  """
  @spec all_paths(String.t() | {atom(), String.t()}, String.t() | {atom(), String.t()}, keyword()) ::
          {:ok, list()} | {:error, term()}
  def all_paths(from, to, opts \\ []) do
    max_length = Keyword.get(opts, :max_length, 5)
    limit = Keyword.get(opts, :limit, 10)
    edge_types = Keyword.get(opts, :edge_types, Graph.edge_types())

    with {:ok, from_id} <- resolve_node(from),
         {:ok, to_id} <- resolve_node(to) do
      paths =
        Traversal.all_paths(from_id, to_id,
          max_length: max_length,
          limit: limit,
          edge_types: edge_types
        )

      formatted_paths =
        paths
        |> Enum.map(fn path_ids ->
          %{
            path: path_ids,
            nodes: Enum.map(path_ids, &get_node_info/1),
            length: length(path_ids) - 1
          }
        end)

      {:ok,
       %{
         from: get_node_info(from_id),
         to: get_node_info(to_id),
         paths: formatted_paths,
         count: length(formatted_paths)
       }}
    end
  end

  @doc """
  Get all nodes within N hops of a starting node.

  ## Options

    - `:hops` - Number of hops (default: 2)
    - `:edge_types` - Filter by edge types (default: all)
    - `:node_types` - Filter results by node types (default: all)
    - `:direction` - :outgoing, :incoming, or :both (default: :both)

  ## Returns

  Map with center node, neighbors, and edges.
  """
  @spec neighborhood(String.t() | {atom(), String.t()}, keyword()) ::
          {:ok, map()} | {:error, term()}
  def neighborhood(node, opts \\ []) do
    hops = Keyword.get(opts, :hops, 2)
    edge_types = Keyword.get(opts, :edge_types, Graph.edge_types())
    node_types = Keyword.get(opts, :node_types, Graph.node_types())
    direction = Keyword.get(opts, :direction, :both)

    with {:ok, node_id} <- resolve_node(node) do
      # Use existing ego_graph but filter by types
      graph = Traversal.ego_graph(node_id, hops: hops, edge_types: edge_types)

      # Filter nodes by type
      filtered_nodes =
        graph.nodes
        |> Enum.filter(fn n -> n && n.node_type in node_types end)
        |> Enum.map(&format_node/1)

      # Get center node info
      center_node = Graph.get_node_by_id(node_id)

      # Group neighbors by type
      neighbors_by_type =
        filtered_nodes
        |> Enum.reject(fn n -> n.id == node_id end)
        |> Enum.group_by(fn n -> n.type end)

      {:ok,
       %{
         center: format_node(center_node),
         neighbors: filtered_nodes,
         neighbors_by_type: neighbors_by_type,
         edges: length(graph.edges),
         hops: hops,
         direction: direction
       }}
    end
  end

  @doc """
  Query nodes by following a specific edge pattern.

  This allows complex queries like:
  - "Find all functions that implement the Authentication concept"
  - "Find all external libraries used by files in lib/"

  ## Parameters

    - `start_type` - Starting node type
    - `edge_pattern` - List of edge types to follow (in order)
    - `end_type` - Ending node type

  ## Options

    - `:start_name` - Filter starting nodes by name pattern
    - `:end_name` - Filter ending nodes by name pattern
    - `:limit` - Maximum results (default: 50)

  ## Examples

      # Functions that implement Authentication
      PathFinder.pattern_query(:concept, [:implements], :function, start_name: "Authentication")

      # Libraries used by auth module
      PathFinder.pattern_query(:module, [:uses], :external_lib, start_name: "Auth")
  """
  @spec pattern_query(atom(), [atom()], atom(), keyword()) :: {:ok, list()} | {:error, term()}
  def pattern_query(start_type, edge_pattern, end_type, opts \\ []) do
    start_name = Keyword.get(opts, :start_name)
    end_name = Keyword.get(opts, :end_name)
    limit = Keyword.get(opts, :limit, 50)

    # Find starting nodes
    start_nodes = find_nodes_by_type_and_name(start_type, start_name)

    if Enum.empty?(start_nodes) do
      {:ok, %{matches: [], count: 0, pattern: {start_type, edge_pattern, end_type}}}
    else
      # For each starting node, follow the edge pattern
      matches =
        start_nodes
        |> Enum.flat_map(fn start_node ->
          follow_pattern(start_node, edge_pattern, end_type, end_name)
        end)
        |> Enum.uniq_by(fn m -> {m.start_node.id, m.end_node.id} end)
        |> Enum.take(limit)

      {:ok,
       %{
         matches: matches,
         count: length(matches),
         pattern: %{start_type: start_type, edges: edge_pattern, end_type: end_type}
       }}
    end
  end

  @doc """
  Find relationships between a memory and code.

  Specialized query for finding how memories connect to code.
  """
  @spec memory_code_relationships(integer() | binary(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def memory_code_relationships(engram_id, opts \\ []) do
    hops = Keyword.get(opts, :hops, 2)

    memory_node_name = "engram_#{engram_id}"

    case Graph.get_node(:memory, memory_node_name) do
      nil ->
        {:error, :memory_not_in_graph}

      memory_node ->
        # Get all connections
        neighborhood = Traversal.ego_graph(memory_node.id, hops: hops)

        # Group by type
        files = Enum.filter(neighborhood.nodes, fn n -> n && n.node_type == :file end)
        functions = Enum.filter(neighborhood.nodes, fn n -> n && n.node_type == :function end)
        modules = Enum.filter(neighborhood.nodes, fn n -> n && n.node_type == :module end)
        libraries = Enum.filter(neighborhood.nodes, fn n -> n && n.node_type == :external_lib end)
        concepts = Enum.filter(neighborhood.nodes, fn n -> n && n.node_type == :concept end)

        {:ok,
         %{
           memory: format_node(memory_node),
           related_files: Enum.map(files, &format_node/1),
           related_functions: Enum.map(functions, &format_node/1),
           related_modules: Enum.map(modules, &format_node/1),
           related_libraries: Enum.map(libraries, &format_node/1),
           related_concepts: Enum.map(concepts, &format_node/1),
           total_connections: length(neighborhood.nodes) - 1
         }}
    end
  end

  @doc """
  Find all code related to a concept.
  """
  @spec concept_implementations(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def concept_implementations(concept_name, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    case Graph.get_node(:concept, concept_name) do
      nil ->
        {:error, :concept_not_found}

      concept_node ->
        # Get incoming :implements edges
        incoming = Graph.incoming_edges(concept_node.id, types: [:implements])

        implementations =
          incoming
          |> Enum.map(fn edge -> edge.source_node end)
          |> Enum.filter(& &1)
          |> Enum.take(limit)
          |> Enum.map(&format_node/1)

        # Also get nodes that relate_to this concept
        relates_to =
          Graph.incoming_edges(concept_node.id, types: [:relates_to])
          |> Enum.map(fn edge -> edge.source_node end)
          |> Enum.filter(fn n -> n && n.node_type == :memory end)
          |> Enum.take(limit)
          |> Enum.map(&format_node/1)

        {:ok,
         %{
           concept: format_node(concept_node),
           implementations: implementations,
           related_memories: relates_to,
           implementation_count: length(implementations)
         }}
    end
  end

  # ==========================================================================
  # Private Functions - Node Resolution
  # ==========================================================================

  defp resolve_node(id) when is_binary(id) do
    case Graph.get_node_by_id(id) do
      nil -> {:error, :node_not_found}
      _node -> {:ok, id}
    end
  end

  defp resolve_node({type, name}) when is_atom(type) and is_binary(name) do
    case Graph.get_node(type, name) do
      nil ->
        # Try search
        case Graph.search_nodes(name, types: [type], limit: 1) do
          [node | _] -> {:ok, node.id}
          [] -> {:error, {:node_not_found, type, name}}
        end

      node ->
        {:ok, node.id}
    end
  end

  defp resolve_node(_), do: {:error, :invalid_node_reference}

  # ==========================================================================
  # Private Functions - Pattern Following
  # ==========================================================================

  defp find_nodes_by_type_and_name(type, nil) do
    Graph.find_by_type(type, limit: 100)
  end

  defp find_nodes_by_type_and_name(type, name_pattern) do
    Graph.search_nodes(name_pattern, types: [type], limit: 100)
  end

  defp follow_pattern(start_node, [], end_type, end_name) do
    # No more edges to follow - check if we're at an end node
    if start_node.node_type == end_type do
      if is_nil(end_name) or String.contains?(start_node.name, end_name) do
        [%{start_node: format_node(start_node), end_node: format_node(start_node), path: []}]
      else
        []
      end
    else
      []
    end
  end

  defp follow_pattern(start_node, [edge_type | rest], end_type, end_name) do
    # Get outgoing edges of this type
    edges = Graph.outgoing_edges(start_node.id, types: [edge_type])

    edges
    |> Enum.flat_map(fn edge ->
      target = edge.target_node

      if rest == [] do
        # Last edge - check if target matches end criteria
        if target && target.node_type == end_type do
          if is_nil(end_name) or String.contains?(target.name, end_name) do
            [
              %{
                start_node: format_node(start_node),
                end_node: format_node(target),
                path: [edge_type]
              }
            ]
          else
            []
          end
        else
          []
        end
      else
        # More edges to follow - recurse
        follow_pattern(target, rest, end_type, end_name)
        |> Enum.map(fn match ->
          %{match | path: [edge_type | match.path]}
        end)
      end
    end)
  end

  # ==========================================================================
  # Private Functions - Formatting
  # ==========================================================================

  defp get_node_info(node_id) do
    case Graph.get_node_by_id(node_id) do
      nil -> %{id: node_id, type: :unknown, name: "unknown"}
      node -> format_node(node)
    end
  end

  defp format_node(nil), do: nil

  defp format_node(node) do
    %{
      id: node.id,
      type: node.node_type,
      name: node.name,
      properties: node.properties || %{},
      access_count: node.access_count || 0
    }
  end

  defp get_path_edges(path_ids) when length(path_ids) < 2, do: []

  defp get_path_edges(path_ids) do
    path_ids
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [from_id, to_id] ->
      # Find edge between these nodes
      edge_query =
        from(e in GraphEdge,
          where: e.source_node_id == ^from_id and e.target_node_id == ^to_id,
          limit: 1
        )

      case Repo.one(edge_query) do
        nil ->
          # Try reverse direction
          reverse_query =
            from(e in GraphEdge,
              where: e.source_node_id == ^to_id and e.target_node_id == ^from_id,
              limit: 1
            )

          case Repo.one(reverse_query) do
            nil -> %{from: from_id, to: to_id, type: :unknown}
            edge -> %{from: to_id, to: from_id, type: edge.edge_type, direction: :reversed}
          end

        edge ->
          %{from: from_id, to: to_id, type: edge.edge_type}
      end
    end)
  end
end
