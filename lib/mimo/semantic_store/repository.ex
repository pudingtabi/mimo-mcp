defmodule Mimo.SemanticStore.Repository do
  @moduledoc """
  Repository pattern wrapper for Semantic Store operations.
  
  Provides a clean API for CRUD operations on semantic triples,
  with validation and convenience functions.
  """

  alias Mimo.SemanticStore.Triple
  alias Mimo.Repo

  import Ecto.Query
  require Logger

  @doc """
  Creates a new triple.
  
  ## Parameters
  
    - `attrs` - Map with triple attributes:
      - `:subject_id` (required)
      - `:subject_type` (required)
      - `:predicate` (required)
      - `:object_id` (required)
      - `:object_type` (required)
      - `:confidence` (optional, default: 1.0)
      - `:source` (optional)
      - `:ttl` (optional, seconds)
      - `:metadata` (optional)
  
  ## Returns
  
    - `{:ok, triple}` - Successfully created triple
    - `{:error, changeset}` - Validation errors
  """
  @spec create(map()) :: {:ok, Triple.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %Triple{}
    |> Triple.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates a triple, raising on error.
  """
  @spec create!(map()) :: Triple.t()
  def create!(attrs) do
    %Triple{}
    |> Triple.changeset(attrs)
    |> Repo.insert!()
  end

  @doc """
  Upserts a triple (insert or update if exists).
  
  Uses the unique constraint on (subject_hash, predicate, object_id, object_type).
  """
  @spec upsert(map()) :: {:ok, Triple.t()} | {:error, Ecto.Changeset.t()}
  def upsert(attrs) do
    %Triple{}
    |> Triple.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:confidence, :source, :ttl, :metadata, :updated_at]},
      conflict_target: [:subject_hash, :predicate, :object_id, :object_type]
    )
  end

  @doc """
  Batch inserts multiple triples efficiently.
  """
  @spec batch_create([map()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def batch_create(triples_attrs) when is_list(triples_attrs) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:microsecond)

    entries =
      triples_attrs
      |> Enum.map(fn attrs ->
        attrs
        |> Map.put(:id, Ecto.UUID.generate())
        |> Map.put(:subject_hash, Triple.hash_entity(attrs.subject_id, attrs.subject_type))
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)
        |> Map.put_new(:confidence, 1.0)
        |> Map.put_new(:metadata, %{})
      end)

    {count, _} = Repo.insert_all(Triple, entries, on_conflict: :nothing)
    {:ok, count}
  rescue
    e ->
      Logger.error("Batch create failed: #{Exception.message(e)}")
      {:error, e}
  end

  @doc """
  Gets a triple by ID.
  """
  @spec get(String.t()) :: Triple.t() | nil
  def get(id) do
    Repo.get(Triple, id)
  end

  @doc """
  Gets all triples for a subject.
  """
  @spec get_by_subject(String.t(), String.t()) :: [Triple.t()]
  def get_by_subject(subject_id, subject_type) do
    subject_hash = Triple.hash_entity(subject_id, subject_type)

    from(t in Triple, where: t.subject_hash == ^subject_hash)
    |> Repo.all()
  end

  @doc """
  Gets all triples with a specific predicate.
  """
  @spec get_by_predicate(String.t(), keyword()) :: [Triple.t()]
  def get_by_predicate(predicate, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    min_confidence = Keyword.get(opts, :min_confidence, 0.0)

    from(t in Triple,
      where: t.predicate == ^predicate and t.confidence >= ^min_confidence,
      limit: ^limit,
      order_by: [desc: t.confidence]
    )
    |> Repo.all()
  end

  @doc """
  Gets all triples pointing to an object.
  """
  @spec get_by_object(String.t(), String.t()) :: [Triple.t()]
  def get_by_object(object_id, object_type) do
    from(t in Triple,
      where: t.object_id == ^object_id and t.object_type == ^object_type
    )
    |> Repo.all()
  end

  @doc """
  Updates a triple's confidence score.
  """
  @spec update_confidence(String.t(), float()) :: {:ok, Triple.t()} | {:error, term()}
  def update_confidence(id, confidence) when confidence >= 0.0 and confidence <= 1.0 do
    case get(id) do
      nil -> {:error, :not_found}
      triple ->
        triple
        |> Triple.changeset(%{confidence: confidence})
        |> Repo.update()
    end
  end

  @doc """
  Deletes a triple by ID.
  """
  @spec delete(String.t()) :: {:ok, Triple.t()} | {:error, term()}
  def delete(id) do
    case get(id) do
      nil -> {:error, :not_found}
      triple -> Repo.delete(triple)
    end
  end

  @doc """
  Deletes all triples for a subject.
  """
  @spec delete_by_subject(String.t(), String.t()) :: {non_neg_integer(), nil}
  def delete_by_subject(subject_id, subject_type) do
    subject_hash = Triple.hash_entity(subject_id, subject_type)

    from(t in Triple, where: t.subject_hash == ^subject_hash)
    |> Repo.delete_all()
  end

  @doc """
  Cleans up expired triples based on TTL.
  """
  @spec cleanup_expired() :: {:ok, non_neg_integer()}
  def cleanup_expired do
    # SQLite doesn't support datetime_add in Ecto, use raw query
    query = """
    DELETE FROM semantic_triples
    WHERE ttl IS NOT NULL
      AND datetime(inserted_at, '+' || ttl || ' seconds') < datetime('now')
    """

    case Ecto.Adapters.SQL.query(Repo, query, []) do
      {:ok, %{num_rows: count}} ->
        if count > 0 do
          Logger.info("Cleaned up #{count} expired semantic triples")
        end
        {:ok, count}

      {:error, error} ->
        Logger.error("TTL cleanup failed: #{inspect(error)}")
        {:ok, 0}
    end
  end

  @doc """
  Returns statistics about the semantic store.
  """
  @spec stats() :: map()
  def stats do
    total = Repo.aggregate(Triple, :count, :id)

    by_predicate =
      from(t in Triple,
        group_by: t.predicate,
        select: {t.predicate, count(t.id)}
      )
      |> Repo.all()
      |> Map.new()

    avg_confidence =
      Repo.aggregate(Triple, :avg, :confidence) || 0.0

    %{
      total_triples: total,
      by_predicate: by_predicate,
      average_confidence: Float.round(avg_confidence, 3)
    }
  end
end
