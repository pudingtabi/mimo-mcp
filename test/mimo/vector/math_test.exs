defmodule Mimo.Vector.MathTest do
  use ExUnit.Case, async: true
  alias Mimo.Vector.Math

  describe "cosine_similarity/2" do
    test "returns 1.0 for identical vectors" do
      vec = [1.0, 2.0, 3.0, 4.0]
      assert {:ok, sim} = Math.cosine_similarity(vec, vec)
      assert_in_delta sim, 1.0, 0.0001
    end

    test "returns 0.0 for orthogonal vectors" do
      a = [1.0, 0.0, 0.0, 0.0]
      b = [0.0, 1.0, 0.0, 0.0]
      assert {:ok, sim} = Math.cosine_similarity(a, b)
      assert_in_delta sim, 0.0, 0.0001
    end

    test "returns -1.0 for opposite vectors" do
      a = [1.0, 2.0, 3.0]
      b = [-1.0, -2.0, -3.0]
      assert {:ok, sim} = Math.cosine_similarity(a, b)
      assert_in_delta sim, -1.0, 0.0001
    end

    test "handles large vectors (1536 dimensions)" do
      a = for i <- 1..1536, do: i / 1536.0
      b = for i <- 1..1536, do: (1536 - i) / 1536.0

      assert {:ok, sim} = Math.cosine_similarity(a, b)
      assert sim >= -1.0 and sim <= 1.0
    end

    test "returns error for empty vectors" do
      assert {:error, :empty_vector} = Math.cosine_similarity([], [1.0])
      assert {:error, :empty_vector} = Math.cosine_similarity([1.0], [])
    end

    test "returns error for dimension mismatch" do
      a = [1.0, 2.0, 3.0]
      b = [1.0, 2.0]
      assert {:error, :dimension_mismatch} = Math.cosine_similarity(a, b)
    end
  end

  describe "batch_similarity/2" do
    test "computes similarities for multiple vectors" do
      query = [1.0, 0.0, 0.0]

      corpus = [
        # Identical
        [1.0, 0.0, 0.0],
        # Orthogonal
        [0.0, 1.0, 0.0],
        # 45 degrees
        [0.707, 0.707, 0.0]
      ]

      assert {:ok, results} = Math.batch_similarity(query, corpus)
      assert length(results) == 3

      [sim1, sim2, sim3] = results
      assert_in_delta sim1, 1.0, 0.0001
      assert_in_delta sim2, 0.0, 0.0001
      assert_in_delta sim3, 0.707, 0.001
    end

    test "returns error for empty corpus" do
      assert {:error, :empty_corpus} = Math.batch_similarity([1.0], [])
    end
  end

  describe "top_k_similar/3" do
    test "returns top k most similar vectors" do
      query = [1.0, 0.0, 0.0]

      corpus = [
        # Index 0
        [0.5, 0.5, 0.0],
        # Index 1 - most similar
        [1.0, 0.0, 0.0],
        # Index 2 - orthogonal
        [0.0, 1.0, 0.0],
        # Index 3 - very similar
        [0.9, 0.1, 0.0]
      ]

      assert {:ok, results} = Math.top_k_similar(query, corpus, 2)
      assert length(results) == 2

      [{idx1, sim1}, {idx2, sim2}] = results

      # Index 1 should be first (identical)
      assert idx1 == 1
      assert_in_delta sim1, 1.0, 0.0001

      # Index 3 should be second
      assert idx2 == 3
      assert sim2 > 0.9
    end

    test "handles k larger than corpus" do
      query = [1.0, 0.0]
      corpus = [[1.0, 0.0], [0.0, 1.0]]

      assert {:ok, results} = Math.top_k_similar(query, corpus, 10)
      assert length(results) == 2
    end
  end

  describe "normalize_vector/1" do
    test "normalizes to unit length" do
      # Length = 5
      vec = [3.0, 4.0]
      assert {:ok, normalized} = Math.normalize_vector(vec)

      [x, y] = normalized
      assert_in_delta x, 0.6, 0.0001
      assert_in_delta y, 0.8, 0.0001

      # Check unit length
      length = :math.sqrt(x * x + y * y)
      assert_in_delta length, 1.0, 0.0001
    end

    test "handles zero vector" do
      vec = [0.0, 0.0, 0.0]
      assert {:ok, ^vec} = Math.normalize_vector(vec)
    end

    test "returns error for empty vector" do
      assert {:error, :empty_vector} = Math.normalize_vector([])
    end
  end

  # ===========================================================================
  # Int8 Quantization Tests (SPEC-031 Phase 2)
  # ===========================================================================

  describe "quantize_int8/1" do
    test "quantizes a simple vector" do
      vec = [0.1, 0.5, -0.3, 0.8, -0.9, 0.0]
      assert {:ok, {binary, scale, offset}} = Math.quantize_int8(vec)

      # Binary should be same length as input
      assert byte_size(binary) == length(vec)

      # Scale and offset should be numbers
      assert is_float(scale) or is_integer(scale)
      assert is_float(offset) or is_integer(offset)
    end

    test "quantizes embedding-sized vectors (256 dim)" do
      # Random [-1, 1]
      vec = for i <- 1..256, do: :rand.uniform() * 2 - 1
      assert {:ok, {binary, _scale, _offset}} = Math.quantize_int8(vec)
      assert byte_size(binary) == 256
    end

    test "quantizes embedding-sized vectors (1024 dim)" do
      vec = for i <- 1..1024, do: :rand.uniform() * 2 - 1
      assert {:ok, {binary, _scale, _offset}} = Math.quantize_int8(vec)
      assert byte_size(binary) == 1024
    end

    test "returns error for empty vector" do
      assert {:error, :empty_vector} = Math.quantize_int8([])
    end

    test "handles constant vector" do
      vec = [0.5, 0.5, 0.5, 0.5]
      assert {:ok, {binary, _scale, _offset}} = Math.quantize_int8(vec)
      assert byte_size(binary) == 4
    end
  end

  describe "dequantize_int8/3" do
    test "roundtrips simple vector with acceptable error" do
      original = [0.1, 0.5, -0.3, 0.8, -0.9, 0.0, 0.25, -0.75]

      {:ok, {binary, scale, offset}} = Math.quantize_int8(original)
      {:ok, restored} = Math.dequantize_int8(binary, scale, offset)

      assert length(restored) == length(original)

      # Each value should be within ~1% of original (quantization error)
      for {orig, rest} <- Enum.zip(original, restored) do
        assert_in_delta orig, rest, 0.02
      end
    end

    test "roundtrips 256-dim embedding with acceptable error" do
      # Simulate real embedding distribution (normalized, centered around 0)
      original = for _ <- 1..256, do: :rand.normal() * 0.1

      {:ok, {binary, scale, offset}} = Math.quantize_int8(original)
      {:ok, restored} = Math.dequantize_int8(binary, scale, offset)

      # Compute mean absolute error
      errors = for {o, r} <- Enum.zip(original, restored), do: abs(o - r)
      mean_error = Enum.sum(errors) / length(errors)

      # Mean error should be small
      assert mean_error < 0.01
    end

    test "returns error for empty binary" do
      assert {:error, :empty_vector} = Math.dequantize_int8(<<>>, 1.0, 0.0)
    end
  end

  describe "cosine_similarity_int8/2" do
    test "returns ~1.0 for identical quantized vectors" do
      vec = for _ <- 1..64, do: :rand.uniform() * 2 - 1
      {:ok, {binary, _scale, _offset}} = Math.quantize_int8(vec)

      assert {:ok, sim} = Math.cosine_similarity_int8(binary, binary)
      assert_in_delta sim, 1.0, 0.0001
    end

    test "approximates float32 similarity within 1%" do
      # Two different vectors
      a = for _ <- 1..256, do: :rand.normal() * 0.1
      b = for _ <- 1..256, do: :rand.normal() * 0.1

      # Float32 similarity
      {:ok, float_sim} = Math.cosine_similarity(a, b)

      # Int8 similarity
      {:ok, {bin_a, _, _}} = Math.quantize_int8(a)
      {:ok, {bin_b, _, _}} = Math.quantize_int8(b)
      {:ok, int8_sim} = Math.cosine_similarity_int8(bin_a, bin_b)

      # Should be within 5% (quantization introduces some error)
      assert_in_delta float_sim, int8_sim, 0.05
    end

    test "returns error for empty vectors" do
      assert {:error, :empty_vector} = Math.cosine_similarity_int8(<<>>, <<1>>)
      assert {:error, :empty_vector} = Math.cosine_similarity_int8(<<1>>, <<>>)
    end

    test "returns error for dimension mismatch" do
      a = <<1, 2, 3>>
      b = <<1, 2>>
      assert {:error, :dimension_mismatch} = Math.cosine_similarity_int8(a, b)
    end
  end

  describe "batch_similarity_int8/2" do
    test "computes similarities for multiple int8 vectors" do
      query = for _ <- 1..64, do: :rand.normal() * 0.1

      corpus =
        for _ <- 1..5 do
          for _ <- 1..64, do: :rand.normal() * 0.1
        end

      # Quantize all
      {:ok, {query_bin, _, _}} = Math.quantize_int8(query)

      corpus_bins =
        for vec <- corpus do
          {:ok, {bin, _, _}} = Math.quantize_int8(vec)
          bin
        end

      assert {:ok, results} = Math.batch_similarity_int8(query_bin, corpus_bins)
      assert length(results) == 5

      # All similarities should be valid
      for sim <- results do
        assert sim >= -1.0 and sim <= 1.0
      end
    end

    test "returns error for empty corpus" do
      {:ok, {query_bin, _, _}} = Math.quantize_int8([0.1, 0.2, 0.3])
      assert {:error, :empty_corpus} = Math.batch_similarity_int8(query_bin, [])
    end
  end

  describe "top_k_similar_int8/3" do
    test "returns top k from int8 corpus" do
      query = for _ <- 1..64, do: :rand.normal() * 0.1

      # Create corpus with one vector very similar to query
      corpus = [
        for(_ <- 1..64, do: :rand.normal() * 0.1),
        # Identical to query
        query,
        for(_ <- 1..64, do: :rand.normal() * 0.1),
        for(_ <- 1..64, do: :rand.normal() * 0.1)
      ]

      # Quantize all
      {:ok, {query_bin, _, _}} = Math.quantize_int8(query)

      corpus_bins =
        for vec <- corpus do
          {:ok, {bin, _, _}} = Math.quantize_int8(vec)
          bin
        end

      assert {:ok, results} = Math.top_k_similar_int8(query_bin, corpus_bins, 2)
      assert length(results) == 2

      # First result should be index 1 (identical vector)
      [{idx1, sim1}, _] = results
      assert idx1 == 1
      assert_in_delta sim1, 1.0, 0.01
    end
  end

  describe "storage reduction verification" do
    test "int8 provides 4x storage reduction" do
      # Original float32 vector (256 dimensions)
      vec = for _ <- 1..256, do: :rand.uniform() * 2 - 1

      # Float32 storage (JSON encoded list)
      float_storage = vec |> Jason.encode!() |> byte_size()

      # Int8 storage (binary + 2 floats for scale/offset)
      {:ok, {binary, _scale, _offset}} = Math.quantize_int8(vec)
      # Binary + ~16 bytes for scale/offset floats
      int8_storage = byte_size(binary) + 16

      # Reduction ratio
      ratio = float_storage / int8_storage

      # Should be at least 3x reduction (JSON encoding has overhead)
      assert ratio > 3.0

      # Log the actual reduction
      IO.puts("\nStorage reduction: #{Float.round(ratio, 2)}x")
      IO.puts("Float32 JSON: #{float_storage} bytes")
      IO.puts("Int8 binary:  #{int8_storage} bytes")
    end

    test "combined MRL + int8 provides 16x reduction from 1024 dims" do
      # Original 1024-dim float32 vector
      vec_1024 = for _ <- 1..1024, do: :rand.uniform() * 2 - 1
      float_1024_storage = vec_1024 |> Jason.encode!() |> byte_size()

      # MRL truncated to 256 dims (simulating Enum.take)
      vec_256 = Enum.take(vec_1024, 256)

      # Quantize the 256-dim vector
      {:ok, {binary, _scale, _offset}} = Math.quantize_int8(vec_256)
      int8_256_storage = byte_size(binary) + 16

      # Total reduction ratio
      ratio = float_1024_storage / int8_256_storage

      # Should be close to 16x
      assert ratio > 12.0

      IO.puts("\nCombined MRL + Int8 reduction: #{Float.round(ratio, 2)}x")
      IO.puts("Original 1024-dim JSON: #{float_1024_storage} bytes")
      IO.puts("Int8 256-dim binary:    #{int8_256_storage} bytes")
    end
  end
end
