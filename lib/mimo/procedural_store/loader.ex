defmodule Mimo.ProceduralStore.Loader do
  @moduledoc """
  Loads and caches procedure definitions.

  Provides efficient procedure lookup with ETS caching
  and version resolution.
  """

  alias Mimo.ProceduralStore.Procedure
  alias Mimo.Repo

  require Logger

  @cache_table :procedure_cache

  @doc """
  Initializes the procedure cache.
  """
  def init do
    :ets.new(@cache_table, [:named_table, :set, :public, read_concurrency: true])
    :ok
  end

  @doc """
  Loads a procedure by name and version.

  ## Parameters

    - `name` - Procedure name
    - `version` - Specific version or "latest"

  ## Returns

    - `{:ok, procedure}` - Procedure found
    - `{:error, :not_found}` - Procedure not found
  """
  @spec load(String.t(), String.t()) :: {:ok, Procedure.t()} | {:error, :not_found}
  def load(name, "latest") do
    # Find the latest active version
    import Ecto.Query

    query =
      from(p in Procedure,
        where: p.name == ^name and p.active == true,
        order_by: [desc: p.version],
        limit: 1
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      procedure -> {:ok, procedure}
    end
  end

  def load(name, version) do
    cache_key = {name, version}

    # Check cache first
    case :ets.lookup(@cache_table, cache_key) do
      [{^cache_key, procedure}] ->
        {:ok, procedure}

      [] ->
        # Load from database
        case load_from_db(name, version) do
          {:ok, procedure} ->
            # Cache it
            :ets.insert(@cache_table, {cache_key, procedure})
            {:ok, procedure}

          error ->
            error
        end
    end
  end

  @doc """
  Loads a procedure by hash (for integrity verification).
  """
  @spec load_by_hash(String.t()) :: {:ok, Procedure.t()} | {:error, :not_found}
  def load_by_hash(hash) do
    import Ecto.Query

    query = from(p in Procedure, where: p.hash == ^hash and p.active == true)

    case Repo.one(query) do
      nil -> {:error, :not_found}
      procedure -> {:ok, procedure}
    end
  end

  @doc """
  Lists all procedures, optionally filtered.
  """
  @spec list(keyword()) :: [Procedure.t()]
  def list(opts \\ []) do
    import Ecto.Query

    active_only = Keyword.get(opts, :active_only, true)
    name_filter = Keyword.get(opts, :name)

    query = from(p in Procedure)

    query =
      if active_only do
        where(query, [p], p.active == true)
      else
        query
      end

    query =
      if name_filter do
        where(query, [p], p.name == ^name_filter)
      else
        query
      end

    query
    |> order_by([p], asc: p.name, desc: p.version)
    |> Repo.all()
  end

  @doc """
  Registers a new procedure.
  """
  @spec register(map()) :: {:ok, Procedure.t()} | {:error, Ecto.Changeset.t()}
  def register(attrs) do
    result =
      %Procedure{}
      |> Procedure.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, procedure} ->
        # Invalidate cache for this name
        invalidate_cache(procedure.name)
        {:ok, procedure}

      error ->
        error
    end
  end

  @doc """
  Deactivates a procedure version.
  """
  @spec deactivate(String.t(), String.t()) :: {:ok, Procedure.t()} | {:error, term()}
  def deactivate(name, version) do
    case load_from_db(name, version) do
      {:ok, procedure} ->
        result =
          procedure
          |> Procedure.changeset(%{active: false})
          |> Repo.update()

        case result do
          {:ok, updated} ->
            invalidate_cache(name, version)
            {:ok, updated}

          error ->
            error
        end

      error ->
        error
    end
  end

  @doc """
  Invalidates cache for a procedure.
  """
  @spec invalidate_cache(String.t(), String.t() | nil) :: :ok
  def invalidate_cache(name, version \\ nil) do
    if version do
      :ets.delete(@cache_table, {name, version})
    else
      # Delete all versions of this procedure
      :ets.match_delete(@cache_table, {{name, :_}, :_})
    end

    :ok
  end

  @doc """
  Clears the entire procedure cache.
  """
  @spec clear_cache() :: :ok
  def clear_cache do
    :ets.delete_all_objects(@cache_table)
    :ok
  end

  # Private

  defp load_from_db(name, version) do
    import Ecto.Query

    query =
      from(p in Procedure,
        where: p.name == ^name and p.version == ^version and p.active == true
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      procedure -> {:ok, procedure}
    end
  end
end

defmodule Mimo.ProceduralStore.Registry do
  @moduledoc """
  GenServer that manages the procedure registry lifecycle.
  """
  use GenServer

  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Initialize loader cache
    Mimo.ProceduralStore.Loader.init()
    Logger.info("✅ Procedural Store registry initialized")
    {:ok, %{}}
  end
end
