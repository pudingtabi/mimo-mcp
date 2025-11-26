defmodule Mimo.SemanticStore.Entity do
  @moduledoc """
  Virtual schema for graph traversal results.

  Represents an entity discovered during graph traversal,
  including its path from the starting entity.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          type: String.t(),
          attributes: map(),
          depth: non_neg_integer(),
          path: [String.t()]
        }

  defstruct [:id, :type, :attributes, :depth, :path]

  @doc """
  Creates a new Entity struct.
  """
  def new(id, type, opts \\ []) do
    %__MODULE__{
      id: id,
      type: type,
      attributes: Keyword.get(opts, :attributes, %{}),
      depth: Keyword.get(opts, :depth, 0),
      path: Keyword.get(opts, :path, [id])
    }
  end

  @doc """
  Extends an entity's path with a new hop.
  """
  def extend_path(%__MODULE__{} = entity, next_id) do
    %{entity | depth: entity.depth + 1, path: entity.path ++ [next_id]}
  end
end

defmodule Mimo.SemanticStore.Predicates do
  @moduledoc """
  Predefined predicates for type safety and consistency.

  Using standardized predicates ensures consistent graph structure
  and enables meaningful inference rules.
  """

  @predicates %{
    # Organizational relationships
    reports_to: "reports_to",
    manages: "manages",
    belongs_to: "belongs_to",
    member_of: "member_of",

    # Spatial relationships
    located_in: "located_in",
    contains: "contains",
    adjacent_to: "adjacent_to",

    # Dependency relationships
    requires: "requires",
    depends_on: "depends_on",
    provides: "provides",

    # Taxonomic relationships
    is_a: "is_a",
    instance_of: "instance_of",
    subclass_of: "subclass_of",

    # Temporal relationships
    precedes: "precedes",
    follows: "follows",
    overlaps: "overlaps",

    # Ownership/attribution
    owns: "owns",
    created_by: "created_by",
    authored_by: "authored_by"
  }

  @doc """
  Returns all standard predicates.
  """
  def all, do: @predicates

  @doc """
  Gets the canonical form of a predicate.
  """
  def canonical(key) when is_atom(key), do: Map.get(@predicates, key)
  def canonical(key) when is_binary(key), do: key

  @doc """
  Checks if a predicate is valid.
  """
  def valid?(predicate) when is_binary(predicate) do
    predicate in Map.values(@predicates)
  end

  @doc """
  Returns the inverse predicate if one exists.

  ## Examples

      iex> Predicates.inverse("reports_to")
      "manages"
      
      iex> Predicates.inverse("contains")
      "located_in"
  """
  def inverse(predicate) do
    inverses = %{
      "reports_to" => "manages",
      "manages" => "reports_to",
      "belongs_to" => "contains",
      "contains" => "belongs_to",
      "located_in" => "contains",
      "requires" => "provides",
      "provides" => "requires",
      "depends_on" => "provides",
      "precedes" => "follows",
      "follows" => "precedes",
      "owns" => "owned_by",
      "owned_by" => "owns",
      "is_a" => nil,
      "instance_of" => nil,
      "subclass_of" => nil
    }

    Map.get(inverses, predicate)
  end

  @doc """
  Checks if a predicate is transitive (supports multi-hop traversal).

  ## Examples

      iex> Predicates.transitive?("reports_to")
      true
      
      iex> Predicates.transitive?("adjacent_to")
      false
  """
  def transitive?(predicate) do
    transitive = ~w(reports_to belongs_to located_in contains depends_on subclass_of)
    predicate in transitive
  end
end
