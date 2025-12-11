defmodule Mimo.NeuroSymbolic.GnnModel do
  @moduledoc """
  Ecto schema for storing GNN model metadata.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Jason.Encoder,
           only: [:id, :version, :trained_at, :embedding_dim, :accuracy, :path, :inserted_at]}

  schema "gnn_models" do
    field(:version, :integer)
    field(:trained_at, :utc_datetime)
    field(:embedding_dim, :integer)
    field(:accuracy, :float)
    field(:path, :string)

    timestamps(type: :naive_datetime_usec)
  end

  @required_fields [:version, :path]
  @optional_fields [:trained_at, :embedding_dim, :accuracy]

  def changeset(model, attrs) do
    model
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end
end
