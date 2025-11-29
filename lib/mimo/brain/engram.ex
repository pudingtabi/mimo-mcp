defmodule Mimo.Brain.Engram do
  @moduledoc """
  Universal Engram - the polymorphic memory unit.
  Based on CoALA framework principles.

  Note: Embedding and metadata are stored as JSON text in SQLite.

  ## Decay Fields (SPEC-003)

  The following fields support memory decay/forgetting:
  - `access_count` - Number of times this memory has been accessed
  - `last_accessed_at` - Timestamp of last access
  - `decay_rate` - Rate at which memory decays (default 0.01 = 69 day half-life)
  - `protected` - Whether this memory is protected from forgetting

  ## Passive Memory Fields (SPEC-012)

  - `thread_id` - Links memory to the thread/session that created it
  - `original_importance` - The initial importance score (for tracking decay)

  ## Project Scoping & Auto-Tagging

  - `project_id` - Workspace/project identifier for memory isolation (default: "global")
  - `tags` - LLM auto-generated tags for categorization and filtering

  ## Importance-Decay Mapping (SPEC-012)

  | Importance | Decay Rate | Half-Life |
  |------------|------------|-----------|
  | 0.9-1.0    | 0.0001     | 693 days  |
  | 0.7-0.9    | 0.001      | 69 days   |
  | 0.5-0.7    | 0.005      | 14 days   |
  | 0.3-0.5    | 0.02       | 3.5 days  |
  | <0.3       | 0.1        | 17 hours  |
  """
  use Ecto.Schema
  import Ecto.Changeset

  # Engrams use integer IDs (existing database)
  # Threads/Interactions use binary_id (new tables)

  schema "engrams" do
    field(:content, :string)
    field(:category, :string)
    field(:importance, :float, default: 0.5)

    # These use custom Ecto type that serializes to JSON
    field(:embedding, Mimo.Brain.EctoJsonList, default: [])
    field(:metadata, Mimo.Brain.EctoJsonMap, default: %{})

    # Decay/forgetting fields (SPEC-003)
    field(:access_count, :integer, default: 0)
    field(:last_accessed_at, :naive_datetime_usec)
    field(:decay_rate, :float, default: 0.01)
    field(:protected, :boolean, default: false)

    # Passive Memory fields (SPEC-012)
    field(:original_importance, :float)
    field(:thread_id, :binary_id)

    # Project scoping & auto-tagging
    field(:project_id, :string, default: "global")
    field(:tags, Mimo.Brain.EctoJsonList, default: [])

    # Link to source interactions (join table with binary_id)
    # many_to_many :interactions, Mimo.Brain.Interaction, join_through: "interaction_engrams"

    timestamps()
  end

  @valid_categories [
    "fact",
    "action",
    "observation",
    "plan",
    "episode",
    "procedure",
    "entity_anchor"
  ]

  def changeset(engram, attrs) do
    engram
    |> cast(attrs, [
      :content,
      :category,
      :importance,
      :embedding,
      :metadata,
      :access_count,
      :last_accessed_at,
      :decay_rate,
      :protected,
      :original_importance,
      :thread_id,
      :project_id,
      :tags
    ])
    |> validate_required([:content, :category])
    |> validate_inclusion(:category, @valid_categories)
    |> validate_number(:importance, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:decay_rate, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> set_original_importance()
    |> set_decay_rate_from_importance()
  end

  # When creating, preserve original importance for decay tracking
  defp set_original_importance(changeset) do
    case {get_field(changeset, :original_importance), get_change(changeset, :importance)} do
      {nil, importance} when is_number(importance) ->
        put_change(changeset, :original_importance, importance)

      _ ->
        changeset
    end
  end

  # Set decay rate based on importance (SPEC-012 mapping)
  defp set_decay_rate_from_importance(changeset) do
    # Only set if decay_rate not explicitly provided
    case get_change(changeset, :decay_rate) do
      nil ->
        importance = get_field(changeset, :importance) || 0.5
        decay_rate = importance_to_decay_rate(importance)
        put_change(changeset, :decay_rate, decay_rate)

      _ ->
        changeset
    end
  end

  @doc """
  Maps importance score to decay rate.

  Higher importance = lower decay rate = longer memory retention.
  Based on exponential decay: half_life = ln(2) / decay_rate
  """
  # ~693 days half-life
  def importance_to_decay_rate(importance) when importance >= 0.9, do: 0.0001
  # ~69 days half-life
  def importance_to_decay_rate(importance) when importance >= 0.7, do: 0.001
  # ~14 days half-life
  def importance_to_decay_rate(importance) when importance >= 0.5, do: 0.005
  # ~3.5 days half-life
  def importance_to_decay_rate(importance) when importance >= 0.3, do: 0.02
  # ~17 hours half-life
  def importance_to_decay_rate(_importance), do: 0.1

  @doc """
  Calculates the current effective importance after decay.

  Uses exponential decay: importance(t) = original * e^(-decay_rate * days)
  """
  def effective_importance(%__MODULE__{} = engram) do
    original = engram.original_importance || engram.importance
    decay_rate = engram.decay_rate || 0.01

    days_since_creation =
      case engram.inserted_at do
        nil ->
          0

        inserted_at ->
          NaiveDateTime.diff(NaiveDateTime.utc_now(), inserted_at, :second) / 86400.0
      end

    original * :math.exp(-decay_rate * days_since_creation)
  end
end
