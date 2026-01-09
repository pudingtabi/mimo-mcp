defmodule Mimo.ProceduralStore.Procedure do
  @moduledoc """
  Ecto schema for procedural registry entries.

  Procedures are deterministic state machines that execute
  critical tasks without LLM involvement.
  """
  alias Validator
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "procedural_registry" do
    field(:name, :string)
    field(:version, :string)
    field(:description, :string)
    field(:definition, Mimo.Brain.EctoJsonMap)
    field(:hash, :string)
    field(:active, :boolean, default: true)
    field(:rollback_procedure, :string)
    field(:timeout_ms, :integer, default: 300_000)
    field(:max_retries, :integer, default: 3)
    field(:metadata, Mimo.Brain.EctoJsonMap, default: %{})

    timestamps()
  end

  @required_fields [:name, :version, :definition]
  @optional_fields [
    :description,
    :active,
    :rollback_procedure,
    :timeout_ms,
    :max_retries,
    :metadata
  ]

  @doc """
  Creates a changeset for a procedure.

  Automatically computes the definition hash for integrity verification.
  """
  def changeset(procedure, attrs) do
    procedure
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_format(:version, ~r/^\d+\.\d+$/, message: "must be in format X.Y")
    |> validate_number(:timeout_ms, greater_than: 0)
    |> validate_number(:max_retries, greater_than_or_equal_to: 0)
    |> validate_definition()
    |> compute_hash()
    |> unique_constraint([:name, :version])
  end

  defp validate_definition(changeset) do
    case get_field(changeset, :definition) do
      nil ->
        changeset

      definition ->
        case Mimo.ProceduralStore.Validator.validate(definition) do
          :ok ->
            changeset

          {:error, errors} ->
            add_error(changeset, :definition, "invalid: #{inspect(errors)}")
        end
    end
  end

  defp compute_hash(changeset) do
    case get_field(changeset, :definition) do
      nil ->
        changeset

      definition ->
        hash =
          definition
          |> Jason.encode!()
          |> then(&:crypto.hash(:sha256, &1))
          |> Base.encode16(case: :lower)

        put_change(changeset, :hash, hash)
    end
  end
end

defmodule Mimo.ProceduralStore.Execution do
  @moduledoc """
  Ecto schema for procedure execution records.

  Tracks execution history for audit, debugging, and analytics.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending running completed failed rolled_back interrupted)

  schema "procedure_executions" do
    field(:procedure_name, :string)
    field(:procedure_version, :string)
    field(:status, :string, default: "pending")
    field(:current_state, :string)
    field(:context, Mimo.Brain.EctoJsonMap, default: %{})
    field(:history, Mimo.Brain.EctoJsonList, default: [])
    field(:error, :string)
    field(:started_at, :naive_datetime_usec)
    field(:completed_at, :naive_datetime_usec)
    field(:duration_ms, :integer)

    belongs_to(:procedure, Mimo.ProceduralStore.Procedure)

    timestamps()
  end

  def changeset(execution, attrs) do
    execution
    |> cast(attrs, [
      :procedure_id,
      :procedure_name,
      :procedure_version,
      :status,
      :current_state,
      :context,
      :history,
      :error,
      :started_at,
      :completed_at,
      :duration_ms
    ])
    |> validate_required([:procedure_name, :procedure_version, :status])
    |> validate_inclusion(:status, @statuses)
  end

  @doc """
  Adds a state transition to the execution history.
  """
  def add_history_entry(execution, from_state, to_state, event, metadata \\ %{}) do
    entry = %{
      from: from_state,
      to: to_state,
      event: event,
      timestamp: NaiveDateTime.utc_now() |> NaiveDateTime.to_iso8601(),
      metadata: metadata
    }

    new_history = execution.history ++ [entry]

    execution
    |> changeset(%{history: new_history, current_state: to_state})
  end
end
