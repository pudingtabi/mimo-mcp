defmodule Mimo.Workflow.Execution do
  @moduledoc """
  SPEC-053: Workflow Execution Schema

  Tracks workflow execution history with status, metrics, and results.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type status :: :pending | :running | :paused | :completed | :failed | :rollback

  @type t :: %__MODULE__{
          id: String.t(),
          pattern_id: String.t() | nil,
          session_id: String.t(),
          bindings: map() | nil,
          status: String.t(),
          result: map() | nil,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          metrics: map(),
          error: String.t() | nil
        }

  @primary_key {:id, :string, autogenerate: false}
  schema "workflow_executions" do
    field :pattern_id, :string
    field :session_id, :string
    field :bindings, :map
    field :status, :string, default: "pending"
    field :result, :map
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :metrics, :map, default: %{}
    field :error, :string
  end

  @valid_statuses ~w(pending running paused completed failed rollback)

  @required_fields [:id, :session_id, :status]
  @optional_fields [
    :pattern_id,
    :bindings,
    :result,
    :started_at,
    :completed_at,
    :metrics,
    :error
  ]

  @doc """
  Creates a changeset for a workflow execution.
  """
  def changeset(execution, attrs) do
    execution
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @valid_statuses)
  end

  @doc """
  Creates a new execution record.
  """
  def new(attrs) do
    id = attrs[:id] || generate_id()

    %__MODULE__{}
    |> changeset(
      attrs
      |> Map.put(:id, id)
      |> Map.put_new(:status, "pending")
      |> Map.put_new(:started_at, DateTime.utc_now())
    )
  end

  @doc """
  Marks execution as running.
  """
  def start(execution) do
    changeset(execution, %{
      status: "running",
      started_at: DateTime.utc_now()
    })
  end

  @doc """
  Marks execution as completed with result.
  """
  def complete(execution, result, metrics \\ %{}) do
    changeset(execution, %{
      status: "completed",
      result: result,
      completed_at: DateTime.utc_now(),
      metrics: Map.merge(execution.metrics || %{}, metrics)
    })
  end

  @doc """
  Marks execution as failed with error.
  """
  def fail(execution, error, metrics \\ %{}) do
    changeset(execution, %{
      status: "failed",
      error: error_to_string(error),
      completed_at: DateTime.utc_now(),
      metrics: Map.merge(execution.metrics || %{}, metrics)
    })
  end

  # Private functions

  defp generate_id do
    timestamp = System.os_time(:millisecond)
    random = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    "exec_#{timestamp}_#{random}"
  end

  defp error_to_string(error) when is_binary(error), do: error
  defp error_to_string(error), do: inspect(error)
end
