defmodule Mimo.Awakening.Stats do
  @moduledoc """
  SPEC-040: Awakening Stats Schema

  Tracks XP, power levels, and achievements for the Mimo Awakening Protocol.
  This enables progressive enhancement of any AI connecting via MCP.

  ## Power Levels (v1.2 - Recalibrated)

  | Level | Name        | Icon | XP Required |
  |-------|-------------|------|-------------|
  | 1     | Base        | 🌑   | 0           |
  | 2     | Enhanced    | 🌓   | 1,000       |
  | 3     | Awakened    | 🌕   | 10,000      |
  | 4     | Ascended    | ⭐   | 50,000      |
  | 5     | Ultra       | 🌌   | 200,000     |
  | 6     | Transcendent| 💎   | 1,000,000   |

  See `Mimo.Awakening.PowerCalculator` for the authoritative XP thresholds.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  require Logger

  alias Mimo.Awakening.PowerCalculator
  alias Mimo.Repo

  @type t :: %__MODULE__{}

  schema "awakening_stats" do
    field(:user_id, :string)
    field(:project_id, :string)

    # XP Tracking
    field(:total_xp, :integer, default: 0)
    field(:current_level, :integer, default: 1)

    # Activity Metrics
    field(:total_sessions, :integer, default: 0)
    field(:total_memories, :integer, default: 0)
    field(:total_relationships, :integer, default: 0)
    field(:total_procedures, :integer, default: 0)
    field(:total_tool_calls, :integer, default: 0)

    # Timestamps
    field(:first_awakening, :utc_datetime)
    field(:last_session, :utc_datetime)

    # Achievement Flags
    field(:achievements, {:array, :string}, default: [])

    timestamps()
  end

  @doc """
  Changeset for stats updates.
  """
  def changeset(stats, attrs) do
    stats
    |> cast(attrs, [
      :user_id,
      :project_id,
      :total_xp,
      :current_level,
      :total_sessions,
      :total_memories,
      :total_relationships,
      :total_procedures,
      :total_tool_calls,
      :first_awakening,
      :last_session,
      :achievements
    ])
    |> validate_number(:total_xp, greater_than_or_equal_to: 0)
    |> validate_number(:current_level, greater_than_or_equal_to: 1, less_than_or_equal_to: 6)
    |> unique_constraint([:user_id, :project_id])
  end

  @doc """
  Get or create stats for a user/project combination.
  Returns the stats record, creating one if it doesn't exist.

  When creating a new record, automatically bootstraps XP from existing data.
  """
  @spec get_or_create(String.t() | nil, String.t() | nil) :: {:ok, t()} | {:error, term()}
  def get_or_create(user_id \\ nil, project_id \\ nil) do
    case get_stats(user_id, project_id) do
      nil -> create_and_bootstrap(user_id, project_id)
      stats -> ensure_level_correct(stats)
    end
  end

  defp create_and_bootstrap(user_id, project_id) do
    case create_stats(user_id, project_id) do
      {:ok, stats} -> bootstrap_from_existing(stats)
      error -> error
    end
  end

  defp ensure_level_correct(stats) do
    correct_level = PowerCalculator.calculate_level(stats.total_xp)

    if stats.current_level != correct_level do
      correct_level_drift(stats, correct_level)
    else
      {:ok, stats}
    end
  end

  defp correct_level_drift(stats, correct_level) do
    Logger.warning("""
    [Awakening] Level drift detected! Correcting...
    - Stored level: #{stats.current_level}
    - Correct level (from #{stats.total_xp} XP): #{correct_level}
    """)

    case stats |> changeset(%{current_level: correct_level}) |> Repo.update() do
      {:ok, corrected_stats} -> {:ok, corrected_stats}
      {:error, _} -> {:ok, stats}
    end
  end

  @doc """
  Get stats for a user/project combination.
  """
  @spec get_stats(String.t() | nil, String.t() | nil) :: t() | nil
  def get_stats(user_id \\ nil, project_id \\ nil) do
    query = from(s in __MODULE__, limit: 1)

    query =
      if user_id do
        from(s in query, where: s.user_id == ^user_id)
      else
        from(s in query, where: is_nil(s.user_id))
      end

    query =
      if project_id do
        from(s in query, where: s.project_id == ^project_id)
      else
        from(s in query, where: is_nil(s.project_id))
      end

    Repo.one(query)
  end

  @doc """
  Create a new stats record.
  """
  @spec create_stats(String.t() | nil, String.t() | nil) :: {:ok, t()} | {:error, term()}
  def create_stats(user_id \\ nil, project_id \\ nil) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %__MODULE__{}
    |> changeset(%{
      user_id: user_id,
      project_id: project_id,
      first_awakening: now,
      last_session: now
    })
    |> Repo.insert()
  end

  @doc """
  Award XP and update stats atomically.

  ## XP Values by Event Type

  | Event              | XP  |
  |--------------------|-----|
  | memory_stored      | 5   |
  | memory_accessed    | 1   |
  | knowledge_taught   | 10  |
  | graph_query        | 2   |
  | procedure_created  | 50  |
  | procedure_executed | 5   |
  | session_completed  | 20  |
  | tool_call          | 1   |
  | error_solved       | 25  |
  """
  @spec award_xp(atom(), map()) :: {:ok, t()} | {:error, term()}
  def award_xp(event_type, opts \\ %{}) do
    user_id = Map.get(opts, :user_id)
    project_id = Map.get(opts, :project_id)

    xp_value = xp_for_event(event_type)

    case get_or_create(user_id, project_id) do
      {:ok, stats} ->
        new_xp = stats.total_xp + xp_value
        new_level = PowerCalculator.calculate_level(new_xp)

        # Build updates with INCREMENTED counter values (not replacement!)
        updates = %{
          total_xp: new_xp,
          current_level: new_level,
          last_session: DateTime.utc_now() |> DateTime.truncate(:second)
        }

        # Add counter increments based on event type
        updates = increment_counter_for_event(updates, event_type, stats)

        stats
        |> changeset(updates)
        |> Repo.update()

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Increment session count.
  """
  @spec increment_sessions(String.t() | nil, String.t() | nil) :: {:ok, t()} | {:error, term()}
  def increment_sessions(user_id \\ nil, project_id \\ nil) do
    case get_or_create(user_id, project_id) do
      {:ok, stats} ->
        new_sessions = stats.total_sessions + 1
        new_xp = stats.total_xp + xp_for_event(:session_completed)
        new_level = PowerCalculator.calculate_level(new_xp)

        stats
        |> changeset(%{
          total_sessions: new_sessions,
          total_xp: new_xp,
          current_level: new_level,
          last_session: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.update()

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Add an achievement if not already unlocked.
  """
  @spec add_achievement(t(), String.t()) :: {:ok, t()} | {:error, term()}
  def add_achievement(stats, achievement_id) do
    if achievement_id in stats.achievements do
      {:ok, stats}
    else
      new_achievements = [achievement_id | stats.achievements]

      stats
      |> changeset(%{achievements: new_achievements})
      |> Repo.update()
    end
  end

  @doc """
  Calculate active days since first awakening.
  """
  @spec active_days(t()) :: non_neg_integer()
  def active_days(%__MODULE__{first_awakening: nil}), do: 0

  def active_days(%__MODULE__{first_awakening: first}) do
    now = DateTime.utc_now()
    DateTime.diff(now, first, :day)
  end

  defp xp_for_event(:memory_stored), do: 5
  defp xp_for_event(:memory_accessed), do: 1
  defp xp_for_event(:knowledge_taught), do: 10
  defp xp_for_event(:graph_query), do: 2
  defp xp_for_event(:graph_link), do: 3
  defp xp_for_event(:procedure_created), do: 50
  defp xp_for_event(:procedure_executed), do: 5
  defp xp_for_event(:session_completed), do: 20
  defp xp_for_event(:tool_call), do: 1
  defp xp_for_event(:error_solved), do: 25
  defp xp_for_event(:reasoning_step), do: 2
  defp xp_for_event(:insight_generated), do: 5
  defp xp_for_event(_), do: 1

  # Increment the appropriate counter based on event type
  # These use the CURRENT stats values + 1, not replacement
  defp increment_counter_for_event(updates, :memory_stored, stats) do
    Map.put(updates, :total_memories, (stats.total_memories || 0) + 1)
  end

  defp increment_counter_for_event(updates, :knowledge_taught, stats) do
    Map.put(updates, :total_relationships, (stats.total_relationships || 0) + 1)
  end

  defp increment_counter_for_event(updates, :procedure_created, stats) do
    Map.put(updates, :total_procedures, (stats.total_procedures || 0) + 1)
  end

  defp increment_counter_for_event(updates, :tool_call, stats) do
    Map.put(updates, :total_tool_calls, (stats.total_tool_calls || 0) + 1)
  end

  defp increment_counter_for_event(updates, _event_type, _stats) do
    updates
  end

  @doc """
  Increment a specific counter (for external tracking).
  Used by Awakening.Hooks for detailed metric tracking.
  """
  @spec increment_counter(atom(), map()) :: :ok
  def increment_counter(counter_type, _metadata \\ %{}) do
    # Logs counter increments for debugging. Detailed metrics can be
    # stored in a separate table if persistence is needed.
    Logger.debug("[Awakening.Stats] Counter increment: #{counter_type}")
    :ok
  end

  @doc """
  Sync XP with existing data in the system.

  Call this to recalculate XP based on current data counts.
  Useful for:
  - First-time setup after migration
  - Periodic sync to ensure accuracy
  - After bulk imports

  ## XP Calculation
  - Memories: 5 XP each
  - Knowledge relationships: 10 XP each  
  - Procedures: 50 XP each
  """
  @spec sync_from_existing(String.t() | nil, String.t() | nil) :: {:ok, t()} | {:error, term()}
  def sync_from_existing(user_id \\ nil, project_id \\ nil) do
    case get_or_create(user_id, project_id) do
      {:ok, stats} ->
        bootstrap_from_existing(stats)

      error ->
        error
    end
  end

  @doc """
  Bootstrap XP from existing data in the system.

  Calculates XP based on:
  - Existing memories (5 XP each)
  - Existing knowledge graph relationships (10 XP each)
  - Existing procedures (50 XP each)

  This should be called once when awakening_stats is first created
  to give credit for pre-existing work.
  """
  @spec bootstrap_from_existing(t()) :: {:ok, t()} | {:error, term()}
  def bootstrap_from_existing(stats) do
    # Count existing data
    memory_count = count_existing_memories()
    relationship_count = count_existing_relationships()
    procedure_count = count_existing_procedures()

    # Calculate XP
    memory_xp = memory_count * 5
    relationship_xp = relationship_count * 10
    procedure_xp = procedure_count * 50
    total_xp = memory_xp + relationship_xp + procedure_xp

    # Calculate level from XP
    level = PowerCalculator.calculate_level(total_xp)

    Logger.info("""
    [Awakening] Bootstrapping from existing data:
      Memories: #{memory_count} (#{memory_xp} XP)
      Relationships: #{relationship_count} (#{relationship_xp} XP)
      Procedures: #{procedure_count} (#{procedure_xp} XP)
      Total XP: #{total_xp}
      Level: #{level}
    """)

    # Update stats
    stats
    |> changeset(%{
      total_xp: total_xp,
      current_level: level,
      total_memories: memory_count,
      total_relationships: relationship_count,
      total_procedures: procedure_count
    })
    |> Repo.update()
  end

  defp count_existing_memories do
    Repo.aggregate(Mimo.Brain.Engram, :count, :id) || 0
  rescue
    _ -> 0
  end

  defp count_existing_relationships do
    Repo.aggregate(Mimo.SemanticStore.Triple, :count, :id) || 0
  rescue
    _ -> 0
  end

  defp count_existing_procedures do
    # Count procedure files in the procedures directory
    procedures_dir = Application.get_env(:mimo_mcp, :procedures_dir, "priv/procedures")

    case File.ls(procedures_dir) do
      {:ok, files} ->
        files |> Enum.filter(&String.ends_with?(&1, ".json")) |> length()

      {:error, _} ->
        0
    end
  end
end
