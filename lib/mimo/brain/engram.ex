defmodule Mimo.Brain.Engram do
  @moduledoc """
  Universal Engram - the polymorphic memory unit.
  Based on CoALA framework principles.

  Note: Embedding and metadata are stored as JSON text in SQLite.
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

    timestamps()
  end

  @valid_categories ["fact", "action", "observation", "plan", "episode", "procedure"]

  def changeset(engram, attrs) do
    engram
    |> cast(attrs, [:content, :category, :importance, :embedding, :metadata])
    |> validate_required([:content, :category])
    |> validate_inclusion(:category, @valid_categories)
    |> validate_number(:importance, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
  end
end
