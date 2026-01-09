defmodule Mimo.Brain.Emergence.Catalog do
  @moduledoc """
  SPEC-044: Catalog for promoted emergent capabilities.

  Tracks patterns that have been promoted to explicit capabilities,
  providing lookup and management for emergent skills.

  ## Architecture

  - Uses ETS for fast in-memory lookup
  - Persists to database for durability
  - Integrates with skill system for capability exposure

  ## Catalog Entry Structure

  Each promoted pattern is stored with:
  - Original pattern metadata
  - Promotion artifact (procedure, knowledge, etc.)
  - Promotion timestamp
  - Usage metrics post-promotion
  """

  use GenServer
  require Logger

  alias Mimo.Brain.Emergence.Pattern
  alias Mimo.Repo

  @catalog_table :emergence_catalog

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register a promoted pattern in the catalog.

  ## Parameters

  - `pattern` - The Pattern struct that was promoted
  - `artifact` - The created artifact (procedure, knowledge triple, etc.)

  ## Returns

  - `{:ok, catalog_entry}` on success
  - `{:error, reason}` on failure
  """
  @spec register_promoted(Pattern.t(), map()) :: {:ok, map()} | {:error, term()}
  def register_promoted(%Pattern{} = pattern, artifact) when is_map(artifact) do
    GenServer.call(__MODULE__, {:register, pattern, artifact})
  end

  @doc """
  Look up a promoted capability by pattern ID.
  """
  @spec get_promoted(integer()) :: {:ok, map()} | {:error, :not_found}
  def get_promoted(pattern_id) when is_integer(pattern_id) do
    case :ets.lookup(@catalog_table, pattern_id) do
      [{^pattern_id, entry}] -> {:ok, entry}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  List all promoted capabilities.
  """
  @spec list_promoted() :: [map()]
  def list_promoted do
    @catalog_table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, entry} -> entry end)
  end

  @doc """
  List promoted capabilities by type.
  """
  @spec list_by_type(atom()) :: [map()]
  def list_by_type(type) when type in [:workflow, :inference, :heuristic, :skill] do
    list_promoted()
    |> Enum.filter(fn entry -> entry.pattern_type == type end)
  end

  @doc """
  Get catalog statistics.
  """
  @spec stats() :: map()
  def stats do
    all = list_promoted()

    %{
      total_promoted: length(all),
      by_type: Enum.frequencies_by(all, & &1.pattern_type),
      recent_promotions:
        all
        |> Enum.sort_by(& &1.promoted_at, {:desc, DateTime})
        |> Enum.take(5)
    }
  end

  @doc """
  Initialize the catalog (no-op, GenServer is started via supervision).
  """
  @spec init() :: :ok
  def init do
    :ok
  end

  @doc """
  Count total promoted capabilities.
  """
  @spec count() :: non_neg_integer()
  def count do
    :ets.info(@catalog_table, :size) || 0
  end

  @doc """
  List emerged capabilities with options.
  """
  @spec list_emerged_capabilities(keyword()) :: [map()]
  def list_emerged_capabilities(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    list_promoted()
    |> Enum.take(limit)
  end

  @doc """
  Generate a capability report.
  """
  @spec capability_report() :: map()
  def capability_report do
    all = list_promoted()

    %{
      total: length(all),
      by_type: Enum.frequencies_by(all, & &1.pattern_type),
      by_usage: group_by_usage(all),
      most_used: all |> Enum.sort_by(& &1.usage_count, :desc) |> Enum.take(10),
      recently_promoted: all |> Enum.sort_by(& &1.promoted_at, {:desc, DateTime}) |> Enum.take(5)
    }
  end

  @doc """
  Search capabilities by query.
  """
  @spec search(String.t(), keyword()) :: [map()]
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    query_lower = String.downcase(query)

    list_promoted()
    |> Enum.filter(fn entry ->
      desc = entry.description || ""
      String.contains?(String.downcase(desc), query_lower)
    end)
    |> Enum.take(limit)
  end

  @doc """
  Suggest capabilities based on context.
  """
  @spec suggest_capabilities(map()) :: [map()]
  def suggest_capabilities(context) when is_map(context) do
    # Get recent and frequently used capabilities as suggestions
    all = list_promoted()

    # Prioritize by usage and recency
    all
    |> Enum.sort_by(fn entry ->
      {-entry.usage_count, entry.promoted_at}
    end)
    |> Enum.take(5)
  end

  defp group_by_usage(capabilities) do
    Enum.reduce(capabilities, %{high: 0, medium: 0, low: 0}, fn entry, acc ->
      cond do
        entry.usage_count >= 10 -> Map.update!(acc, :high, &(&1 + 1))
        entry.usage_count >= 3 -> Map.update!(acc, :medium, &(&1 + 1))
        true -> Map.update!(acc, :low, &(&1 + 1))
      end
    end)
  end

  @doc """
  Record usage of a promoted capability.
  """
  @spec record_usage(integer()) :: :ok | {:error, :not_found}
  def record_usage(pattern_id) do
    GenServer.call(__MODULE__, {:record_usage, pattern_id})
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    Mimo.EtsSafe.ensure_table(@catalog_table, [:named_table, :set, :public, read_concurrency: true])

    # Load existing promoted patterns from database
    load_promoted_patterns()

    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, pattern, artifact}, _from, state) do
    entry = %{
      pattern_id: pattern.id,
      pattern_type: pattern.type,
      description: pattern.description,
      artifact: artifact,
      promoted_at: DateTime.utc_now(),
      usage_count: 0,
      last_used_at: nil
    }

    :ets.insert(@catalog_table, {pattern.id, entry})

    Logger.info("📚 Registered promoted pattern ##{pattern.id} (#{pattern.type})")

    {:reply, {:ok, entry}, state}
  end

  @impl true
  def handle_call({:record_usage, pattern_id}, _from, state) do
    case :ets.lookup(@catalog_table, pattern_id) do
      [{^pattern_id, entry}] ->
        updated = %{entry | usage_count: entry.usage_count + 1, last_used_at: DateTime.utc_now()}
        :ets.insert(@catalog_table, {pattern_id, updated})
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  # Private helpers

  defp load_promoted_patterns do
    try do
      import Ecto.Query

      patterns =
        Repo.all(
          from(p in Pattern,
            where: p.status == :promoted,
            order_by: [desc: p.updated_at]
          )
        )

      Enum.each(patterns, fn pattern ->
        # evolution is a list of history entries, not a map
        # promotion_artifact and usage_count should come from metadata
        metadata = pattern.metadata || %{}

        entry = %{
          pattern_id: pattern.id,
          pattern_type: pattern.type,
          description: pattern.description,
          artifact: Map.get(metadata, "promotion_artifact"),
          promoted_at: pattern.updated_at,
          usage_count: Map.get(metadata, "post_promotion_usage", 0),
          last_used_at: Map.get(metadata, "last_used_at"),
          occurrences: pattern.occurrences,
          success_rate: pattern.success_rate
        }

        :ets.insert(@catalog_table, {pattern.id, entry})
      end)

      Logger.info("📚 Loaded #{length(patterns)} promoted patterns into catalog")
    rescue
      e ->
        Logger.warning("Could not load promoted patterns: #{inspect(e)}")
    end
  end
end
