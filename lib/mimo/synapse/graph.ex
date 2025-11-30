defmodule Mimo.Synapse.Graph do
  @moduledoc """
  Core graph operations for the Synapse Web.

  Provides a typed, property graph model on top of SQLite
  with efficient recursive CTE-based traversal.

  ## Features

  - **Typed Nodes**: concept, file, function, module, external_lib, memory
  - **Typed Edges**: defines, calls, imports, uses, mentions, relates_to, implements
  - **Graph Traversal**: BFS/DFS with recursive CTEs
  - **Hybrid Search**: Combine graph structure + vector similarity
  - **Access Tracking**: Reinforce frequently used connections

  ## Example

      # Create nodes
      {:ok, fn_node} = Graph.create_node(%{
        node_type: :function,
        name: "Mimo.Tools.dispatch/2"
      })

      {:ok, lib_node} = Graph.create_node(%{
        node_type: :external_lib,
        name: "phoenix"
      })

      # Create edge
      {:ok, edge} = Graph.create_edge(%{
        source_node_id: fn_node.id,
        target_node_id: lib_node.id,
        edge_type: :uses
      })

      # Traverse
      results = Graph.traverse(fn_node.id, max_hops: 2)
  """

  import Ecto.Query
  alias Mimo.Repo
  alias Mimo.Synapse.{GraphNode, GraphEdge}

  require Logger

  @node_types [:concept, :file, :function, :module, :external_lib, :memory]
  @edge_types [
    :defines,
    :calls,
    :imports,
    :uses,
    :mentions,
    :relates_to,
    :implements,
    :documented_by
  ]

  # ============================================
  # Node Operations
  # ============================================

  @doc """
  Create a new node in the graph.

  ## Parameters

    - `attrs` - Map with node attributes:
      - `:node_type` (required) - One of: concept, file, function, module, external_lib, memory
      - `:name` (required) - Unique name within the type
      - `:properties` (optional) - Additional metadata
      - `:embedding` (optional) - Vector embedding for similarity search
      - `:description` (optional) - Human-readable description
      - `:source_ref_type` (optional) - Type of source entity (code_symbol, engram, etc.)
      - `:source_ref_id` (optional) - ID in source table

  ## Returns

    - `{:ok, node}` - Successfully created node
    - `{:error, changeset}` - Validation errors
  """
  @spec create_node(map()) :: {:ok, GraphNode.t()} | {:error, Ecto.Changeset.t()}
  def create_node(attrs) do
    %GraphNode{}
    |> GraphNode.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Find or create a node by type and name.

  If a node with the same type and name exists, returns it.
  Otherwise, creates a new node with the given attributes.
  """
  @spec find_or_create_node(atom(), String.t(), map()) :: {:ok, GraphNode.t()} | {:error, term()}
  def find_or_create_node(type, name, properties \\ %{}) do
    case get_node(type, name) do
      nil ->
        create_node(%{
          node_type: type,
          name: name,
          properties: properties
        })

      node ->
        {:ok, node}
    end
  end

  @doc """
  Get a node by type and name.
  """
  @spec get_node(atom(), String.t()) :: GraphNode.t() | nil
  def get_node(type, name) when is_atom(type) and is_binary(name) do
    GraphNode
    |> where([n], n.node_type == ^type and n.name == ^name)
    |> Repo.one()
  end

  @doc """
  Get a node by ID.
  """
  @spec get_node_by_id(String.t()) :: GraphNode.t() | nil
  def get_node_by_id(id) when is_binary(id) do
    Repo.get(GraphNode, id)
  end

  @doc """
  Search nodes by name pattern.

  ## Options

    - `:types` - Filter by node types (default: all)
    - `:limit` - Maximum results (default: 50)
  """
  @spec search_nodes(String.t(), keyword()) :: [GraphNode.t()]
  def search_nodes(pattern, opts \\ []) do
    types = Keyword.get(opts, :types, @node_types)
    limit = Keyword.get(opts, :limit, 50)

    # Use SQLite-compatible case-insensitive search (lower + like instead of ilike)
    search_pattern = "%#{String.downcase(pattern)}%"

    GraphNode
    |> where([n], like(fragment("lower(?)", n.name), ^search_pattern))
    |> where([n], n.node_type in ^types)
    |> limit(^limit)
    |> order_by([n], desc: n.access_count, asc: n.name)
    |> Repo.all()
  end

  @doc """
  Find nodes by type.

  ## Options

    - `:limit` - Maximum results (default: 100)
    - `:offset` - Offset for pagination (default: 0)
  """
  @spec find_by_type(atom(), keyword()) :: [GraphNode.t()]
  def find_by_type(type, opts \\ []) when type in @node_types do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)

    GraphNode
    |> where([n], n.node_type == ^type)
    |> limit(^limit)
    |> offset(^offset)
    |> order_by([n], desc: n.access_count, asc: n.name)
    |> Repo.all()
  end

  @doc """
  Update a node's properties.
  """
  @spec update_node(GraphNode.t(), map()) :: {:ok, GraphNode.t()} | {:error, Ecto.Changeset.t()}
  def update_node(%GraphNode{} = node, attrs) do
    node
    |> GraphNode.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete a node and all its edges.
  """
  @spec delete_node(GraphNode.t()) :: {:ok, GraphNode.t()} | {:error, Ecto.Changeset.t()}
  def delete_node(%GraphNode{} = node) do
    Repo.delete(node)
  end

  @doc """
  Track access to a node (for reinforcement learning).
  """
  @spec track_access(String.t()) :: {:ok, GraphNode.t()} | {:error, term()}
  def track_access(node_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    GraphNode
    |> where([n], n.id == ^node_id)
    |> Repo.update_all(
      set: [last_accessed_at: now],
      inc: [access_count: 1]
    )

    {:ok, get_node_by_id(node_id)}
  end

  # ============================================
  # Edge Operations
  # ============================================

  @doc """
  Create an edge between two nodes.

  ## Parameters

    - `attrs` - Map with edge attributes:
      - `:source_node_id` (required) - Source node ID
      - `:target_node_id` (required) - Target node ID
      - `:edge_type` (required) - One of: defines, calls, imports, uses, mentions, relates_to, implements
      - `:weight` (optional) - Edge importance (0.0-1.0, default: 1.0)
      - `:confidence` (optional) - Confidence in this edge (0.0-1.0, default: 1.0)
      - `:properties` (optional) - Additional metadata
      - `:source` (optional) - How this edge was created (static_analysis, semantic_inference, etc.)
  """
  @spec create_edge(map()) :: {:ok, GraphEdge.t()} | {:error, Ecto.Changeset.t()}
  def create_edge(attrs) do
    %GraphEdge{}
    |> GraphEdge.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Create an edge if it doesn't exist.

  Returns existing edge if one already exists between the nodes with the same type.
  """
  @spec ensure_edge(String.t(), String.t(), atom(), map()) ::
          {:ok, GraphEdge.t()} | {:error, term()}
  def ensure_edge(source_id, target_id, edge_type, properties \\ %{}) do
    case get_edge(source_id, target_id, edge_type) do
      nil ->
        create_edge(%{
          source_node_id: source_id,
          target_node_id: target_id,
          edge_type: edge_type,
          properties: properties
        })

      edge ->
        {:ok, edge}
    end
  end

  @doc """
  Get an edge by source, target, and type.
  """
  @spec get_edge(String.t(), String.t(), atom()) :: GraphEdge.t() | nil
  def get_edge(source_id, target_id, edge_type) do
    GraphEdge
    |> where([e], e.source_node_id == ^source_id)
    |> where([e], e.target_node_id == ^target_id)
    |> where([e], e.edge_type == ^edge_type)
    |> Repo.one()
  end

  @doc """
  Get outgoing edges from a node.

  ## Options

    - `:types` - Filter by edge types (default: all)
    - `:preload` - Preload target node (default: true)
  """
  @spec outgoing_edges(String.t(), keyword()) :: [GraphEdge.t()]
  def outgoing_edges(node_id, opts \\ []) do
    types = Keyword.get(opts, :types, @edge_types)
    preload_target = Keyword.get(opts, :preload, true)

    query =
      GraphEdge
      |> where([e], e.source_node_id == ^node_id)
      |> where([e], e.edge_type in ^types)
      |> order_by([e], desc: e.weight)

    query = if preload_target, do: preload(query, :target_node), else: query
    Repo.all(query)
  end

  @doc """
  Get incoming edges to a node.

  ## Options

    - `:types` - Filter by edge types (default: all)
    - `:preload` - Preload source node (default: true)
  """
  @spec incoming_edges(String.t(), keyword()) :: [GraphEdge.t()]
  def incoming_edges(node_id, opts \\ []) do
    types = Keyword.get(opts, :types, @edge_types)
    preload_source = Keyword.get(opts, :preload, true)

    query =
      GraphEdge
      |> where([e], e.target_node_id == ^node_id)
      |> where([e], e.edge_type in ^types)
      |> order_by([e], desc: e.weight)

    query = if preload_source, do: preload(query, :source_node), else: query
    Repo.all(query)
  end

  @doc """
  Get all neighbors of a node (both directions).
  """
  @spec neighbors(String.t(), keyword()) :: [GraphNode.t()]
  def neighbors(node_id, opts \\ []) do
    outgoing = outgoing_edges(node_id, opts) |> Enum.map(& &1.target_node)
    incoming = incoming_edges(node_id, opts) |> Enum.map(& &1.source_node)
    Enum.uniq_by(outgoing ++ incoming, & &1.id)
  end

  @doc """
  Update an edge's weight.
  """
  @spec update_edge_weight(GraphEdge.t(), float()) :: {:ok, GraphEdge.t()} | {:error, term()}
  def update_edge_weight(%GraphEdge{} = edge, weight) when weight >= 0.0 and weight <= 1.0 do
    edge
    |> GraphEdge.changeset(%{weight: weight})
    |> Repo.update()
  end

  @doc """
  Track access to an edge (for reinforcement learning).
  """
  @spec track_edge_access(String.t()) :: {:ok, GraphEdge.t()} | {:error, term()}
  def track_edge_access(edge_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    GraphEdge
    |> where([e], e.id == ^edge_id)
    |> Repo.update_all(
      set: [last_accessed_at: now],
      inc: [access_count: 1]
    )

    {:ok, Repo.get(GraphEdge, edge_id)}
  end

  @doc """
  Delete an edge.
  """
  @spec delete_edge(GraphEdge.t()) :: {:ok, GraphEdge.t()} | {:error, Ecto.Changeset.t()}
  def delete_edge(%GraphEdge{} = edge) do
    Repo.delete(edge)
  end

  # ============================================
  # Bulk Operations
  # ============================================

  @doc """
  Batch create nodes.

  Returns count of successfully created nodes.
  """
  @spec batch_create_nodes([map()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def batch_create_nodes(nodes_attrs) when is_list(nodes_attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entries =
      nodes_attrs
      |> Enum.map(fn attrs ->
        attrs
        |> Map.put(:id, Ecto.UUID.generate())
        |> Map.put_new(:properties, %{})
        |> Map.put_new(:embedding, [])
        |> Map.put_new(:access_count, 0)
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)
        |> ensure_atom_type(:node_type)
      end)

    {count, _} = Repo.insert_all(GraphNode, entries, on_conflict: :nothing)
    {:ok, count}
  rescue
    e ->
      Logger.error("Batch create nodes failed: #{Exception.message(e)}")
      {:error, e}
  end

  # Ensure type fields are atoms for Ecto.Enum compatibility with insert_all
  defp ensure_atom_type(attrs, key) do
    case Map.get(attrs, key) do
      val when is_binary(val) -> Map.put(attrs, key, String.to_existing_atom(val))
      _ -> attrs
    end
  end

  @doc """
  Batch create edges.

  Returns count of successfully created edges.
  """
  @spec batch_create_edges([map()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def batch_create_edges(edges_attrs) when is_list(edges_attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entries =
      edges_attrs
      |> Enum.map(fn attrs ->
        attrs
        |> Map.put(:id, Ecto.UUID.generate())
        |> Map.put_new(:weight, 1.0)
        |> Map.put_new(:confidence, 1.0)
        |> Map.put_new(:properties, %{})
        |> Map.put_new(:access_count, 0)
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)
        |> ensure_atom_type(:edge_type)
      end)

    {count, _} = Repo.insert_all(GraphEdge, entries, on_conflict: :nothing)
    {:ok, count}
  rescue
    e ->
      Logger.error("Batch create edges failed: #{Exception.message(e)}")
      {:error, e}
  end

  # ============================================
  # Statistics
  # ============================================

  @doc """
  Get graph statistics.
  """
  @spec stats() :: map()
  def stats do
    %{
      total_nodes: Repo.aggregate(GraphNode, :count),
      total_edges: Repo.aggregate(GraphEdge, :count),
      nodes_by_type: nodes_by_type(),
      edges_by_type: edges_by_type(),
      avg_edges_per_node: avg_edges_per_node()
    }
  end

  defp nodes_by_type do
    GraphNode
    |> group_by([n], n.node_type)
    |> select([n], {n.node_type, count(n.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp edges_by_type do
    GraphEdge
    |> group_by([e], e.edge_type)
    |> select([e], {e.edge_type, count(e.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp avg_edges_per_node do
    nodes = Repo.aggregate(GraphNode, :count) || 1
    edges = Repo.aggregate(GraphEdge, :count) || 0
    if nodes > 0, do: Float.round(edges / nodes, 2), else: 0.0
  end

  @doc """
  Returns all valid node types.
  """
  def node_types, do: @node_types

  @doc """
  Returns all valid edge types.
  """
  def edge_types, do: @edge_types
end
