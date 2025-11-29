defmodule Mimo.Brain.Thread do
  @moduledoc """
  Thread represents an AI session connected to Mimo.

  A thread is created when an AI client connects and persists even after
  the AI disconnects. This enables:
  - Session-scoped memory (memories belong to a session context)
  - Activity tracking (what happened during a session)
  - Cross-session learning (patterns across multiple sessions)

  Thread Status:
  - active: Currently connected and interacting
  - idle: Connected but no recent activity (5+ minutes)
  - disconnected: Client disconnected but thread persists
  - archived: Old thread archived for reference
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Mimo.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(active idle disconnected archived)

  schema "threads" do
    field :name, :string
    field :client_info, :map, default: %{}
    field :started_at, :utc_datetime_usec
    field :last_active_at, :utc_datetime_usec
    field :status, :string, default: "active"
    field :metadata, :map, default: %{}

    has_many :interactions, Mimo.Brain.Interaction
    has_many :engrams, Mimo.Brain.Engram

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Creates a changeset for a new thread.
  """
  def changeset(thread, attrs) do
    thread
    |> cast(attrs, [:name, :client_info, :started_at, :last_active_at, :status, :metadata])
    |> validate_required([:status])
    |> validate_inclusion(:status, @statuses)
    |> set_timestamps()
  end

  defp set_timestamps(changeset) do
    now = DateTime.utc_now()
    changeset
    |> put_default(:started_at, now)
    |> put_default(:last_active_at, now)
  end

  defp put_default(changeset, field, value) do
    case get_field(changeset, field) do
      nil -> put_change(changeset, field, value)
      _ -> changeset
    end
  end

  # ─────────────────────────────────────────────────────────────
  # Public API
  # ─────────────────────────────────────────────────────────────

  @doc """
  Creates a new thread for an AI session.

  ## Options
  - `:name` - Optional human-readable name for the thread
  - `:client_info` - Map of client information (e.g., %{client: "vscode", version: "1.0"})
  """
  def create(opts \\ []) do
    attrs = %{
      name: Keyword.get(opts, :name),
      client_info: Keyword.get(opts, :client_info, %{}),
      status: "active",
      metadata: Keyword.get(opts, :metadata, %{})
    }

    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets a thread by ID.
  """
  def get(id) when is_binary(id) do
    Repo.get(__MODULE__, id)
  end

  def get(_), do: nil

  @doc """
  Gets or creates the current active thread.

  If there's an active thread within the last 30 minutes, returns it.
  Otherwise, creates a new thread.
  """
  def get_or_create_current(opts \\ []) do
    thirty_minutes_ago = DateTime.add(DateTime.utc_now(), -30, :minute)

    query = from t in __MODULE__,
      where: t.status in ["active", "idle"],
      where: t.last_active_at > ^thirty_minutes_ago,
      order_by: [desc: t.last_active_at],
      limit: 1

    case Repo.one(query) do
      nil -> create(opts)
      thread -> touch(thread)
    end
  end

  @doc """
  Updates the last_active_at timestamp for a thread.
  """
  def touch(%__MODULE__{} = thread) do
    thread
    |> changeset(%{last_active_at: DateTime.utc_now(), status: "active"})
    |> Repo.update()
  end

  def touch(id) when is_binary(id) do
    case get(id) do
      nil -> {:error, :not_found}
      thread -> touch(thread)
    end
  end

  @doc """
  Marks a thread as disconnected.
  """
  def disconnect(%__MODULE__{} = thread) do
    thread
    |> changeset(%{status: "disconnected"})
    |> Repo.update()
  end

  def disconnect(id) when is_binary(id) do
    case get(id) do
      nil -> {:error, :not_found}
      thread -> disconnect(thread)
    end
  end

  @doc """
  Lists all threads, optionally filtered by status.
  """
  def list(opts \\ []) do
    query = from t in __MODULE__, order_by: [desc: t.last_active_at]

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status when is_binary(status) -> where(query, [t], t.status == ^status)
        statuses when is_list(statuses) -> where(query, [t], t.status in ^statuses)
      end

    query =
      case Keyword.get(opts, :limit) do
        nil -> query
        limit -> limit(query, ^limit)
      end

    Repo.all(query)
  end

  @doc """
  Archives old threads that haven't been active for the specified duration.
  Default is 7 days.
  """
  def archive_old(days \\ 7) do
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)

    from(t in __MODULE__,
      where: t.status in ["idle", "disconnected"],
      where: t.last_active_at < ^cutoff
    )
    |> Repo.update_all(set: [status: "archived", updated_at: DateTime.utc_now()])
  end

  @doc """
  Updates idle threads to disconnected after 30 minutes of inactivity.
  """
  def cleanup_idle do
    thirty_minutes_ago = DateTime.add(DateTime.utc_now(), -30, :minute)

    from(t in __MODULE__,
      where: t.status == "active",
      where: t.last_active_at < ^thirty_minutes_ago
    )
    |> Repo.update_all(set: [status: "idle", updated_at: DateTime.utc_now()])
  end

  @doc """
  Gets statistics for threads.
  """
  def stats do
    query = from t in __MODULE__,
      group_by: t.status,
      select: {t.status, count(t.id)}

    stats_map =
      query
      |> Repo.all()
      |> Map.new()

    %{
      active: Map.get(stats_map, "active", 0),
      idle: Map.get(stats_map, "idle", 0),
      disconnected: Map.get(stats_map, "disconnected", 0),
      archived: Map.get(stats_map, "archived", 0),
      total: Repo.aggregate(__MODULE__, :count)
    }
  end
end
