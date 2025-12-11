defmodule Mimo.NeuroSymbolic.CrossModalityLink do
  @moduledoc """
  Ecto schema for cross modality links (code symbol <-> memory <-> knowledge node).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Jason.Encoder, only: [:id, :source_type, :source_id, :target_type, :target_id, :link_type, :confidence, :discovered_by, :inserted_at]}

  schema "cross_modality_links" do
    field :source_type, :string
    field :source_id, :string
    field :target_type, :string
    field :target_id, :string
    field :link_type, :string
    field :confidence, :float, default: 0.5
    field :discovered_by, :string

    timestamps(type: :naive_datetime_usec)
  end

  @required_fields [:source_type, :source_id, :target_type, :target_id, :link_type, :discovered_by]
  @optional_fields [:confidence]

  def changeset(link, attrs) do
    link
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:confidence,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
  end
end
