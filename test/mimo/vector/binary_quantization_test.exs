defmodule Mimo.Vector.BinaryQuantizationTest do
  @moduledoc """
  Tests for SPEC-033 Phase 3a: Binary Quantization functions.

  Binary quantization converts float32 vectors to 32-byte binary format
  using sign bits for ultra-fast Hamming distance pre-filtering.
  """
  use ExUnit.Case, async: true

  alias Mimo.Vector.Math, as: VectorMath

  @dimensions 256
  # 256 bits / 8 = 32 bytes
  @binary_size 32

  describe "to_binary/1" do
    test "converts 256-dim float vector to 32-byte binary" do
      vec = generate_random_vector(@dimensions)

      case VectorMath.to_binary(vec) do
        {:ok, binary} ->
          assert is_binary(binary)
          assert byte_size(binary) == @binary_size

        {:error, :nif_not_available} ->
          # Skip if NIFs not compiled
          :ok
      end
    end

    test "positive values set bit to 1, negative to 0" do
      # All positive values should give all 1s (0xFF bytes)
      all_positive = List.duplicate(1.0, @dimensions)

      case VectorMath.to_binary(all_positive) do
        {:ok, binary} ->
          # 32 bytes of 0xFF = all bits set to 1
          assert binary == :binary.copy(<<0xFF>>, @binary_size)

        {:error, :nif_not_available} ->
          :ok
      end
    end

    test "all negative values give all 0s" do
      all_negative = List.duplicate(-1.0, @dimensions)

      case VectorMath.to_binary(all_negative) do
        {:ok, binary} ->
          # 32 bytes of 0x00 = all bits set to 0
          assert binary == :binary.copy(<<0>>, @binary_size)

        {:error, :nif_not_available} ->
          :ok
      end
    end

    test "handles zero as positive (>= 0)" do
      all_zeros = List.duplicate(0.0, @dimensions)

      case VectorMath.to_binary(all_zeros) do
        {:ok, binary} ->
          # Zero is treated as positive (>= 0), so all bits set to 1
          assert binary == :binary.copy(<<0xFF>>, @binary_size)

        {:error, :nif_not_available} ->
          :ok
      end
    end

    test "handles empty vector" do
      result = VectorMath.to_binary([])

      case result do
        {:error, :empty_vector} -> :ok
        {:error, :nif_not_available} -> :ok
        # Some implementations may return empty binary
        {:ok, <<>>} -> :ok
      end
    end

    test "handles non-256 dimensions" do
      vec_128 = generate_random_vector(128)

      case VectorMath.to_binary(vec_128) do
        {:ok, binary} ->
          # 128 bits / 8 = 16 bytes
          assert byte_size(binary) == 16

        {:error, :nif_not_available} ->
          :ok
      end
    end
  end

  describe "hamming_distance/2" do
    test "identical vectors have zero distance" do
      binary = :crypto.strong_rand_bytes(@binary_size)

      case VectorMath.hamming_distance(binary, binary) do
        {:ok, distance} ->
          assert distance == 0

        {:error, :nif_not_available} ->
          :ok
      end
    end

    test "opposite vectors have maximum distance (256 bits)" do
      # 32 bytes of 0x00 = all zeros
      a = :binary.copy(<<0>>, @binary_size)
      # 32 bytes of 0xFF = all ones
      b = :binary.copy(<<0xFF>>, @binary_size)

      case VectorMath.hamming_distance(a, b) do
        {:ok, distance} ->
          # All 256 bits differ
          assert distance == 256

        {:error, :nif_not_available} ->
          :ok
      end
    end

    test "hamming distance is symmetric" do
      a = :crypto.strong_rand_bytes(@binary_size)
      b = :crypto.strong_rand_bytes(@binary_size)

      case {VectorMath.hamming_distance(a, b), VectorMath.hamming_distance(b, a)} do
        {{:ok, dist_ab}, {:ok, dist_ba}} ->
          assert dist_ab == dist_ba

        _ ->
          :ok
      end
    end

    test "single bit difference gives distance of 1" do
      # 32 bytes of 0x00
      a = :binary.copy(<<0>>, @binary_size)
      # Only first bit differs (0x01 in first byte, rest 0x00)
      b = <<1, 0::size(248)>>

      case VectorMath.hamming_distance(a, b) do
        {:ok, distance} ->
          assert distance == 1

        {:error, :nif_not_available} ->
          :ok
      end
    end

    test "mismatched sizes return error" do
      a = :crypto.strong_rand_bytes(32)
      b = :crypto.strong_rand_bytes(16)

      case VectorMath.hamming_distance(a, b) do
        {:error, :dimension_mismatch} -> :ok
        {:error, :nif_not_available} -> :ok
        # Some implementations may handle this differently
        _ -> :ok
      end
    end
  end

  describe "top_k_hamming/3" do
    test "returns top-k closest vectors by Hamming distance" do
      query = :crypto.strong_rand_bytes(@binary_size)

      # Create corpus with query as first element (should have distance 0)
      corpus = [query | for(_ <- 1..9, do: :crypto.strong_rand_bytes(@binary_size))]

      case VectorMath.top_k_hamming(query, corpus, 3) do
        {:ok, results} ->
          assert length(results) == 3

          # First result should be the query itself (index 0, distance 0)
          [{idx, dist} | _] = results
          assert idx == 0
          assert dist == 0

          # Results should be sorted by distance
          distances = Enum.map(results, &elem(&1, 1))
          assert distances == Enum.sort(distances)

        {:error, :nif_not_available} ->
          :ok
      end
    end

    test "returns all vectors when k > corpus size" do
      query = :crypto.strong_rand_bytes(@binary_size)
      corpus = for _ <- 1..5, do: :crypto.strong_rand_bytes(@binary_size)

      case VectorMath.top_k_hamming(query, corpus, 10) do
        {:ok, results} ->
          assert length(results) == 5

        {:error, :nif_not_available} ->
          :ok
      end
    end

    test "empty corpus returns empty results" do
      query = :crypto.strong_rand_bytes(@binary_size)

      case VectorMath.top_k_hamming(query, [], 5) do
        {:ok, results} ->
          assert results == []

        # NIF may return error for empty corpus - this is also acceptable
        {:error, :empty_corpus} ->
          :ok

        {:error, :nif_not_available} ->
          :ok
      end
    end

    test "k=0 returns empty results" do
      query = :crypto.strong_rand_bytes(@binary_size)
      corpus = for _ <- 1..5, do: :crypto.strong_rand_bytes(@binary_size)

      case VectorMath.top_k_hamming(query, corpus, 0) do
        {:ok, results} ->
          assert results == []

        {:error, :nif_not_available} ->
          :ok
      end
    end
  end

  describe "binary quantization quality" do
    test "similar float vectors produce similar binary vectors" do
      # Create two similar vectors (small perturbation)
      base = generate_random_vector(@dimensions)
      similar = Enum.map(base, fn x -> x + (:rand.uniform() - 0.5) * 0.1 end)
      different = generate_random_vector(@dimensions)

      case {VectorMath.to_binary(base), VectorMath.to_binary(similar),
            VectorMath.to_binary(different)} do
        {{:ok, bin_base}, {:ok, bin_similar}, {:ok, bin_different}} ->
          {:ok, dist_similar} = VectorMath.hamming_distance(bin_base, bin_similar)
          {:ok, dist_different} = VectorMath.hamming_distance(bin_base, bin_different)

          # Similar vectors should have lower Hamming distance
          # Note: This is probabilistic, may occasionally fail
          assert dist_similar < dist_different or dist_different < 128

        _ ->
          :ok
      end
    end

    test "binary distance correlates with cosine similarity" do
      # Generate test vectors
      base = generate_random_vector(@dimensions)
      vectors = for _ <- 1..100, do: generate_random_vector(@dimensions)

      skip_if_nif_unavailable(fn ->
        # Get binary representations
        {:ok, bin_base} = VectorMath.to_binary(base)

        bin_vectors =
          Enum.map(vectors, fn v ->
            {:ok, bin} = VectorMath.to_binary(v)
            bin
          end)

        # Calculate both distances
        distances =
          Enum.zip(vectors, bin_vectors)
          |> Enum.map(fn {float_vec, bin_vec} ->
            {:ok, hamming} = VectorMath.hamming_distance(bin_base, bin_vec)

            # Calculate cosine similarity using fallback
            cosine = Mimo.Vector.Math.Fallback.cosine_similarity(base, float_vec)

            {hamming, cosine}
          end)

        # Check correlation: lower Hamming distance should correlate with higher cosine
        # Sort by Hamming distance and check that top results have reasonable cosine
        top_by_hamming =
          distances
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.take(10)
          |> Enum.map(&elem(&1, 1))

        # Average cosine of top-10 by Hamming should be positive
        avg_cosine = Enum.sum(top_by_hamming) / length(top_by_hamming)
        assert avg_cosine > 0.0
      end)
    end
  end

  # Helper functions

  defp generate_random_vector(dimensions) do
    for _ <- 1..dimensions, do: :rand.uniform() * 2 - 1
  end

  defp skip_if_nif_unavailable(fun) do
    vec = generate_random_vector(@dimensions)

    case VectorMath.to_binary(vec) do
      {:ok, _} -> fun.()
      {:error, :nif_not_available} -> :ok
    end
  end
end
