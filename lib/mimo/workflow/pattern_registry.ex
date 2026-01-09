defmodule Mimo.Workflow.PatternRegistry do
  @moduledoc """
  SPEC-053: Workflow Pattern Registry

  Central registry for workflow patterns. Manages:
  - Seed patterns (pre-defined)
  - Learned patterns (extracted from usage)
  - Pattern lookup and search
  - Pattern persistence

  ## Usage

      # Get all patterns
      patterns = PatternRegistry.list_patterns()

      # Find pattern by ID
      {:ok, pattern} = PatternRegistry.get_pattern("debug_error_v1")

      # Search patterns by tags
      patterns = PatternRegistry.search_patterns(tags: ["debugging"])

      # Save a new pattern
      PatternRegistry.save_pattern(pattern)
  """
  use GenServer
  require Logger

  alias Mimo.Repo
  alias Mimo.Workflow.Pattern

  alias Mimo.Workflow.Patterns.{
    CodeNavigation,
    ContextGathering,
    DebugError,
    FileEdit,
    ProjectOnboarding
  }

  import Ecto.Query

  @seed_patterns [
    DebugError,
    FileEdit,
    ContextGathering,
    CodeNavigation,
    ProjectOnboarding
  ]

  defstruct patterns: %{},
            loaded_at: nil

  @doc """
  Starts the PatternRegistry GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Lists all available patterns.
  """
  @spec list_patterns() :: [Pattern.t()]
  def list_patterns do
    GenServer.call(__MODULE__, :list_patterns)
  end

  @doc """
  Gets a pattern by ID.
  """
  @spec get_pattern(String.t()) :: {:ok, Pattern.t()} | {:error, :not_found}
  def get_pattern(pattern_id) do
    GenServer.call(__MODULE__, {:get_pattern, pattern_id})
  end

  @doc """
  Gets a pattern by name.
  """
  @spec get_pattern_by_name(String.t()) :: {:ok, Pattern.t()} | {:error, :not_found}
  def get_pattern_by_name(name) do
    GenServer.call(__MODULE__, {:get_pattern_by_name, name})
  end

  @doc """
  Searches patterns by criteria.

  ## Options

    * `:tags` - Filter by tags (any match)
    * `:min_success_rate` - Minimum success rate
    * `:limit` - Maximum results
  """
  @spec search_patterns(keyword()) :: [Pattern.t()]
  def search_patterns(opts \\ []) do
    GenServer.call(__MODULE__, {:search_patterns, opts})
  end

  @doc """
  Saves a pattern to the registry and database.
  """
  @spec save_pattern(Pattern.t()) :: {:ok, Pattern.t()} | {:error, term()}
  def save_pattern(pattern) do
    GenServer.call(__MODULE__, {:save_pattern, pattern})
  end

  @doc """
  Updates a pattern's metrics after execution.
  """
  @spec update_pattern_metrics(String.t(), boolean(), integer()) :: :ok | {:error, term()}
  def update_pattern_metrics(pattern_id, success?, token_savings \\ 0) do
    GenServer.call(__MODULE__, {:update_metrics, pattern_id, success?, token_savings})
  end

  @doc """
  Reloads patterns from database.
  """
  @spec reload() :: :ok
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  @doc """
  Seeds default patterns into the database.
  """
  @spec seed_patterns() :: {:ok, integer()} | {:error, term()}
  def seed_patterns do
    GenServer.call(__MODULE__, :seed_patterns)
  end

  @impl true
  def init(_opts) do
    # Load patterns from database
    state = load_patterns(%__MODULE__{})

    {:ok, state}
  end

  @impl true
  def handle_call(:list_patterns, _from, state) do
    patterns = Map.values(state.patterns)
    {:reply, patterns, state}
  end

  @impl true
  def handle_call({:get_pattern, pattern_id}, _from, state) do
    result =
      case Map.get(state.patterns, pattern_id) do
        nil ->
          # Fallback: search by name if not found by ID
          state.patterns
          |> Map.values()
          |> Enum.find(fn p -> p.name == pattern_id end)
          |> case do
            nil -> {:error, :not_found}
            pattern -> {:ok, pattern}
          end

        pattern ->
          {:ok, pattern}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_pattern_by_name, name}, _from, state) do
    result =
      state.patterns
      |> Map.values()
      |> Enum.find(fn p -> p.name == name end)
      |> case do
        nil -> {:error, :not_found}
        pattern -> {:ok, pattern}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:search_patterns, opts}, _from, state) do
    tags = Keyword.get(opts, :tags, [])
    min_success_rate = Keyword.get(opts, :min_success_rate, 0.0)
    limit = Keyword.get(opts, :limit, 100)

    patterns =
      state.patterns
      |> Map.values()
      |> Enum.filter(fn p ->
        matches_tags?(p, tags) and p.success_rate >= min_success_rate
      end)
      |> Enum.sort_by(& &1.success_rate, :desc)
      |> Enum.take(limit)

    {:reply, patterns, state}
  end

  @impl true
  def handle_call({:save_pattern, pattern}, _from, state) do
    # Generate an ID if not present
    pattern_with_id =
      if pattern.id do
        pattern
      else
        id = "#{pattern.name}_v1"
        %{pattern | id: id}
      end

    case persist_pattern(pattern_with_id) do
      {:ok, saved} ->
        new_patterns = Map.put(state.patterns, saved.id, saved)
        {:reply, {:ok, saved}, %{state | patterns: new_patterns}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:update_metrics, pattern_id, success?, token_savings}, _from, state) do
    case Map.get(state.patterns, pattern_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      pattern ->
        changeset = Pattern.update_success_metrics(pattern, success?, token_savings)

        case Repo.update(changeset) do
          {:ok, updated} ->
            new_patterns = Map.put(state.patterns, pattern_id, updated)
            {:reply, :ok, %{state | patterns: new_patterns}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call(:reload, _from, _state) do
    new_state = load_patterns(%__MODULE__{})
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:seed_patterns, _from, _state) do
    count =
      @seed_patterns
      |> Enum.map(& &1.pattern())
      |> Enum.reduce(0, fn pattern, acc ->
        case persist_pattern(pattern) do
          {:ok, _} -> acc + 1
          {:error, _} -> acc
        end
      end)

    new_state = load_patterns(%__MODULE__{})

    {:reply, {:ok, count}, new_state}
  end

  defp load_patterns(state) do
    patterns =
      try do
        from(p in Pattern)
        |> Repo.all()
        |> Map.new(fn p -> {p.id, p} end)
      rescue
        _ ->
          # If DB not available, load seed patterns
          @seed_patterns
          |> Enum.map(& &1.pattern())
          |> Map.new(fn p -> {p.id, p} end)
      end

    %{state | patterns: patterns, loaded_at: DateTime.utc_now()}
  end

  defp persist_pattern(pattern) do
    # Check if exists
    case Repo.get(Pattern, pattern.id) do
      nil ->
        changeset = Pattern.changeset(%Pattern{}, Map.from_struct(pattern))
        Repo.insert(changeset)

      existing ->
        changeset = Pattern.changeset(existing, Map.from_struct(pattern))
        Repo.update(changeset)
    end
  end

  defp matches_tags?(_pattern, []), do: true

  defp matches_tags?(pattern, tags) do
    pattern_tags = pattern.tags || []
    Enum.any?(tags, &(&1 in pattern_tags))
  end
end
