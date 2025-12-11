defmodule Mimo.Workflow.ToolLog do
  @moduledoc """
  SPEC-053: Tool Usage Log Schema

  Records individual tool calls for pattern extraction.
  Used by PatternExtractor to detect workflow sequences.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer(),
          session_id: String.t(),
          tool: String.t(),
          operation: String.t(),
          params: map() | nil,
          success: boolean() | nil,
          duration_ms: integer() | nil,
          token_usage: integer() | nil,
          context_snapshot: map() | nil,
          timestamp: DateTime.t()
        }

  schema "workflow_tool_logs" do
    field :session_id, :string
    field :tool, :string
    field :operation, :string
    field :params, :map
    field :success, :boolean
    field :duration_ms, :integer
    field :token_usage, :integer
    field :context_snapshot, :map
    field :timestamp, :utc_datetime_usec
  end

  @required_fields [:session_id, :tool, :operation, :timestamp]
  @optional_fields [:params, :success, :duration_ms, :token_usage, :context_snapshot]

  @doc """
  Creates a changeset for a tool log entry.
  """
  def changeset(log, attrs) do
    log
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end

  @doc """
  Creates a new tool log entry with current timestamp.
  """
  def new(attrs) do
    %__MODULE__{}
    |> changeset(Map.put_new(attrs, :timestamp, DateTime.utc_now()))
  end

  @doc """
  Logs a tool usage event to the database.
  """
  def log(attrs) when is_map(attrs) do
    attrs_with_timestamp = Map.put_new(attrs, :timestamp, DateTime.utc_now())

    %__MODULE__{}
    |> changeset(attrs_with_timestamp)
    |> Mimo.Repo.insert()
  end
end
