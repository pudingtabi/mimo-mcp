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
        [1.0, 0.0, 0.0],  # Identical
        [0.0, 1.0, 0.0],  # Orthogonal
        [0.707, 0.707, 0.0]  # 45 degrees
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
        [0.5, 0.5, 0.0],   # Index 0
        [1.0, 0.0, 0.0],   # Index 1 - most similar
        [0.0, 1.0, 0.0],   # Index 2 - orthogonal
        [0.9, 0.1, 0.0],   # Index 3 - very similar
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
      vec = [3.0, 4.0]  # Length = 5
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
end
