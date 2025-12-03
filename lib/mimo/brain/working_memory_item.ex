defmodule Mimo.Brain.WorkingMemoryItem do
  @moduledoc """
  Schema for working memory items.
  Uses embedded schema (NOT persisted to DB - lives in ETS).

  Working memory provides short-lived storage for active context
  during AI interactions, with automatic TTL expiration.
  """

  use Ecto.Schema
  import Ecto.Changeset

  # Enable JSON encoding, excluding the embedding field (too large)
  @derive {Jason.Encoder, except: [:embedding]}

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  embedded_schema do
    field(:content, :string)
    field(:category, :string, default: "fact")
    field(:context, :map, default: %{})
    field(:embedding, {:array, :float}, default: [])
    field(:importance, :float, default: 0.5)
    field(:tokens, :integer, default: 0)
    field(:session_id, :string)
    field(:source, :string, default: "unknown")
    field(:tool_name, :string)
    field(:created_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:accessed_at, :utc_datetime_usec)
    field(:consolidation_candidate, :boolean, default: false)
  end

  @doc """
  Creates a changeset for a working memory item.
  """
  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :content,
      :category,
      :context,
      :embedding,
      :importance,
      :tokens,
      :session_id,
      :source,
      :tool_name,
      :consolidation_candidate
    ])
    |> validate_required([:content])
    |> validate_number(:importance,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
    |> set_timestamps()
  end

  @doc """
  Creates a new working memory item from attributes.
  """
  def new(attrs) do
    changeset =
      %__MODULE__{}
      |> changeset(attrs)
      |> put_change(:id, Ecto.UUID.generate())

    case apply_action(changeset, :insert) do
      {:ok, item} -> {:ok, item}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp set_timestamps(changeset) do
    now = DateTime.utc_now()
    ttl_seconds = get_ttl_seconds()

    changeset
    |> put_change(:created_at, now)
    |> put_change(:accessed_at, now)
    |> put_change(:expires_at, DateTime.add(now, ttl_seconds, :second))
  end

  defp get_ttl_seconds do
    Application.get_env(:mimo_mcp, :working_memory, [])
    |> Keyword.get(:ttl_seconds, 600)
  end

  @doc """
  Check if an item has expired.
  """
  def expired?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :gt
  end

  @doc """
  Refresh the accessed_at timestamp.
  """
  def touch(%__MODULE__{} = item) do
    %{item | accessed_at: DateTime.utc_now()}
  end

  @doc """
  Extend TTL by refreshing expires_at.
  """
  def extend_ttl(%__MODULE__{} = item, additional_seconds \\ nil) do
    ttl = additional_seconds || get_ttl_seconds()
    %{item | expires_at: DateTime.add(DateTime.utc_now(), ttl, :second)}
  end
end
