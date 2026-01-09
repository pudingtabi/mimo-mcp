defmodule Mimo.Synapse.Traversal do
  @moduledoc """
  Graph traversal algorithms for the Synapse Web.

  Provides efficient graph traversal using SQLite recursive CTEs:
  - BFS (Breadth-First Search)
  - DFS (Depth-First Search)
  - Shortest path finding
  - Subgraph extraction (ego graph)
  - Centrality computation

  ## Performance

  Uses SQLite's WITH RECURSIVE for efficient in-database traversal,
  avoiding multiple round-trips for each hop.

  ## Example

      # BFS from a starting node
      results = Traversal.bfs(node_id, max_depth: 3)

      # Find shortest path
      {:ok, path} = Traversal.shortest_path(from_id, to_id)

      # Get ego graph (neighborhood)
      subgraph = Traversal.ego_graph(center_id, hops: 2)
  """

  alias Ecto.Adapters.SQL, as: EctoSQL
  alias Mimo.Repo
  alias Mimo.Synapse.{Graph, GraphEdge, GraphNode}

  require Logger

  @type traversal_result :: %{
          node: GraphNode.t(),
          depth: non_neg_integer(),
          path: [String.t()]
        }

  @doc """
  Breadth-First Search traversal from a starting node.

  Uses SQLite recursive CTE for efficient multi-hop traversal.

  ## Options

    - `:max_depth` - Maximum traversal depth (default: 3)
    - `:edge_types` - Filter by edge types (default: all)
    - `:direction` - `:outgoing`, `:incoming`, or `:both` (default: :outgoing)
    - `:min_weight` - Minimum edge weight threshold (default: 0.0)

  ## Returns

  List of `%{node: GraphNode.t(), depth: integer, path: [String.t()]}`
  """
  # Allowed edge types for safe SQL generation (whitelist)
  @allowed_edge_types ~w(defines calls imports uses mentions relates_to implements documented_by)

  # Allowed node types for safe SQL generation (whitelist)
  @allowed_node_types ~w(concept file function module external_lib memory)

  @spec bfs(String.t(), keyword()) :: [traversal_result()]
  def bfs(start_node_id, opts \\ []) do
    max_depth = Keyword.get(opts, :max_depth, 3)
    edge_types = Keyword.get(opts, :edge_types, Graph.edge_types())
    direction = Keyword.get(opts, :direction, :outgoing)
    min_weight = Keyword.get(opts, :min_weight, 0.0)

    # SECURITY: Validate and sanitize edge_types against whitelist to prevent SQL injection
    safe_edge_types = sanitize_edge_types(edge_types)

    if Enum.empty?(safe_edge_types) do
      Logger.warning("BFS: No valid edge types provided, returning empty")
      []
    else
      edge_types_str = Enum.map_join(safe_edge_types, ",", &"'#{&1}'")
      # min_weight is validated as float
      safe_min_weight = validate_min_weight(min_weight)

      sql = build_traversal_sql(direction, edge_types_str, safe_min_weight)

      case EctoSQL.query(Repo, sql, [start_node_id, max_depth]) do
        {:ok, %{rows: rows}} ->
          rows
          |> Enum.map(fn [id, node_type, name, properties, depth, path] ->
            %{
              node: %GraphNode{
                id: id,
                node_type: safe_atom(node_type),
                name: name,
                properties: decode_json(properties)
              },
              depth: depth,
              path: String.split(path, "->")
            }
          end)

        {:error, error} ->
          Logger.error("BFS traversal failed: #{inspect(error)}")
          []
      end
    end
  end

  # Sanitize edge types against whitelist - prevents SQL injection
  defp sanitize_edge_types(edge_types) when is_list(edge_types) do
    edge_types
    |> Enum.map(&to_string/1)
    |> Enum.filter(&(&1 in @allowed_edge_types))
  end

  defp sanitize_edge_types(_), do: @allowed_edge_types

  # Sanitize node types against whitelist - prevents SQL injection
  defp sanitize_node_types(node_types) when is_list(node_types) do
    node_types
    |> Enum.map(&to_string/1)
    |> Enum.filter(&(&1 in @allowed_node_types))
  end

  defp sanitize_node_types(_), do: @allowed_node_types

  # Validate min_weight is a safe float value
  defp validate_min_weight(weight) when is_number(weight) and weight >= 0.0 and weight <= 1.0,
    do: weight

  defp validate_min_weight(_), do: 0.0

  defp build_traversal_sql(:outgoing, edge_types_str, min_weight) do
    """
    WITH RECURSIVE graph_walk AS (
      -- Base case: starting node
      SELECT
        n.id,
        n.node_type,
        n.name,
        n.properties,
        0 as depth,
        n.id as path,
        n.id as visited
      FROM graph_nodes n
      WHERE n.id = ?1

      UNION ALL

      -- Recursive case: follow outgoing edges
      SELECT
        tn.id,
        tn.node_type,
        tn.name,
        tn.properties,
        gw.depth + 1,
        gw.path || '->' || tn.id,
        gw.visited || ',' || tn.id
      FROM graph_edges e
      INNER JOIN graph_walk gw ON e.source_node_id = gw.id
      INNER JOIN graph_nodes tn ON e.target_node_id = tn.id
      WHERE gw.depth < ?2
        AND e.edge_type IN (#{edge_types_str})
        AND e.weight >= #{min_weight}
        AND instr(gw.visited, tn.id) = 0
    )
    SELECT DISTINCT id, node_type, name, properties, depth, path
    FROM graph_walk
    WHERE depth > 0
    ORDER BY depth ASC, name ASC
    """
  end

  defp build_traversal_sql(:incoming, edge_types_str, min_weight) do
    """
    WITH RECURSIVE graph_walk AS (
      -- Base case: starting node
      SELECT
        n.id,
        n.node_type,
        n.name,
        n.properties,
        0 as depth,
        n.id as path,
        n.id as visited
      FROM graph_nodes n
      WHERE n.id = ?1

      UNION ALL

      -- Recursive case: follow incoming edges
      SELECT
        sn.id,
        sn.node_type,
        sn.name,
        sn.properties,
        gw.depth + 1,
        sn.id || '->' || gw.path,
        gw.visited || ',' || sn.id
      FROM graph_edges e
      INNER JOIN graph_walk gw ON e.target_node_id = gw.id
      INNER JOIN graph_nodes sn ON e.source_node_id = sn.id
      WHERE gw.depth < ?2
        AND e.edge_type IN (#{edge_types_str})
        AND e.weight >= #{min_weight}
        AND instr(gw.visited, sn.id) = 0
    )
    SELECT DISTINCT id, node_type, name, properties, depth, path
    FROM graph_walk
    WHERE depth > 0
    ORDER BY depth ASC, name ASC
    """
  end

  defp build_traversal_sql(:both, edge_types_str, min_weight) do
    """
    WITH RECURSIVE graph_walk AS (
      -- Base case: starting node
      SELECT
        n.id,
        n.node_type,
        n.name,
        n.properties,
        0 as depth,
        n.id as path,
        n.id as visited
      FROM graph_nodes n
      WHERE n.id = ?1

      UNION ALL

      -- Recursive case: follow outgoing edges
      SELECT
        tn.id,
        tn.node_type,
        tn.name,
        tn.properties,
        gw.depth + 1,
        gw.path || '->' || tn.id,
        gw.visited || ',' || tn.id
      FROM graph_edges e
      INNER JOIN graph_walk gw ON e.source_node_id = gw.id
      INNER JOIN graph_nodes tn ON e.target_node_id = tn.id
      WHERE gw.depth < ?2
        AND e.edge_type IN (#{edge_types_str})
        AND e.weight >= #{min_weight}
        AND instr(gw.visited, tn.id) = 0

      UNION ALL

      -- Recursive case: follow incoming edges
      SELECT
        sn.id,
        sn.node_type,
        sn.name,
        sn.properties,
        gw.depth + 1,
        sn.id || '->' || gw.path,
        gw.visited || ',' || sn.id
      FROM graph_edges e
      INNER JOIN graph_walk gw ON e.target_node_id = gw.id
      INNER JOIN graph_nodes sn ON e.source_node_id = sn.id
      WHERE gw.depth < ?2
        AND e.edge_type IN (#{edge_types_str})
        AND e.weight >= #{min_weight}
        AND instr(gw.visited, sn.id) = 0
    )
    SELECT DISTINCT id, node_type, name, properties, depth, path
    FROM graph_walk
    WHERE depth > 0
    ORDER BY depth ASC, name ASC
    """
  end

  @doc """
  Depth-First Search traversal from a starting node.

  Note: SQLite CTEs are naturally BFS-like. This function provides
  DFS ordering by sorting results by path length first.

  ## Options

  Same as `bfs/2`.
  """
  @spec dfs(String.t(), keyword()) :: [traversal_result()]
  def dfs(start_node_id, opts \\ []) do
    # Use BFS but sort by path depth (DFS-like ordering)
    bfs(start_node_id, opts)
    |> Enum.sort_by(fn %{path: path} -> -length(path) end)
  end

  @doc """
  Find the shortest path between two nodes.

  Uses BFS to find the first path, which is guaranteed to be shortest
  in an unweighted graph.

  ## Options

    - `:max_depth` - Maximum path length (default: 6)
    - `:edge_types` - Filter by edge types (default: all)

  ## Returns

    - `{:ok, path}` - List of node IDs forming the path
    - `{:error, :no_path}` - No path exists within max_depth
  """
  @spec shortest_path(String.t(), String.t(), keyword()) :: {:ok, [String.t()]} | {:error, :no_path}
  def shortest_path(from_id, to_id, opts \\ []) do
    max_depth = Keyword.get(opts, :max_depth, 6)
    edge_types = Keyword.get(opts, :edge_types, Graph.edge_types())

    # SECURITY: Sanitize edge_types against whitelist to prevent SQL injection
    safe_edge_types = sanitize_edge_types(edge_types)

    if Enum.empty?(safe_edge_types) do
      Logger.warning("shortest_path: No valid edge types provided")
      {:error, :no_path}
    else
      edge_types_str = Enum.map_join(safe_edge_types, ",", &"'#{&1}'")

      sql = """
      WITH RECURSIVE path_search AS (
        -- Base case: start from source
        SELECT
          ?1 as current_id,
          ?1 as path,
          ?1 as visited,
          0 as depth
        
        UNION ALL
        
        -- Follow edges
        SELECT
          e.target_node_id,
          ps.path || '->' || e.target_node_id,
          ps.visited || ',' || e.target_node_id,
          ps.depth + 1
        FROM graph_edges e
        INNER JOIN path_search ps ON e.source_node_id = ps.current_id
        WHERE ps.depth < ?3
          AND e.edge_type IN (#{edge_types_str})
          AND instr(ps.visited, e.target_node_id) = 0
      )
      SELECT path
      FROM path_search
      WHERE current_id = ?2
      ORDER BY depth ASC
      LIMIT 1
      """

      case EctoSQL.query(Repo, sql, [from_id, to_id, max_depth]) do
        {:ok, %{rows: [[path]]}} ->
          {:ok, String.split(path, "->")}

        {:ok, %{rows: []}} ->
          {:error, :no_path}

        {:error, error} ->
          Logger.error("Shortest path query failed: #{inspect(error)}")
          {:error, :no_path}
      end
    end
  end

  @doc """
  Find all paths between two nodes up to a maximum length.

  ## Options

    - `:max_length` - Maximum path length (default: 5)
    - `:limit` - Maximum number of paths to return (default: 10)
  """
  @spec all_paths(String.t(), String.t(), keyword()) :: [list(String.t())]
  def all_paths(from_id, to_id, opts \\ []) do
    max_length = Keyword.get(opts, :max_length, 5)
    limit = Keyword.get(opts, :limit, 10)
    edge_types = Keyword.get(opts, :edge_types, Graph.edge_types())

    # SECURITY: Sanitize edge_types against whitelist to prevent SQL injection
    safe_edge_types = sanitize_edge_types(edge_types)

    if Enum.empty?(safe_edge_types) do
      Logger.warning("all_paths: No valid edge types provided")
      []
    else
      edge_types_str = Enum.map_join(safe_edge_types, ",", &"'#{&1}'")

      sql = """
      WITH RECURSIVE path_search AS (
        SELECT
          ?1 as current_id,
          ?1 as path,
          ?1 as visited,
          0 as depth
        
        UNION ALL
        
        SELECT
          e.target_node_id,
          ps.path || '->' || e.target_node_id,
          ps.visited || ',' || e.target_node_id,
          ps.depth + 1
        FROM graph_edges e
        INNER JOIN path_search ps ON e.source_node_id = ps.current_id
        WHERE ps.depth < ?3
          AND e.edge_type IN (#{edge_types_str})
          AND instr(ps.visited, e.target_node_id) = 0
      )
      SELECT path
      FROM path_search
      WHERE current_id = ?2
      ORDER BY depth ASC
      LIMIT ?4
      """

      case EctoSQL.query(Repo, sql, [from_id, to_id, max_length, limit]) do
        {:ok, %{rows: rows}} ->
          Enum.map(rows, fn [path] -> String.split(path, "->") end)

        {:error, error} ->
          Logger.error("All paths query failed: #{inspect(error)}")
          []
      end
    end
  end

  @doc """
  Get the ego graph (neighborhood) around a center node.

  Returns all nodes within `hops` distance and all edges between them.

  ## Options

    - `:hops` - Number of hops from center (default: 2)
    - `:edge_types` - Filter by edge types (default: all)

  ## Returns

  Map with `:nodes` and `:edges` lists.
  """
  @spec ego_graph(String.t(), keyword()) :: %{nodes: [GraphNode.t()], edges: [GraphEdge.t()]}
  def ego_graph(center_id, opts \\ []) do
    hops = Keyword.get(opts, :hops, 2)

    # Get all reachable nodes
    traversal = bfs(center_id, max_depth: hops, direction: :both)
    node_ids = [center_id | Enum.map(traversal, & &1.node.id)]

    # Get center node
    center_node = Graph.get_node_by_id(center_id)
    traversal_nodes = Enum.map(traversal, & &1.node)

    # Get all edges between these nodes
    edges =
      if Enum.empty?(node_ids) do
        []
      else
        import Ecto.Query

        GraphEdge
        |> where([e], e.source_node_id in ^node_ids and e.target_node_id in ^node_ids)
        |> preload([:source_node, :target_node])
        |> Repo.all()
      end

    %{
      nodes: [center_node | traversal_nodes] |> Enum.filter(& &1) |> Enum.uniq_by(& &1.id),
      edges: edges
    }
  end

  @doc """
  Compute centrality scores for nodes in the graph.

  Uses a simplified PageRank-style algorithm:
  - Nodes with more incoming edges are more central
  - Weighted by edge weights

  ## Options

    - `:limit` - Maximum number of results (default: 100)
    - `:node_types` - Filter by node types (default: all)

  ## Returns

  List of `{node_id, centrality_score}` tuples, sorted by score descending.
  """
  @spec compute_centrality(keyword()) :: [{String.t(), float()}]
  def compute_centrality(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    node_types = Keyword.get(opts, :node_types, Graph.node_types())

    # SECURITY: Sanitize node_types against whitelist to prevent SQL injection
    safe_node_types = sanitize_node_types(node_types)

    if Enum.empty?(safe_node_types) do
      Logger.warning("compute_centrality: No valid node types provided")
      []
    else
      node_types_str = Enum.map_join(safe_node_types, ",", &"'#{&1}'")

      # Simple centrality: sum of incoming edge weights + access count bonus
      sql = """
      SELECT
        n.id,
        n.name,
        n.node_type,
        COALESCE(SUM(e.weight), 0) + (n.access_count * 0.1) as centrality
      FROM graph_nodes n
      LEFT JOIN graph_edges e ON e.target_node_id = n.id
      WHERE n.node_type IN (#{node_types_str})
      GROUP BY n.id
      ORDER BY centrality DESC
      LIMIT ?1
      """

      case EctoSQL.query(Repo, sql, [limit]) do
        {:ok, %{rows: rows}} ->
          Enum.map(rows, fn [id, name, type, centrality] ->
            {id, %{name: name, node_type: safe_atom(type), centrality: centrality || 0.0}}
          end)

        {:error, error} ->
          Logger.error("Centrality computation failed: #{inspect(error)}")
          []
      end
    end
  end

  defp safe_atom(nil), do: nil

  # SECURITY FIX: Only convert to atom if in whitelist, otherwise keep as string
  # This prevents atom table exhaustion from attacker-controlled data
  defp safe_atom(str) when is_binary(str) do
    if str in @allowed_node_types do
      String.to_existing_atom(str)
    else
      # Return as string instead of creating potentially dangerous atom
      Logger.debug("safe_atom: Unknown node type '#{str}', keeping as string")
      str
    end
  rescue
    # Even whitelisted atoms might not exist yet in a fresh BEAM
    ArgumentError -> str
  end

  defp safe_atom(atom) when is_atom(atom), do: atom

  defp decode_json(nil), do: %{}

  defp decode_json(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, map} -> map
      _ -> %{}
    end
  end

  defp decode_json(map) when is_map(map), do: map
end
