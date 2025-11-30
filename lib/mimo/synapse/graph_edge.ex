defmodule Mimo.Synapse.GraphEdge do
  @moduledoc """
  Ecto schema for graph edges in the Synapse Web.

  Represents typed relationships between nodes:
  - `:defines` - File defines a Symbol
  - `:calls` - Function calls another Function
  - `:imports` - File imports a Module
  - `:uses` - Symbol uses an ExternalLib
  - `:mentions` - Memory mentions any entity
  - `:relates_to` - Concept relates to another Concept
  - `:implements` - Function implements a Concept
  - `:documented_by` - Symbol documented by documentation node

  ## Edge Weights

  Edges have weights (0.0-1.0) for ranking traversal results:
  - 1.0 = Strong, explicit relationship (e.g., direct function call)
  - 0.7 = Moderate relationship (e.g., semantic similarity)
  - 0.3 = Weak relationship (e.g., inferred connection)

  ## Example

      %GraphEdge{
        source_node_id: "uuid-1",
        target_node_id: "uuid-2",
        edge_type: :calls,
        weight: 1.0,
        source: "static_analysis"
      }
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

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

  schema "graph_edges" do
    belongs_to(:source_node, Mimo.Synapse.GraphNode)
    belongs_to(:target_node, Mimo.Synapse.GraphNode)

    field(:edge_type, Ecto.Enum, values: @edge_types)
    field(:weight, :float, default: 1.0)
    field(:confidence, :float, default: 1.0)
    field(:properties, :map, default: %{})
    field(:source, :string)
    field(:last_accessed_at, :utc_datetime)
    field(:access_count, :integer, default: 0)

    timestamps(type: :utc_datetime)
  end

  @required_fields [:source_node_id, :target_node_id, :edge_type]
  @optional_fields [
    :weight,
    :confidence,
    :properties,
    :source,
    :last_accessed_at,
    :access_count
  ]

  @doc """
  Creates a changeset for a graph edge.
  """
  def changeset(edge, attrs) do
    # Normalize properties to string keys for consistency with JSON serialization
    attrs = normalize_properties(attrs)

    edge
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:edge_type, @edge_types)
    |> validate_number(:weight, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> foreign_key_constraint(:source_node_id)
    |> foreign_key_constraint(:target_node_id)
    # SQLite uses auto-generated index name format: table_columns_index
    |> unique_constraint([:source_node_id, :target_node_id, :edge_type],
      name: :graph_edges_source_node_id_target_node_id_edge_type_index
    )
  end

  # Normalize map keys to strings for consistency with JSON serialization
  defp normalize_properties(%{properties: props} = attrs) when is_map(props) do
    %{attrs | properties: stringify_keys(props)}
  end

  defp normalize_properties(attrs), do: attrs

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {k, stringify_keys(v)}
    end)
  end

  defp stringify_keys(value), do: value

  @doc """
  Returns all valid edge types.
  """
  def edge_types, do: @edge_types

  @doc """
  Checks if a given type is a valid edge type.
  """
  def valid_type?(type) when is_atom(type), do: type in @edge_types
  def valid_type?(type) when is_binary(type), do: String.to_existing_atom(type) in @edge_types
  def valid_type?(_), do: false

  @doc """
  Returns the inverse of an edge type, if one exists.

  Some edge types have natural inverses:
  - defines <-> defined_by (conceptual)
  - imports <-> imported_by (conceptual)
  - calls <-> called_by (conceptual)

  For traversal in both directions.
  """
  def inverse_type(:defines), do: nil
  def inverse_type(:calls), do: nil
  def inverse_type(:imports), do: nil
  def inverse_type(:uses), do: nil
  def inverse_type(:mentions), do: nil
  # symmetric
  def inverse_type(:relates_to), do: :relates_to
  def inverse_type(:implements), do: nil
  def inverse_type(:documented_by), do: nil
  def inverse_type(_), do: nil

  @doc """
  Checks if an edge type is transitive (can be followed across multiple hops).
  """
  def transitive?(:calls), do: true
  def transitive?(:imports), do: true
  def transitive?(:uses), do: true
  def transitive?(:relates_to), do: true
  def transitive?(_), do: false
end
