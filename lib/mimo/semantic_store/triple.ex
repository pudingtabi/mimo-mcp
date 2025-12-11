defmodule Mimo.SemanticStore.Triple do
  @moduledoc """
  Ecto schema for semantic triples (Subject-Predicate-Object).

  Triples represent exact relationships between entities, enabling
  deterministic graph queries and multi-hop reasoning.

  ## Examples

      # "Alice reports to Bob"
      %Triple{
        subject_id: "alice",
        subject_type: "person",
        predicate: "reports_to",
        object_id: "bob",
        object_type: "person",
        confidence: 1.0
      }
      
      # "Engineering belongs to TechCorp"
      %Triple{
        subject_id: "engineering",
        subject_type: "department",
        predicate: "belongs_to",
        object_id: "techcorp",
        object_type: "company",
        confidence: 1.0
      }
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @derive {Jason.Encoder,
           only: [
             :id,
             :subject_id,
             :subject_type,
             :predicate,
             :object_id,
             :object_type,
             :confidence,
             :source,
             :context,
             :graph_id,
             :inferred_by_rule_id,
             :inserted_at
           ]}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "semantic_triples" do
    field(:subject_hash, :string, redact: true)
    field(:subject_id, :string)
    field(:subject_type, :string)
    field(:predicate, :string)
    field(:object_id, :string)
    field(:object_type, :string)
    field(:confidence, :float, default: 1.0)
    field(:source, :string)
    field(:ttl, :integer)
    field(:metadata, Mimo.Brain.EctoJsonMap, default: %{})

    # Enhanced Semantic Store Fields (v2.3)
    field(:context, :map, default: %{})
    field(:graph_id, :string, default: "global")
    field(:expires_at, :utc_datetime)

    # Neuro-symbolic linkage
    field(:inferred_by_rule_id, :binary_id)

    timestamps(type: :naive_datetime_usec)
  end

  @required_fields [:subject_id, :subject_type, :predicate, :object_id, :object_type]
  @optional_fields [
    :confidence,
    :source,
    :ttl,
    :metadata,
    :context,
    :graph_id,
    :expires_at,
    :inferred_by_rule_id
  ]

  @doc """
  Creates a changeset for a triple.

  Automatically computes the subject_hash for indexing.
  """
  def changeset(triple, attrs) do
    triple
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:confidence,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
    |> validate_number(:ttl, greater_than: 0)
    |> compute_subject_hash()
    |> unique_constraint([:subject_hash, :predicate, :object_id, :object_type],
      name: :semantic_unique_triple_index
    )
  end

  defp compute_subject_hash(changeset) do
    case {get_field(changeset, :subject_id), get_field(changeset, :subject_type)} do
      {id, type} when is_binary(id) and is_binary(type) ->
        put_change(changeset, :subject_hash, hash_entity(id, type))

      _ ->
        changeset
    end
  end

  @doc """
  Computes a deterministic hash for entity indexing.

  The hash is used for efficient lookups without needing
  to query on both subject_id and subject_type.
  """
  @spec hash_entity(String.t(), String.t()) :: String.t()
  def hash_entity(id, type) when is_binary(id) and is_binary(type) do
    :crypto.hash(:md5, "#{id}:#{type}")
    |> Base.encode16(case: :lower)
  end

  @doc """
  Checks if a triple has expired based on its TTL.
  """
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{ttl: nil}), do: false

  def expired?(%__MODULE__{ttl: ttl, inserted_at: inserted_at}) do
    expires_at = NaiveDateTime.add(inserted_at, ttl, :second)
    NaiveDateTime.compare(NaiveDateTime.utc_now(), expires_at) == :gt
  end
end
