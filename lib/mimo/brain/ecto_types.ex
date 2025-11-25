defmodule Mimo.Brain.EctoJsonList do
  @moduledoc """
  Custom Ecto type for JSON list (embedding vectors).
  Serializes lists to JSON text for SQLite storage.
  """
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

defmodule Mimo.Brain.EctoJsonMap do
  @moduledoc """
  Custom Ecto type for JSON map (metadata).
  Serializes maps to JSON text for SQLite storage.
  """
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
