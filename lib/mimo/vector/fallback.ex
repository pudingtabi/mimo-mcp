defmodule Mimo.Vector.Fallback do
  @moduledoc """
  Pure Elixir fallback implementations for vector operations.

  Used when the Rust NIF is not available (development, unsupported platforms).
  Performance is ~10-40x slower than the NIF but functionally identical.

  Includes int8 quantization fallbacks added in SPEC-031 Phase 2.
  Includes binary quantization fallbacks added in SPEC-033 Phase 3a.
  """

  # ===========================================================================
  # Float32 Vector Operations
  # ===========================================================================

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

  # ===========================================================================
  # Int8 Quantization Operations (SPEC-031 Phase 2)
  # ===========================================================================

  @doc """
  Pure Elixir int8 quantization implementation.

  Quantizes float32 vector to int8 using min-max scaling.
  Returns {binary, scale, offset} tuple.
  """
  @spec quantize_int8([float()]) :: {:ok, {binary(), float(), float()}} | {:error, atom()}
  def quantize_int8([]), do: {:error, :empty_vector}

  def quantize_int8(vec) when is_list(vec) do
    # Find min/max for scaling
    {min_val, max_val} = Enum.min_max(vec)

    # Calculate scale and offset
    range = max_val - min_val
    scale = if range == 0.0, do: 1.0, else: range / 255.0
    offset = min_val

    # Quantize to int8 (-128 to 127, stored as unsigned bytes)
    quantized =
      vec
      |> Enum.map(fn v ->
        normalized = if scale == 0.0, do: 0.0, else: (v - offset) / scale
        # Map 0-255 to -128 to 127, then store as unsigned byte
        int8_value = trunc(Float.round(normalized - 128.0))
        int8_value = max(-128, min(127, int8_value))
        # Convert signed to unsigned byte
        <<int8_value::signed-integer-8>>
      end)
      |> IO.iodata_to_binary()

    {:ok, {quantized, scale, offset}}
  end

  @doc """
  Pure Elixir int8 dequantization implementation.

  Restores float32 vector from int8 binary using scale and offset.
  """
  @spec dequantize_int8(binary(), float(), float()) :: {:ok, [float()]} | {:error, atom()}
  def dequantize_int8(<<>>, _scale, _offset), do: {:error, :empty_vector}

  def dequantize_int8(binary, scale, offset)
      when is_binary(binary) and is_number(scale) and is_number(offset) do
    # Ensure float
    scale = scale / 1
    offset = offset / 1

    dequantized =
      binary
      |> :binary.bin_to_list()
      |> Enum.map(fn byte ->
        # Interpret as signed int8
        signed = if byte > 127, do: byte - 256, else: byte
        # Reverse quantization: float = (int8 + 128) * scale + offset
        (signed + 128) * scale + offset
      end)

    {:ok, dequantized}
  end

  @doc """
  Pure Elixir cosine similarity on int8 vectors.

  Uses integer arithmetic for the core computation.
  """
  @spec cosine_similarity_int8(binary(), binary()) :: {:ok, float()} | {:error, atom()}
  def cosine_similarity_int8(<<>>, _), do: {:error, :empty_vector}
  def cosine_similarity_int8(_, <<>>), do: {:error, :empty_vector}

  def cosine_similarity_int8(a, b) when byte_size(a) != byte_size(b),
    do: {:error, :dimension_mismatch}

  def cosine_similarity_int8(a, b) when is_binary(a) and is_binary(b) do
    # Convert to signed integer lists
    list_a = binary_to_signed_list(a)
    list_b = binary_to_signed_list(b)

    # Compute dot product and norms using integer arithmetic
    {dot, norm_a, norm_b} =
      list_a
      |> Enum.zip(list_b)
      |> Enum.reduce({0, 0, 0}, fn {ai, bi}, {d, na, nb} ->
        {d + ai * bi, na + ai * ai, nb + bi * bi}
      end)

    # Final computation with floats
    denom = :math.sqrt(norm_a) * :math.sqrt(norm_b)

    if denom == 0.0 do
      {:ok, 0.0}
    else
      {:ok, dot / denom}
    end
  end

  @doc """
  Pure Elixir batch similarity on int8 vectors.
  """
  @spec batch_similarity_int8(binary(), [binary()]) :: {:ok, [float()]} | {:error, atom()}
  def batch_similarity_int8(<<>>, _), do: {:error, :empty_vector}
  def batch_similarity_int8(_, []), do: {:error, :empty_corpus}

  def batch_similarity_int8(query, corpus) when is_binary(query) and is_list(corpus) do
    dim = byte_size(query)

    # Validate all vectors have same dimension
    case Enum.find(corpus, fn vec -> byte_size(vec) != dim end) do
      nil ->
        results =
          corpus
          |> Task.async_stream(
            fn vec ->
              {:ok, sim} = cosine_similarity_int8(query, vec)
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
  Pure Elixir top-k similar on int8 vectors.
  """
  @spec top_k_similar_int8(binary(), [binary()], non_neg_integer()) ::
          {:ok, [{non_neg_integer(), float()}]} | {:error, atom()}
  def top_k_similar_int8(<<>>, _, _), do: {:error, :empty_vector}
  def top_k_similar_int8(_, [], _), do: {:error, :empty_corpus}

  def top_k_similar_int8(query, corpus, k)
      when is_binary(query) and is_list(corpus) and is_integer(k) do
    case batch_similarity_int8(query, corpus) do
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

  # ===========================================================================
  # Binary Quantization Operations (SPEC-033 Phase 3a)
  # ===========================================================================

  @doc """
  Pure Elixir binary quantization from float32.

  Converts float vector to binary representation where each dimension
  becomes 1 bit: 1 if >= 0, 0 if < 0.
  """
  @spec to_binary([float()]) :: {:ok, binary()} | {:error, atom()}
  def to_binary([]), do: {:error, :empty_vector}

  def to_binary(vec) when is_list(vec) do
    # Pack 8 sign bits into each byte (LSB first)
    byte_count = div(length(vec) + 7, 8)

    binary =
      vec
      |> Enum.with_index()
      |> Enum.reduce(:array.new(byte_count, {:default, 0}), fn {v, i}, acc ->
        if v >= 0.0 do
          byte_idx = div(i, 8)
          bit_idx = rem(i, 8)
          current = :array.get(byte_idx, acc)
          :array.set(byte_idx, Bitwise.bor(current, Bitwise.bsl(1, bit_idx)), acc)
        else
          acc
        end
      end)
      |> :array.to_list()
      |> :binary.list_to_bin()

    {:ok, binary}
  end

  @doc """
  Pure Elixir binary quantization from int8.

  Converts int8 binary to binary representation where each dimension
  becomes 1 bit: 1 if int8 value >= 0, 0 if < 0.
  """
  @spec int8_to_binary(binary()) :: {:ok, binary()} | {:error, atom()}
  def int8_to_binary(<<>>), do: {:error, :empty_vector}

  def int8_to_binary(int8_vec) when is_binary(int8_vec) do
    input = :binary.bin_to_list(int8_vec)
    byte_count = div(length(input) + 7, 8)

    binary =
      input
      |> Enum.with_index()
      |> Enum.reduce(:array.new(byte_count, {:default, 0}), fn {v, i}, acc ->
        # Interpret as signed: values >= 0 (when signed) get bit 1
        signed = if v > 127, do: v - 256, else: v

        if signed >= 0 do
          byte_idx = div(i, 8)
          bit_idx = rem(i, 8)
          current = :array.get(byte_idx, acc)
          :array.set(byte_idx, Bitwise.bor(current, Bitwise.bsl(1, bit_idx)), acc)
        else
          acc
        end
      end)
      |> :array.to_list()
      |> :binary.list_to_bin()

    {:ok, binary}
  end

  @doc """
  Pure Elixir Hamming distance computation.

  Computes the number of differing bits between two binary vectors.
  """
  @spec hamming_distance(binary(), binary()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def hamming_distance(<<>>, _), do: {:error, :empty_vector}
  def hamming_distance(_, <<>>), do: {:error, :empty_vector}

  def hamming_distance(a, b) when byte_size(a) != byte_size(b),
    do: {:error, :dimension_mismatch}

  def hamming_distance(a, b) when is_binary(a) and is_binary(b) do
    distance =
      :binary.bin_to_list(a)
      |> Enum.zip(:binary.bin_to_list(b))
      |> Enum.map(fn {x, y} -> popcount(Bitwise.bxor(x, y)) end)
      |> Enum.sum()

    {:ok, distance}
  end

  @doc """
  Pure Elixir batch Hamming distance computation.
  """
  @spec batch_hamming_distance(binary(), [binary()]) ::
          {:ok, [non_neg_integer()]} | {:error, atom()}
  def batch_hamming_distance(<<>>, _), do: {:error, :empty_vector}
  def batch_hamming_distance(_, []), do: {:error, :empty_corpus}

  def batch_hamming_distance(query, corpus) when is_binary(query) and is_list(corpus) do
    dim = byte_size(query)

    case Enum.find(corpus, fn vec -> byte_size(vec) != dim end) do
      nil ->
        results =
          corpus
          |> Task.async_stream(
            fn vec ->
              {:ok, dist} = hamming_distance(query, vec)
              dist
            end,
            max_concurrency: System.schedulers_online(),
            ordered: true
          )
          |> Enum.map(fn {:ok, dist} -> dist end)

        {:ok, results}

      _mismatched ->
        {:error, :dimension_mismatch}
    end
  end

  @doc """
  Pure Elixir top-k by Hamming distance.

  Returns the k vectors with lowest Hamming distance (most similar).
  """
  @spec top_k_hamming(binary(), [binary()], non_neg_integer()) ::
          {:ok, [{non_neg_integer(), non_neg_integer()}]} | {:error, atom()}
  def top_k_hamming(<<>>, _, _), do: {:error, :empty_vector}
  def top_k_hamming(_, [], _), do: {:error, :empty_corpus}

  def top_k_hamming(query, corpus, k)
      when is_binary(query) and is_list(corpus) and is_integer(k) do
    case batch_hamming_distance(query, corpus) do
      {:ok, distances} ->
        results =
          distances
          |> Enum.with_index()
          |> Enum.map(fn {dist, idx} -> {idx, dist} end)
          # Ascending - lowest distance first
          |> Enum.sort_by(fn {_idx, dist} -> dist end, :asc)
          |> Enum.take(k)

        {:ok, results}

      error ->
        error
    end
  end

  @doc """
  Pure Elixir Hamming distance to similarity conversion.
  """
  @spec hamming_to_similarity(non_neg_integer(), non_neg_integer()) ::
          {:ok, float()} | {:error, atom()}
  def hamming_to_similarity(_distance, 0), do: {:error, :empty_vector}

  def hamming_to_similarity(distance, total_bits)
      when is_integer(distance) and is_integer(total_bits) do
    similarity = 1.0 - distance / total_bits
    {:ok, similarity}
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  @spec binary_to_signed_list(binary()) :: [integer()]
  defp binary_to_signed_list(binary) do
    binary
    |> :binary.bin_to_list()
    |> Enum.map(fn byte ->
      # Interpret unsigned byte as signed int8
      if byte > 127, do: byte - 256, else: byte
    end)
  end

  # Population count (number of 1 bits in a byte)
  @spec popcount(non_neg_integer()) :: non_neg_integer()
  defp popcount(byte) when byte >= 0 and byte <= 255 do
    # Brian Kernighan's algorithm would be faster for sparse bits,
    # but for a byte, lookup table or this approach is fine
    byte
    |> Integer.digits(2)
    |> Enum.sum()
  end
end
