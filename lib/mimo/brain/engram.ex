defmodule Mimo.Brain.Engram do
  @moduledoc """
  Universal Engram - the polymorphic memory unit.
  Based on CoALA framework principles.

  Note: Embedding and metadata are stored as JSON text in SQLite.

  ## Decay Fields (SPEC-003)

  The following fields support memory decay/forgetting:
  - `access_count` - Number of times this memory has been accessed
  - `last_accessed_at` - Timestamp of last access
  - `decay_rate` - Rate at which memory decays (default 0.1)
  - `protected` - Whether this memory is protected from forgetting
  """
  use Ecto.Schema
  import Ecto.Changeset

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
    field(:decay_rate, :float, default: 0.1)
    field(:protected, :boolean, default: false)

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
      :protected
    ])
    |> validate_required([:content, :category])
    |> validate_inclusion(:category, @valid_categories)
    |> validate_number(:importance, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:decay_rate, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
  end
end
