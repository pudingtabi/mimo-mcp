defmodule Mimo.SemanticStore.Query do
  @moduledoc """
  Query engine for the Semantic Store.

  Provides efficient graph queries using SQLite recursive CTEs
  for transitive closure and pattern matching operations.

  ## Query Types

  - **Transitive Closure**: Find all entities reachable via a predicate
  - **Pattern Match**: Find entities matching multiple conditions
  - **Path Finding**: Find shortest paths between entities
  """

  import Ecto.Query
  alias Mimo.SemanticStore.{Triple, Entity}
  alias Mimo.Repo

  require Logger

  @doc """
  Finds all entities reachable from `start_entity` via `predicate`.

  Uses SQLite recursive CTE for efficient transitive closure computation.

  ## Parameters

    - `start_id` - Starting entity ID
    - `start_type` - Starting entity type
    - `predicate` - Relationship to traverse
    - `opts` - Options:
      - `:max_depth` - Maximum traversal depth (default: 5)
      - `:min_confidence` - Minimum confidence threshold (default: 0.7)
      - `:direction` - `:forward` (default) or `:backward`

  ## Returns

  List of `%Entity{}` structs representing reachable entities.

  ## Examples

      iex> Query.transitive_closure("alice", "person", "reports_to")
      [
        %Entity{id: "bob", type: "person", depth: 1, path: ["alice", "bob"]},
        %Entity{id: "ceo", type: "person", depth: 2, path: ["alice", "bob", "ceo"]}
      ]
  """
  @spec transitive_closure(String.t(), String.t(), String.t(), keyword()) :: [Entity.t()]
  def transitive_closure(start_id, start_type, predicate, opts \\ []) do
    max_depth = Keyword.get(opts, :max_depth, 5)
    min_confidence = Keyword.get(opts, :min_confidence, 0.7)
    direction = Keyword.get(opts, :direction, :forward)

    # SQLite recursive CTE for transitive closure
    # Note: SQLite uses || for string concatenation
    query =
      case direction do
        :forward -> forward_traversal_query()
        :backward -> backward_traversal_query()
      end

    case Ecto.Adapters.SQL.query(Repo, query, [
           start_id,
           start_type,
           predicate,
           min_confidence,
           max_depth
         ]) do
      {:ok, %{rows: rows}} ->
        rows
        |> Enum.map(fn [id, type, depth, path] ->
          %Entity{
            id: id,
            type: type,
            depth: depth,
            path: String.split(path, "->")
          }
        end)

      {:error, error} ->
        Logger.error("Transitive closure query failed: #{inspect(error)}")
        []
    end
  end

  defp forward_traversal_query do
    """
    WITH RECURSIVE traversal(entity_id, entity_type, depth, path, visited) AS (
      -- Anchor: Starting entity
      SELECT 
        ?1 as entity_id,
        ?2 as entity_type,
        0 as depth,
        ?1 as path,
        ?1 as visited
      
      UNION ALL
      
      -- Recursive: Follow predicate edges forward (subject -> object)
      SELECT 
        t.object_id,
        t.object_type,
        tr.depth + 1,
        tr.path || '->' || t.object_id,
        tr.visited || ',' || t.object_id
      FROM semantic_triples t
      INNER JOIN traversal tr ON t.subject_id = tr.entity_id
      WHERE t.predicate = ?3
        AND t.confidence >= ?4
        AND tr.depth < ?5
        AND instr(tr.visited, t.object_id) = 0
    )
    SELECT DISTINCT entity_id, entity_type, depth, path 
    FROM traversal
    WHERE depth > 0
    ORDER BY depth ASC
    """
  end

  defp backward_traversal_query do
    """
    WITH RECURSIVE traversal(entity_id, entity_type, depth, path, visited) AS (
      -- Anchor: Starting entity (target)
      SELECT 
        ?1 as entity_id,
        ?2 as entity_type,
        0 as depth,
        ?1 as path,
        ?1 as visited
      
      UNION ALL
      
      -- Recursive: Follow predicate edges backward (object <- subject)
      SELECT 
        t.subject_id,
        t.subject_type,
        tr.depth + 1,
        t.subject_id || '->' || tr.path,
        tr.visited || ',' || t.subject_id
      FROM semantic_triples t
      INNER JOIN traversal tr ON t.object_id = tr.entity_id
      WHERE t.predicate = ?3
        AND t.confidence >= ?4
        AND tr.depth < ?5
        AND instr(tr.visited, t.subject_id) = 0
    )
    SELECT DISTINCT entity_id, entity_type, depth, path 
    FROM traversal
    WHERE depth > 0
    ORDER BY depth ASC
    """
  end

  @doc """
  Pattern matching query: find entities matching multiple conditions.

  ## Parameters

    - `clauses` - List of pattern clauses

  ## Clause Format

    - `{:subject, predicate, object}` - Subject has predicate to object
    - `{:any, predicate, object}` - Any entity with predicate to object
    - `{:subject, predicate, :any}` - Subject has predicate to any entity

  ## Examples

      # Find entities that report to "ceo" AND are located in "sf"
      iex> Query.pattern_match([
      ...>   {:any, "reports_to", "ceo"},
      ...>   {:any, "located_in", "sf"}
      ...> ])
      [%Triple{subject_id: "alice", ...}]
  """
  @spec pattern_match([tuple()]) :: [Triple.t()]
  def pattern_match(clauses) when is_list(clauses) do
    # For each clause, get the set of subject_hashes that match
    # Then intersect all sets to find subjects matching ALL clauses
    hash_sets =
      clauses
      |> Enum.map(fn clause ->
        from(t in Triple, select: t.subject_hash)
        |> apply_clause(clause)
        |> Repo.all()
        |> MapSet.new()
      end)

    # Intersect all hash sets
    matching_hashes =
      hash_sets
      |> Enum.reduce(fn set, acc -> MapSet.intersection(acc, set) end)
      |> MapSet.to_list()

    # Fetch full triples for matching subjects
    if matching_hashes == [] do
      []
    else
      from(t in Triple, where: t.subject_hash in ^matching_hashes)
      |> Repo.all()
    end
  end

  defp apply_clause(query, {:any, predicate, object}) do
    from(t in query,
      where: t.predicate == ^predicate and t.object_id == ^object
    )
  end

  defp apply_clause(query, {subject, predicate, :any}) do
    from(t in query,
      where: t.subject_id == ^subject and t.predicate == ^predicate
    )
  end

  defp apply_clause(query, {subject, predicate, object}) do
    from(t in query,
      where:
        t.subject_id == ^subject and
          t.predicate == ^predicate and
          t.object_id == ^object
    )
  end

  @doc """
  Finds the shortest path between two entities.

  Uses bidirectional BFS for efficiency.

  ## Returns

    - `{:ok, path}` - List of entity IDs forming the path
    - `{:error, :no_path}` - No path exists within max_depth
  """
  @spec find_path(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, :no_path}
  def find_path(from_id, to_id, predicate, opts \\ []) do
    max_depth = Keyword.get(opts, :max_depth, 10)
    min_confidence = Keyword.get(opts, :min_confidence, 0.7)

    query = """
    WITH RECURSIVE path_search(current_id, path, depth) AS (
      SELECT ?1, ?1, 0
      
      UNION ALL
      
      SELECT 
        t.object_id,
        ps.path || '->' || t.object_id,
        ps.depth + 1
      FROM semantic_triples t
      INNER JOIN path_search ps ON t.subject_id = ps.current_id
      WHERE t.predicate = ?3
        AND t.confidence >= ?4
        AND ps.depth < ?5
        AND instr(ps.path, t.object_id) = 0
    )
    SELECT path 
    FROM path_search 
    WHERE current_id = ?2
    ORDER BY depth ASC
    LIMIT 1
    """

    case Ecto.Adapters.SQL.query(Repo, query, [from_id, to_id, predicate, min_confidence, max_depth]) do
      {:ok, %{rows: [[path]]}} ->
        {:ok, String.split(path, "->")}

      {:ok, %{rows: []}} ->
        {:error, :no_path}

      {:error, error} ->
        Logger.error("Path finding query failed: #{inspect(error)}")
        {:error, :no_path}
    end
  end

  @doc """
  Gets all direct relationships for an entity.
  """
  @spec get_relationships(String.t(), String.t()) :: %{
          outgoing: [Triple.t()],
          incoming: [Triple.t()]
        }
  def get_relationships(entity_id, entity_type) do
    subject_hash = Triple.hash_entity(entity_id, entity_type)

    outgoing =
      from(t in Triple, where: t.subject_hash == ^subject_hash)
      |> Repo.all()

    incoming =
      from(t in Triple, where: t.object_id == ^entity_id)
      |> Repo.all()

    %{outgoing: outgoing, incoming: incoming}
  end

  @doc """
  Counts entities by type in the semantic store.
  """
  @spec count_by_type() :: %{String.t() => non_neg_integer()}
  def count_by_type do
    from(t in Triple,
      group_by: t.subject_type,
      select: {t.subject_type, count(t.id)}
    )
    |> Repo.all()
    |> Map.new()
  end
end
