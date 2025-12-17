defmodule Mimo.Vector.NifValidationTest do
  @moduledoc """
  SPEC-008: Rust NIFs Production Validation Tests

  Validates that Rust NIFs for SIMD vector operations are production-ready.
  Tests correctness, fallback behavior, and edge cases.
  """
  use ExUnit.Case, async: true

  alias Mimo.Vector.Math
  alias Mimo.Vector.Fallback

  # ===========================================================================
  # NIF Loading Tests
  # ===========================================================================

  describe "nif_loaded?/0" do
    test "returns boolean indicating NIF status" do
      result = Math.nif_loaded?()
      assert is_boolean(result)
    end
  end

  # ===========================================================================
  # Cosine Similarity Tests
  # ===========================================================================

  describe "cosine_similarity/2" do
    test "calculates similarity between identical vectors" do
      vec = List.duplicate(1.0, 768)

      {:ok, similarity} = Math.cosine_similarity(vec, vec)

      assert_in_delta similarity, 1.0, 0.0001
    end

    test "calculates similarity between orthogonal vectors" do
      vec_a = [1.0, 0.0, 0.0]
      vec_b = [0.0, 1.0, 0.0]

      {:ok, similarity} = Math.cosine_similarity(vec_a, vec_b)

      assert_in_delta similarity, 0.0, 0.0001
    end

    test "calculates similarity between opposite vectors" do
      vec_a = [1.0, 0.0, 0.0]
      vec_b = [-1.0, 0.0, 0.0]

      {:ok, similarity} = Math.cosine_similarity(vec_a, vec_b)

      assert_in_delta similarity, -1.0, 0.0001
    end

    test "handles mismatched dimensions" do
      vec_a = [1.0, 2.0, 3.0]
      vec_b = [1.0, 2.0]

      result = Math.cosine_similarity(vec_a, vec_b)

      assert {:error, :dimension_mismatch} = result
    end

    test "handles empty vectors" do
      result_a = Math.cosine_similarity([], [])
      result_b = Math.cosine_similarity([], [1.0])
      result_c = Math.cosine_similarity([1.0], [])

      assert {:error, :empty_vector} = result_a
      assert {:error, :empty_vector} = result_b
      assert {:error, :empty_vector} = result_c
    end

    test "handles zero vectors gracefully" do
      zero = [0.0, 0.0, 0.0]
      other = [1.0, 2.0, 3.0]

      result = Math.cosine_similarity(zero, other)

      # Should return 0.0 (handled gracefully, not NaN)
      assert {:ok, sim} = result
      assert_in_delta sim, 0.0, 0.0001
    end

    test "handles very small values" do
      small = [1.0e-10, 1.0e-10, 1.0e-10]
      normal = [1.0, 1.0, 1.0]

      {:ok, sim} = Math.cosine_similarity(small, normal)

      # Should still compute correctly
      assert_in_delta sim, 1.0, 0.001
    end

    test "handles very large values" do
      large = [1.0e10, 1.0e10, 1.0e10]
      normal = [1.0, 1.0, 1.0]

      {:ok, sim} = Math.cosine_similarity(large, normal)

      # Should still compute correctly
      assert_in_delta sim, 1.0, 0.001
    end

    test "handles negative values" do
      a = [-1.0, -2.0, -3.0]
      b = [-1.0, -2.0, -3.0]

      {:ok, sim} = Math.cosine_similarity(a, b)

      assert_in_delta sim, 1.0, 0.0001
    end

    test "handles mixed positive and negative values" do
      a = [1.0, -2.0, 3.0, -4.0]
      b = [-1.0, 2.0, -3.0, 4.0]

      {:ok, sim} = Math.cosine_similarity(a, b)

      assert_in_delta sim, -1.0, 0.0001
    end

    test "handles standard embedding dimensions (384)" do
      vec_a = for _ <- 1..384, do: :rand.uniform() * 2 - 1
      vec_b = for _ <- 1..384, do: :rand.uniform() * 2 - 1

      {:ok, sim} = Math.cosine_similarity(vec_a, vec_b)

      assert sim >= -1.0 and sim <= 1.0
    end

    test "handles standard embedding dimensions (768)" do
      vec_a = for _ <- 1..768, do: :rand.uniform() * 2 - 1
      vec_b = for _ <- 1..768, do: :rand.uniform() * 2 - 1

      {:ok, sim} = Math.cosine_similarity(vec_a, vec_b)

      assert sim >= -1.0 and sim <= 1.0
    end

    test "handles OpenAI embedding dimensions (1536)" do
      vec_a = for _ <- 1..1536, do: :rand.uniform() * 2 - 1
      vec_b = for _ <- 1..1536, do: :rand.uniform() * 2 - 1

      {:ok, sim} = Math.cosine_similarity(vec_a, vec_b)

      assert sim >= -1.0 and sim <= 1.0
    end
  end

  # ===========================================================================
  # Batch Similarity Tests
  # ===========================================================================

  describe "batch_similarity/2" do
    test "calculates similarity against multiple vectors" do
      query = [1.0, 0.0, 0.0]

      corpus = [
        [1.0, 0.0, 0.0],
        [0.0, 1.0, 0.0],
        [0.5, 0.5, 0.0]
      ]

      {:ok, similarities} = Math.batch_similarity(query, corpus)

      assert length(similarities) == 3
      assert_in_delta Enum.at(similarities, 0), 1.0, 0.001
      assert_in_delta Enum.at(similarities, 1), 0.0, 0.001
    end

    test "handles empty corpus" do
      query = [1.0, 0.0, 0.0]

      result = Math.batch_similarity(query, [])

      assert {:error, :empty_corpus} = result
    end

    test "handles large corpus (100 vectors)" do
      query = for _ <- 1..768, do: :rand.uniform() * 2 - 1
      corpus = for _ <- 1..100, do: for(_ <- 1..768, do: :rand.uniform() * 2 - 1)

      {:ok, similarities} = Math.batch_similarity(query, corpus)

      assert length(similarities) == 100

      Enum.each(similarities, fn sim ->
        assert sim >= -1.0 and sim <= 1.0
      end)
    end

    test "handles large corpus (1000 vectors)" do
      query = for _ <- 1..768, do: :rand.uniform() * 2 - 1
      corpus = for _ <- 1..1000, do: for(_ <- 1..768, do: :rand.uniform() * 2 - 1)

      {:ok, similarities} = Math.batch_similarity(query, corpus)

      assert length(similarities) == 1000
    end

    test "handles dimension mismatch in corpus" do
      query = [1.0, 0.0, 0.0]

      corpus = [
        [1.0, 0.0, 0.0],
        [0.0, 1.0]
      ]

      result = Math.batch_similarity(query, corpus)

      assert {:error, :dimension_mismatch} = result
    end
  end

  # ===========================================================================
  # Top-K Search Tests
  # ===========================================================================

  describe "top_k_similar/3" do
    test "returns top k most similar vectors" do
      query = [1.0, 0.0, 0.0]

      corpus = [
        [0.9, 0.1, 0.0],
        [0.0, 1.0, 0.0],
        [0.8, 0.2, 0.0],
        [-1.0, 0.0, 0.0],
        [0.7, 0.3, 0.0]
      ]

      {:ok, results} = Math.top_k_similar(query, corpus, 3)

      assert length(results) == 3

      # Should be sorted by similarity descending
      [{idx1, sim1}, {idx2, sim2}, {idx3, sim3}] = results

      # First should be index 0 (most similar)
      assert idx1 == 0
      assert sim1 > sim2
      assert sim2 > sim3
    end

    test "handles k larger than corpus" do
      query = [1.0, 0.0, 0.0]
      corpus = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]]

      {:ok, results} = Math.top_k_similar(query, corpus, 10)

      assert length(results) == 2
    end

    test "handles k = 0" do
      query = [1.0, 0.0, 0.0]
      corpus = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]]

      {:ok, results} = Math.top_k_similar(query, corpus, 0)

      assert results == []
    end

    test "handles k = 1" do
      query = [1.0, 0.0, 0.0]

      corpus = [
        [0.5, 0.5, 0.0],
        [1.0, 0.0, 0.0],
        [0.0, 1.0, 0.0]
      ]

      {:ok, results} = Math.top_k_similar(query, corpus, 1)

      assert length(results) == 1
      [{idx, _sim}] = results
      assert idx == 1
    end

    test "handles large corpus top-k search" do
      query = for _ <- 1..768, do: :rand.uniform() * 2 - 1
      corpus = for _ <- 1..1000, do: for(_ <- 1..768, do: :rand.uniform() * 2 - 1)

      {:ok, results} = Math.top_k_similar(query, corpus, 10)

      assert length(results) == 10

      # Verify descending order
      sims = Enum.map(results, fn {_idx, sim} -> sim end)

      Enum.zip(sims, Enum.drop(sims, 1))
      |> Enum.each(fn {a, b} -> assert a >= b end)
    end
  end

  # ===========================================================================
  # Vector Normalization Tests
  # ===========================================================================

  describe "normalize_vector/1" do
    test "normalizes vector to unit length" do
      vec = [3.0, 4.0]

      {:ok, normalized} = Math.normalize_vector(vec)

      [x, y] = normalized
      magnitude = :math.sqrt(x * x + y * y)

      assert_in_delta magnitude, 1.0, 0.0001
      assert_in_delta x, 0.6, 0.0001
      assert_in_delta y, 0.8, 0.0001
    end

    test "handles already normalized vector" do
      vec = [1.0, 0.0, 0.0]

      {:ok, normalized} = Math.normalize_vector(vec)

      assert_in_delta Enum.at(normalized, 0), 1.0, 0.0001
      assert_in_delta Enum.at(normalized, 1), 0.0, 0.0001
      assert_in_delta Enum.at(normalized, 2), 0.0, 0.0001
    end

    test "handles zero vector" do
      vec = [0.0, 0.0, 0.0]

      {:ok, result} = Math.normalize_vector(vec)

      assert result == vec
    end

    test "handles empty vector" do
      assert {:error, :empty_vector} = Math.normalize_vector([])
    end

    test "handles high-dimensional vector" do
      vec = for _ <- 1..1536, do: :rand.uniform() * 2 - 1

      {:ok, normalized} = Math.normalize_vector(vec)

      magnitude = normalized |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt()

      assert_in_delta magnitude, 1.0, 0.0001
    end
  end

  # ===========================================================================
  # Fallback Consistency Tests
  # ===========================================================================

  describe "fallback consistency" do
    test "Math and Fallback produce same results for cosine_similarity" do
      vec_a = for _ <- 1..768, do: :rand.uniform() * 2 - 1
      vec_b = for _ <- 1..768, do: :rand.uniform() * 2 - 1

      {:ok, math_result} = Math.cosine_similarity(vec_a, vec_b)
      {:ok, fallback_result} = Fallback.cosine_similarity(vec_a, vec_b)

      assert_in_delta math_result, fallback_result, 0.0001
    end

    test "Math and Fallback produce same results for batch_similarity" do
      query = for _ <- 1..768, do: :rand.uniform() * 2 - 1
      corpus = for _ <- 1..50, do: for(_ <- 1..768, do: :rand.uniform() * 2 - 1)

      {:ok, math_results} = Math.batch_similarity(query, corpus)
      {:ok, fallback_results} = Fallback.batch_similarity(query, corpus)

      for {m, f} <- Enum.zip(math_results, fallback_results) do
        assert_in_delta m, f, 0.0001
      end
    end

    test "Math and Fallback produce same results for top_k_similar" do
      query = for _ <- 1..768, do: :rand.uniform() * 2 - 1
      corpus = for _ <- 1..100, do: for(_ <- 1..768, do: :rand.uniform() * 2 - 1)

      {:ok, math_results} = Math.top_k_similar(query, corpus, 10)
      {:ok, fallback_results} = Fallback.top_k_similar(query, corpus, 10)

      # Both should return same indices (same vectors are most similar)
      math_indices = Enum.map(math_results, fn {idx, _} -> idx end)
      fallback_indices = Enum.map(fallback_results, fn {idx, _} -> idx end)

      assert math_indices == fallback_indices
    end

    test "Math and Fallback produce same results for normalize_vector" do
      vec = for _ <- 1..768, do: :rand.uniform() * 2 - 1

      {:ok, math_result} = Math.normalize_vector(vec)
      {:ok, fallback_result} = Fallback.normalize_vector(vec)

      for {m, f} <- Enum.zip(math_result, fallback_result) do
        assert_in_delta m, f, 0.0001
      end
    end
  end

  # ===========================================================================
  # Memory Safety Tests
  # ===========================================================================

  describe "memory safety" do
    test "handles large vectors without crash" do
      # 4096 dimensions (larger than typical)
      vec_a = for _ <- 1..4096, do: :rand.uniform()
      vec_b = for _ <- 1..4096, do: :rand.uniform()

      # Should not crash
      assert {:ok, _} = Math.cosine_similarity(vec_a, vec_b)
    end

    test "handles many sequential calls" do
      vec = for _ <- 1..768, do: :rand.uniform()

      # 1000 calls should not cause memory issues
      for _ <- 1..1000 do
        Math.cosine_similarity(vec, vec)
      end

      # If we get here, no crash
      assert true
    end

    test "handles concurrent calls" do
      vec = for _ <- 1..768, do: :rand.uniform()

      tasks =
        for _ <- 1..50 do
          Task.async(fn ->
            for _ <- 1..50 do
              Math.cosine_similarity(vec, vec)
            end
          end)
        end

      # All should complete without crash
      Task.await_many(tasks, 30_000)
      assert true
    end
  end

  # ===========================================================================
  # Numerical Precision Tests
  # ===========================================================================

  describe "numerical precision" do
    test "maintains precision with normalized vectors" do
      # Pre-normalized vectors should give exact results
      a = [1.0, 0.0, 0.0]
      b = [0.707106781, 0.707106781, 0.0]

      {:ok, sim} = Math.cosine_similarity(a, b)

      # cos(45°) ≈ 0.707
      assert_in_delta sim, 0.707106781, 0.001
    end

    test "handles vectors with all same values" do
      a = List.duplicate(0.5, 100)
      b = List.duplicate(0.5, 100)

      {:ok, sim} = Math.cosine_similarity(a, b)

      assert_in_delta sim, 1.0, 0.0001
    end

    test "handles vectors with alternating signs" do
      a = for i <- 1..100, do: if(rem(i, 2) == 0, do: 1.0, else: -1.0)
      b = for i <- 1..100, do: if(rem(i, 2) == 0, do: 1.0, else: -1.0)

      {:ok, sim} = Math.cosine_similarity(a, b)

      assert_in_delta sim, 1.0, 0.0001
    end
  end
end
