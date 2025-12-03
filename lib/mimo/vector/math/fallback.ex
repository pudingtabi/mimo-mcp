defmodule Mimo.Vector.Math.Fallback do
  @moduledoc """
  Pure Elixir fallbacks for vector math operations used in tests and environments
  where NIF-backed implementations are unavailable.
  """

  @doc """
  Compute cosine similarity between two float vectors.

  Returns a float in [-1.0, 1.0]. If either vector has zero norm or the
  inputs are invalid/mismatched, returns 0.0.
  """
  @spec cosine_similarity([number()], [number()]) :: float()
  def cosine_similarity(a, b) when is_list(a) and is_list(b) do
    if length(a) == length(b) and length(a) > 0 do
      {dot, na2, nb2} =
        Enum.zip(a, b)
        |> Enum.reduce({0.0, 0.0, 0.0}, fn {x, y}, {d, sa, sb} ->
          xf = to_float(x)
          yf = to_float(y)
          {d + xf * yf, sa + xf * xf, sb + yf * yf}
        end)

      denom = :math.sqrt(na2) * :math.sqrt(nb2)
      if denom > 0.0, do: dot / denom, else: 0.0
    else
      0.0
    end
  end

  def cosine_similarity(_, _), do: 0.0

  defp to_float(x) when is_float(x), do: x
  defp to_float(x) when is_integer(x), do: x / 1.0
  defp to_float(_), do: 0.0
end
