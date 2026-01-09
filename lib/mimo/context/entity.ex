defmodule Mimo.Context.Entity do
  @moduledoc """
  SPEC-097 Phase 2: Entity Tracker for Universal Context Understanding.

  Tracks entities (modules, functions, concepts) mentioned in conversations
  with aliases for reference resolution.

  ## Usage

      # Track a new entity
      Entity.track("UserController", :module, "/project/path", "handles user auth")

      # Add an alias
      Entity.add_alias(entity_id, "A")
      Entity.add_alias(entity_id, "that controller")

      # Record a mention
      Entity.mention(entity_id, "discussing auth flow")

      # Resolve a reference
      Entity.resolve("A", project: "/project/path")
      Entity.resolve("that module")
  """

  require Logger

  @table :mimo_entities

  defstruct [
    :id,
    :name,
    :type,
    :project_path,
    :context,
    aliases: [],
    mentions: [],
    last_mentioned: nil,
    created_at: nil
  ]

  @type entity_type :: :module | :function | :concept | :file | :pattern | :variable | :other

  @type mention :: %{
          timestamp: DateTime.t(),
          context: String.t()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          type: entity_type(),
          project_path: String.t() | nil,
          context: String.t() | nil,
          aliases: [String.t()],
          mentions: [mention()],
          last_mentioned: DateTime.t() | nil,
          created_at: DateTime.t()
        }

  @doc """
  Initialize the ETS table. Called on application start.
  """
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
      Logger.info("[SPEC-097] Entity tracker initialized")
    end

    :ok
  end

  @doc """
  Track a new entity or update existing one.

  ## Parameters
  - `name` - Primary name of the entity
  - `type` - Type atom (:module, :function, :concept, etc.)
  - `project_path` - Path to the project (optional)
  - `context` - Brief description (optional)
  - `opts` - Additional options:
    - `:aliases` - Initial aliases for this entity
  """
  @spec track(String.t(), entity_type(), String.t() | nil, String.t() | nil, keyword()) ::
          {:ok, t()} | {:error, term()}
  def track(name, type, project_path \\ nil, context \\ nil, opts \\ []) do
    unless is_valid_name?(name) do
      {:error, "Invalid entity name"}
    else
      now = DateTime.utc_now()

      # Check if entity already exists by name + project
      existing = find_by_name(name, project_path)

      entity = %__MODULE__{
        id: existing[:id] || generate_id(),
        name: name,
        type: type,
        project_path: project_path && Path.expand(project_path),
        context: context || existing[:context],
        aliases: merge_aliases(existing[:aliases], Keyword.get(opts, :aliases, [])),
        mentions: existing[:mentions] || [],
        last_mentioned: existing[:last_mentioned],
        created_at: existing[:created_at] || now
      }

      :ets.insert(@table, {entity.id, entity})

      Logger.debug("[SPEC-097] Entity tracked: #{entity.name} (#{entity.type})")
      {:ok, entity}
    end
  end

  @doc """
  Add an alias to an entity.
  """
  @spec add_alias(String.t(), String.t()) :: :ok | {:error, term()}
  def add_alias(entity_id, new_alias) do
    case find(entity_id) do
      nil ->
        {:error, "Entity not found: #{entity_id}"}

      entity ->
        new_alias_lower = String.downcase(String.trim(new_alias))

        if new_alias_lower in Enum.map(entity.aliases, &String.downcase/1) do
          # Already exists
          :ok
        else
          updated = %{entity | aliases: [new_alias | entity.aliases]}
          :ets.insert(@table, {entity_id, updated})
          :ok
        end
    end
  end

  @doc """
  Record a mention of an entity.
  """
  @spec mention(String.t(), String.t()) :: :ok | {:error, term()}
  def mention(entity_id, context \\ "") do
    case find(entity_id) do
      nil ->
        {:error, "Entity not found: #{entity_id}"}

      entity ->
        now = DateTime.utc_now()
        new_mention = %{timestamp: now, context: context}

        # Keep last 20 mentions
        updated_mentions = [new_mention | entity.mentions] |> Enum.take(20)

        updated = %{entity | mentions: updated_mentions, last_mentioned: now}

        :ets.insert(@table, {entity_id, updated})
        :ok
    end
  end

  @doc """
  Find an entity by ID.
  """
  @spec find(String.t()) :: t() | nil
  def find(entity_id) do
    case :ets.lookup(@table, entity_id) do
      [{^entity_id, entity}] -> entity
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Find an entity by name (exact match) and optional project.
  """
  @spec find_by_name(String.t(), String.t() | nil) :: t() | nil
  def find_by_name(name, project_path \\ nil) do
    name_lower = String.downcase(name)
    project = project_path && Path.expand(project_path)

    all()
    |> Enum.find(fn e ->
      name_matches = String.downcase(e.name) == name_lower
      project_matches = is_nil(project) or e.project_path == project
      name_matches and project_matches
    end)
  end

  @doc """
  Resolve a reference (name or alias) to an entity.
  Prefers current project, then searches all projects.
  """
  @spec resolve(String.t(), keyword()) :: {:ok, t()} | {:error, :not_found | :ambiguous}
  def resolve(reference, opts \\ []) do
    reference_lower = String.downcase(String.trim(reference))
    project_path = Keyword.get(opts, :project)

    # Try exact name match first
    if entity = find_by_name(reference, project_path) do
      {:ok, entity}
    else
      # Search aliases
      candidates = find_by_alias(reference_lower, project_path)

      case candidates do
        [] ->
          {:error, :not_found}

        [entity] ->
          {:ok, entity}

        multiple when length(multiple) > 1 ->
          # Try to disambiguate by recency
          sorted = Enum.sort_by(multiple, & &1.last_mentioned, {:desc, DateTime})
          # Return most recently mentioned
          {:ok, List.first(sorted)}
      end
    end
  end

  @doc """
  Find entities by alias.
  """
  @spec find_by_alias(String.t(), String.t() | nil) :: [t()]
  def find_by_alias(alias_str, project_path \\ nil) do
    alias_lower = String.downcase(alias_str)
    project = project_path && Path.expand(project_path)

    all()
    |> Enum.filter(fn e ->
      alias_matches = Enum.any?(e.aliases, &(String.downcase(&1) == alias_lower))
      project_matches = is_nil(project) or e.project_path == project
      alias_matches and project_matches
    end)
  end

  @doc """
  Get recently mentioned entities for a project.
  """
  @spec recent(String.t() | nil, non_neg_integer()) :: [t()]
  def recent(project_path \\ nil, n \\ 10) do
    project = project_path && Path.expand(project_path)

    all()
    |> Enum.filter(fn e ->
      (is_nil(project) or e.project_path == project) and
        not is_nil(e.last_mentioned)
    end)
    |> Enum.sort_by(& &1.last_mentioned, {:desc, DateTime})
    |> Enum.take(n)
  end

  @doc """
  Get all entities.
  """
  @spec all() :: [t()]
  def all do
    try do
      :ets.tab2list(@table)
      |> Enum.map(fn {_id, entity} -> entity end)
    rescue
      ArgumentError -> []
    end
  end

  @doc """
  Get entities by type.
  """
  @spec by_type(entity_type(), String.t() | nil) :: [t()]
  def by_type(type, project_path \\ nil) do
    project = project_path && Path.expand(project_path)

    all()
    |> Enum.filter(fn e ->
      e.type == type and (is_nil(project) or e.project_path == project)
    end)
  end

  @doc """
  Delete an entity.
  """
  @spec delete(String.t()) :: :ok
  def delete(entity_id) do
    :ets.delete(@table, entity_id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # Private helpers

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp is_valid_name?(name) do
    is_binary(name) and String.length(String.trim(name)) > 0
  end

  defp merge_aliases(existing, new) do
    ((existing || []) ++ (new || []))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&String.downcase/1)
  end
end
