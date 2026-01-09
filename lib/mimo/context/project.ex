defmodule Mimo.Context.Project do
  @moduledoc """
  SPEC-097: Project Registry for Universal Context Understanding.

  Stores project metadata with aliases for reference resolution.
  Uses ETS for storage (no database migrations required).

  ## Usage

      # Register a project
      Project.register("/path/to/project", name: "My App")

      # Find by path or alias
      Project.find("/path/to/project")
      Project.find_by_alias("my-app")

      # List recent projects
      Project.recent(5)
  """

  require Logger

  @table :mimo_projects

  defstruct [
    :id,
    :name,
    :path,
    :aliases,
    :fingerprint,
    :last_active,
    :inserted_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          path: String.t(),
          aliases: [String.t()],
          fingerprint: String.t() | nil,
          last_active: DateTime.t(),
          inserted_at: DateTime.t()
        }

  @doc """
  Initialize the ETS table. Called on application start.
  """
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
      Logger.info("[SPEC-097] Project registry initialized")
    end

    :ok
  end

  @doc """
  Register or update a project.

  ## Options
  - `:name` - Human-readable project name (default: directory basename)
  - `:aliases` - List of aliases for this project
  - `:fingerprint` - Onboard fingerprint for change detection
  """
  @spec register(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def register(path, opts \\ []) do
    abs_path = Path.expand(path)

    unless File.dir?(abs_path) do
      {:error, "Path does not exist or is not a directory: #{abs_path}"}
    else
      now = DateTime.utc_now()
      basename = Path.basename(abs_path)

      # Check if project already exists
      existing = find(abs_path)

      project = %__MODULE__{
        id: existing[:id] || generate_id(),
        name: Keyword.get(opts, :name, existing[:name] || basename),
        path: abs_path,
        aliases: merge_aliases(existing[:aliases], Keyword.get(opts, :aliases, [])),
        fingerprint: Keyword.get(opts, :fingerprint, existing[:fingerprint]),
        last_active: now,
        inserted_at: existing[:inserted_at] || now
      }

      :ets.insert(@table, {abs_path, project})

      Logger.debug("[SPEC-097] Project registered: #{project.name} (#{abs_path})")
      {:ok, project}
    end
  end

  @doc """
  Find a project by its absolute path.
  """
  @spec find(String.t()) :: t() | nil
  def find(path) do
    abs_path = Path.expand(path)

    case :ets.lookup(@table, abs_path) do
      [{^abs_path, project}] -> project
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Find a project by name or alias.
  """
  @spec find_by_name_or_alias(String.t()) :: t() | nil
  def find_by_name_or_alias(query) do
    query_lower = String.downcase(query)

    all()
    |> Enum.find(fn p ->
      String.downcase(p.name) == query_lower or
        Enum.any?(p.aliases || [], &(String.downcase(&1) == query_lower))
    end)
  end

  @doc """
  Get all registered projects.
  """
  @spec all() :: [t()]
  def all do
    try do
      :ets.tab2list(@table)
      |> Enum.map(fn {_path, project} -> project end)
    rescue
      ArgumentError -> []
    end
  end

  @doc """
  Get N most recent projects.
  """
  @spec recent(non_neg_integer()) :: [t()]
  def recent(n \\ 5) do
    all()
    |> Enum.sort_by(& &1.last_active, {:desc, DateTime})
    |> Enum.take(n)
  end

  @doc """
  Update last_active timestamp for a project.
  """
  @spec touch(String.t()) :: :ok
  def touch(path) do
    abs_path = Path.expand(path)

    case find(abs_path) do
      nil ->
        :ok

      project ->
        updated = %{project | last_active: DateTime.utc_now()}
        :ets.insert(@table, {abs_path, updated})
        :ok
    end
  end

  @doc """
  Add an alias to a project.
  """
  @spec add_alias(String.t(), String.t()) :: :ok | {:error, term()}
  def add_alias(path, new_alias) do
    abs_path = Path.expand(path)

    case find(abs_path) do
      nil ->
        {:error, "Project not found: #{abs_path}"}

      project ->
        updated_aliases = Enum.uniq([new_alias | project.aliases || []])
        updated = %{project | aliases: updated_aliases}
        :ets.insert(@table, {abs_path, updated})
        :ok
    end
  end

  # Private helpers

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp merge_aliases(existing, new) do
    ((existing || []) ++ (new || []))
    |> Enum.uniq()
    |> Enum.reject(&is_nil/1)
  end
end
