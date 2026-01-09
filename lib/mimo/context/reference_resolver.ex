defmodule Mimo.Context.ReferenceResolver do
  @moduledoc """
  SPEC-097: Reference Resolver for Universal Context Understanding.

  Resolves vague references like "last project", "current project",
  "project Alpha", "A", "that module" to actual structs.

  ## Usage

      # Project references
      {:ok, project} = ReferenceResolver.resolve("last project")
      {:ok, project} = ReferenceResolver.resolve("project mimo")

      # Entity references (Phase 2)
      {:ok, entity} = ReferenceResolver.resolve_entity("A")
      {:ok, entity} = ReferenceResolver.resolve_entity("that module")
  """

  alias Mimo.Context.{Entity, Project, WorkingMemory}

  @type project_resolution :: {:ok, Project.t()} | {:error, :not_found | :ambiguous}
  @type entity_resolution :: {:ok, Entity.t()} | {:error, :not_found | :ambiguous}

  # ============================================
  # Project Resolution (Phase 1)
  # ============================================

  @doc """
  Resolve a reference string to a project.

  Supports:
  - "last project" / "previous project"
  - "current project" / "this project"
  - "project <name>" / "<name> project"
  """
  @spec resolve(String.t()) :: project_resolution()
  def resolve(reference) when is_binary(reference) do
    reference
    |> String.downcase()
    |> String.trim()
    |> do_resolve()
  end

  def resolve(_), do: {:error, :not_found}

  # Temporal references
  defp do_resolve("last project"), do: resolve_last()
  defp do_resolve("previous project"), do: resolve_last()
  defp do_resolve("the last project"), do: resolve_last()

  # Current project references
  defp do_resolve("current project"), do: resolve_current()
  defp do_resolve("this project"), do: resolve_current()
  defp do_resolve("the current project"), do: resolve_current()

  # Named project references
  defp do_resolve("project " <> name), do: resolve_by_name(name)

  # Handle "X project" pattern
  defp do_resolve(ref) do
    cond do
      String.ends_with?(ref, " project") ->
        name = String.replace_suffix(ref, " project", "")
        resolve_by_name(name)

      true ->
        # Try as direct name/alias lookup
        resolve_by_name(ref)
    end
  end

  @doc """
  Resolve "last project" - the project before current.
  """
  @spec resolve_last() :: project_resolution()
  def resolve_last do
    case WorkingMemory.last_project_info() do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  @doc """
  Resolve "current project" - the currently active project.
  """
  @spec resolve_current() :: project_resolution()
  def resolve_current do
    case WorkingMemory.current_project_info() do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  @doc """
  Resolve by project name or alias.
  """
  @spec resolve_by_name(String.t()) :: project_resolution()
  def resolve_by_name(name) do
    case Project.find_by_name_or_alias(name) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  # ============================================
  # Entity Resolution (Phase 2)
  # ============================================

  @doc """
  Resolve an entity reference like "A", "that module", "the auth function".

  Searches by name and alias, preferring current project context.
  """
  @spec resolve_entity(String.t(), keyword()) :: entity_resolution()
  def resolve_entity(reference, opts \\ []) do
    reference
    |> normalize_entity_reference()
    |> do_resolve_entity(opts)
  end

  defp normalize_entity_reference(ref) do
    ref
    |> String.trim()
    |> String.replace(~r/^(that|the|this)\s+/i, "")
    |> String.trim()
  end

  defp do_resolve_entity(ref, opts) do
    project = Keyword.get(opts, :project) || WorkingMemory.current_project()

    Entity.resolve(ref, project: project)
  end

  @doc """
  Track an entity for future reference.
  Convenience wrapper around Entity.track.
  """
  @spec track_entity(String.t(), Entity.entity_type(), String.t() | nil, keyword()) ::
          {:ok, Entity.t()} | {:error, term()}
  def track_entity(name, type, context \\ nil, opts \\ []) do
    project = Keyword.get(opts, :project) || WorkingMemory.current_project()
    aliases = Keyword.get(opts, :aliases, [])

    Entity.track(name, type, project, context, aliases: aliases)
  end

  @doc """
  Record a mention of an entity by name or alias.
  Finds the entity and updates its mention history.
  """
  @spec mention_entity(String.t(), String.t()) :: :ok | {:error, term()}
  def mention_entity(reference, context \\ "") do
    case resolve_entity(reference) do
      {:ok, entity} -> Entity.mention(entity.id, context)
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc """
  Get recently mentioned entities in current project.
  """
  @spec recent_entities(non_neg_integer()) :: [Entity.t()]
  def recent_entities(n \\ 10) do
    project = WorkingMemory.current_project()
    Entity.recent(project, n)
  end

  # ============================================
  # Utility Functions
  # ============================================

  @doc """
  Get all resolvable projects with metadata.
  """
  @spec list_available() :: [map()]
  def list_available do
    current = WorkingMemory.current_project()
    last = WorkingMemory.last_project()

    Project.all()
    |> Enum.map(fn p ->
      %{
        name: p.name,
        path: p.path,
        aliases: p.aliases,
        is_current: p.path == current,
        is_last: p.path == last,
        last_active: p.last_active
      }
    end)
  end

  @doc """
  Check if a string looks like a project reference.
  """
  @spec is_project_reference?(String.t()) :: boolean()
  def is_project_reference?(text) when is_binary(text) do
    lower = String.downcase(text)

    String.contains?(lower, "project") or
      String.contains?(lower, "last") or
      String.contains?(lower, "previous") or
      String.contains?(lower, "current")
  end

  def is_project_reference?(_), do: false

  @doc """
  Check if a string looks like an entity reference.
  """
  @spec is_entity_reference?(String.t()) :: boolean()
  def is_entity_reference?(text) when is_binary(text) do
    lower = String.downcase(text)

    # Single letters like "A", "B" are likely entity references
    String.match?(text, ~r/^[A-Z]$/) or
      String.starts_with?(lower, "that ") or
      String.starts_with?(lower, "the ") or
      String.starts_with?(lower, "this ")
  end

  def is_entity_reference?(_), do: false
end
