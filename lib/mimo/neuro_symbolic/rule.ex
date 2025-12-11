defmodule Mimo.NeuroSymbolic.Rule do
  @moduledoc """
  Ecto schema and changeset for neuro-symbolic rules.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Jason.Encoder, only: [:id, :premise, :conclusion, :confidence, :source, :validation_status, :usage_count, :inserted_at]}

  schema "neuro_symbolic_rules" do
    field :premise, :string
    field :conclusion, :string
    field :logical_form, :map, default: %{}
    field :confidence, :float, default: 0.5
    field :source, :string
    field :validation_status, :string, default: "pending"
    field :validation_evidence, :map, default: %{}
    field :usage_count, :integer, default: 0

    timestamps(type: :naive_datetime_usec)
  end

  @required_fields [:premise, :conclusion, :logical_form, :source]
  @optional_fields [:confidence, :validation_status, :validation_evidence, :usage_count]

  def changeset(rule, attrs) do
    rule
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:confidence,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
  end
end
