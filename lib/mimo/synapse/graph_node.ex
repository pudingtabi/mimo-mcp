defmodule Mimo.Synapse.GraphNode do
  @moduledoc """
  Ecto schema for graph nodes in the Synapse Web.

  Represents typed entities in the knowledge graph:
  - `:concept` - Abstract ideas and categories
  - `:file` - Source files in the codebase
  - `:function` - Functions, methods, procedures
  - `:module` - Modules, classes, namespaces
  - `:external_lib` - External library packages
  - `:memory` - Memory engrams

  ## Example

      %GraphNode{
        node_type: :function,
        name: "Mimo.Synapse.Graph.traverse/2",
        properties: %{language: "elixir", visibility: "public"},
        source_ref_type: "code_symbol",
        source_ref_id: "abc123"
      }
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @node_types [:concept, :file, :function, :module, :external_lib, :memory]

  schema "graph_nodes" do
    field(:node_type, Ecto.Enum, values: @node_types)
    field(:name, :string)
    field(:properties, :map, default: %{})
    field(:embedding, Mimo.Brain.EctoJsonList, default: [])
    field(:description, :string)
    field(:source_ref_type, :string)
    field(:source_ref_id, :string)
    field(:last_accessed_at, :utc_datetime)
    field(:access_count, :integer, default: 0)

    # Virtual field for similarity score in search results
    field(:similarity, :float, virtual: true)

    # Associations
    has_many(:outgoing_edges, Mimo.Synapse.GraphEdge, foreign_key: :source_node_id)
    has_many(:incoming_edges, Mimo.Synapse.GraphEdge, foreign_key: :target_node_id)

    timestamps(type: :utc_datetime)
  end

  @required_fields [:node_type, :name]
  @optional_fields [
    :properties,
    :embedding,
    :description,
    :source_ref_type,
    :source_ref_id,
    :last_accessed_at,
    :access_count
  ]

  @doc """
  Creates a changeset for a graph node.
  """
  def changeset(node, attrs) do
    # Normalize properties to string keys for consistency with JSON serialization
    attrs = normalize_properties(attrs)

    node
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:node_type, @node_types)
    |> validate_length(:name, min: 1, max: 500)
    # SQLite uses auto-generated index name format: table_columns_index
    |> unique_constraint([:node_type, :name], name: :graph_nodes_node_type_name_index)
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
  Returns all valid node types.
  """
  def node_types, do: @node_types

  @doc """
  Checks if a given type is a valid node type.
  """
  def valid_type?(type) when is_atom(type), do: type in @node_types
  def valid_type?(type) when is_binary(type), do: String.to_existing_atom(type) in @node_types
  def valid_type?(_), do: false
end
