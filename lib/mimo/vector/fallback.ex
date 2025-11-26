defmodule Mimo.Vector.Fallback do
  @moduledoc """
  Pure Elixir fallback implementations for vector operations.
  
  Used when the Rust NIF is not available (development, unsupported platforms).
  Performance is ~10-40x slower than the NIF but functionally identical.
  """

  @doc """
  Pure Elixir cosine similarity implementation.
  """
  @spec cosine_similarity([float()], [float()]) :: {:ok, float()} | {:error, atom()}
  def cosine_similarity([], _), do: {:error, :empty_vector}
  def cosine_similarity(_, []), do: {:error, :empty_vector}
  def cosine_similarity(a, b) when length(a) != length(b), do: {:error, :dimension_mismatch}

  def cosine_similarity(a, b) when is_list(a) and is_list(b) do
    {dot, mag_a, mag_b} = 
      a
      |> Enum.zip(b)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {x, y}, {dot, ma, mb} ->
        {dot + x * y, ma + x * x, mb + y * y}
      end)

    mag_a = :math.sqrt(mag_a)
    mag_b = :math.sqrt(mag_b)

    if mag_a == 0.0 or mag_b == 0.0 do
      {:ok, 0.0}
    else
      {:ok, dot / (mag_a * mag_b)}
    end
  end

  @doc """
  Pure Elixir batch similarity implementation.
  """
  @spec batch_similarity([float()], [[float()]]) :: {:ok, [float()]} | {:error, atom()}
  def batch_similarity([], _), do: {:error, :empty_vector}
  def batch_similarity(_, []), do: {:error, :empty_corpus}

  def batch_similarity(query, corpus) when is_list(query) and is_list(corpus) do
    dim = length(query)

    # Validate all vectors have same dimension
    case Enum.find(corpus, fn vec -> length(vec) != dim end) do
      nil ->
        results =
          corpus
          |> Task.async_stream(
            fn vec -> 
              {:ok, sim} = cosine_similarity(query, vec)
              sim
            end,
            max_concurrency: System.schedulers_online(),
            ordered: true
          )
          |> Enum.map(fn {:ok, sim} -> sim end)

        {:ok, results}

      _mismatched ->
        {:error, :dimension_mismatch}
    end
  end

  @doc """
  Pure Elixir top-k similar implementation.
  """
  @spec top_k_similar([float()], [[float()]], non_neg_integer()) ::
          {:ok, [{non_neg_integer(), float()}]} | {:error, atom()}
  def top_k_similar([], _, _), do: {:error, :empty_vector}
  def top_k_similar(_, [], _), do: {:error, :empty_corpus}

  def top_k_similar(query, corpus, k) when is_list(query) and is_list(corpus) and is_integer(k) do
    case batch_similarity(query, corpus) do
      {:ok, similarities} ->
        results =
          similarities
          |> Enum.with_index()
          |> Enum.map(fn {sim, idx} -> {idx, sim} end)
          |> Enum.sort_by(fn {_idx, sim} -> sim end, :desc)
          |> Enum.take(k)

        {:ok, results}

      error ->
        error
    end
  end

  @doc """
  Pure Elixir vector normalization.
  """
  @spec normalize_vector([float()]) :: {:ok, [float()]} | {:error, atom()}
  def normalize_vector([]), do: {:error, :empty_vector}

  def normalize_vector(vec) when is_list(vec) do
    magnitude = vec |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt()

    if magnitude == 0.0 do
      {:ok, vec}
    else
      {:ok, Enum.map(vec, &(&1 / magnitude))}
    end
  end
end
