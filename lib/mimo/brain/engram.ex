defmodule Mimo.Brain.Engram do
  @moduledoc """
  Universal Engram - the polymorphic memory unit.
  Based on CoALA framework principles.
  
  Note: Embedding and metadata are stored as JSON text in SQLite.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "engrams" do
    field :content, :string
    field :category, :string
    field :importance, :float, default: 0.5
    
    # These use custom Ecto type that serializes to JSON
    field :embedding, Mimo.Brain.EctoJsonList, default: []
    field :metadata, Mimo.Brain.EctoJsonMap, default: %{}
    
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

# Custom Ecto type for JSON list (embedding vectors)
defmodule Mimo.Brain.EctoJsonList do
  @behaviour Ecto.Type
  
  def type, do: :text
  
  def cast(list) when is_list(list), do: {:ok, list}
  def cast(_), do: :error
  
  def load(nil), do: {:ok, []}
  def load(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, list} when is_list(list) -> {:ok, list}
      _ -> {:ok, []}
    end
  end
  def load(data) when is_list(data), do: {:ok, data}
  
  def dump(list) when is_list(list), do: {:ok, Jason.encode!(list)}
  def dump(_), do: :error
  
  # Required callbacks for Ecto 3.x
  def equal?(a, b), do: a == b
  def embed_as(_), do: :self
end

# Custom Ecto type for JSON map (metadata)
defmodule Mimo.Brain.EctoJsonMap do
  @behaviour Ecto.Type
  
  def type, do: :text
  
  def cast(map) when is_map(map), do: {:ok, map}
  def cast(_), do: :error
  
  def load(nil), do: {:ok, %{}}
  def load(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:ok, %{}}
    end
  end
  def load(data) when is_map(data), do: {:ok, data}
  
  def dump(map) when is_map(map), do: {:ok, Jason.encode!(map)}
  def dump(_), do: :error
  
  # Required callbacks for Ecto 3.x
  def equal?(a, b), do: a == b
  def embed_as(_), do: :self
end
