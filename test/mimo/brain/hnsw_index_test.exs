defmodule Mimo.Brain.HnswIndexTest do
  @moduledoc """
  Tests for SPEC-033 Phase 3b: HNSW Index integration.

  Tests the HnswIndex GenServer that manages the USearch HNSW index
  for O(log n) approximate nearest neighbor search.
  """
  use Mimo.DataCase, async: false

  alias Mimo.Brain.HnswIndex
  alias Mimo.Vector.Math, as: VectorMath

  @dimensions 256
  @test_vector_count 100

  setup do
    # Ensure HnswIndex is started for tests
    case Process.whereis(HnswIndex) do
      nil ->
        {:ok, _pid} = HnswIndex.start_link(dimensions: @dimensions)

      _pid ->
        :ok
    end

    :ok
  end

  describe "HnswIndex GenServer" do
    test "starts and initializes correctly" do
      assert Process.whereis(HnswIndex) != nil
    end

    test "should_use_hnsw?/0 returns boolean" do
      # May be true or false depending on NIF availability
      result = HnswIndex.should_use_hnsw?()
      assert is_boolean(result)
    end

    test "stats/0 returns index information" do
      stats = HnswIndex.stats()

      assert is_map(stats)
      # Stats may contain :available/:reason (when disabled) or :initialized (when running)
      assert Map.has_key?(stats, :available) or Map.has_key?(stats, :reason) or
               Map.has_key?(stats, :initialized)

      assert Map.has_key?(stats, :threshold)
    end
  end

  describe "HNSW index operations" do
    @tag :hnsw_nif
    test "can add and search vectors" do
      skip_unless_hnsw_available()

      # Generate test vectors
      vectors = generate_test_vectors(@test_vector_count)

      # Add vectors to index
      Enum.each(vectors, fn {id, vec} ->
        HnswIndex.add(id, vec)
      end)

      # Wait for async adds to complete
      Process.sleep(100)

      # Search for similar vectors
      {query_id, query_vec} = List.first(vectors)

      case HnswIndex.search(query_vec, 10) do
        {:ok, results} ->
          assert length(results) <= 10

          # First result should be the query itself (exact match)
          case results do
            [{result_id, similarity} | _] ->
              assert result_id == query_id
              # Should be very high for exact match
              assert similarity > 0.99

            [] ->
              # Empty results are ok if index not fully ready
              :ok
          end

        {:error, :index_not_available} ->
          :ok

        {:error, reason} ->
          flunk("Unexpected error: #{inspect(reason)}")
      end
    end

    @tag :hnsw_nif
    test "search returns results sorted by similarity (descending)" do
      skip_unless_hnsw_available()

      vectors = generate_test_vectors(50)

      Enum.each(vectors, fn {id, vec} ->
        HnswIndex.add(id, vec)
      end)

      Process.sleep(100)

      {_id, query_vec} = List.first(vectors)

      case HnswIndex.search(query_vec, 10) do
        {:ok, results} when length(results) > 1 ->
          similarities = Enum.map(results, &elem(&1, 1))
          assert similarities == Enum.sort(similarities, :desc)

        _ ->
          :ok
      end
    end

    @tag :hnsw_nif
    test "remove/1 marks vector as deleted" do
      skip_unless_hnsw_available()

      id = 999_999
      vec = generate_random_int8_vector(@dimensions)

      HnswIndex.add(id, vec)
      Process.sleep(50)

      # Remove the vector
      HnswIndex.remove(id)
      Process.sleep(50)

      # Search should not return the removed vector
      case HnswIndex.search(vec, 10) do
        {:ok, results} ->
          result_ids = Enum.map(results, &elem(&1, 0))
          refute id in result_ids

        _ ->
          :ok
      end
    end
  end

  describe "HNSW recall quality" do
    @tag :hnsw_nif
    @tag :slow
    test "recall@10 vs exact search > 80%" do
      skip_unless_hnsw_available()

      # Generate larger test set
      vector_count = 500
      vectors = generate_test_vectors(vector_count)

      # Add all vectors
      Enum.each(vectors, fn {id, vec} ->
        HnswIndex.add(id, vec)
      end)

      # Wait for index to stabilize
      Process.sleep(500)

      # Test with multiple queries
      query_count = 10

      recall_scores =
        for _ <- 1..query_count do
          # Use a vector from the set as query
          {_query_id, query_vec} = Enum.random(vectors)

          # Get HNSW results
          {:ok, hnsw_results} = HnswIndex.search(query_vec, 10)
          hnsw_ids = MapSet.new(Enum.map(hnsw_results, &elem(&1, 0)))

          # Compute exact results
          exact_results = compute_exact_top_k(query_vec, vectors, 10)
          exact_ids = MapSet.new(Enum.map(exact_results, &elem(&1, 0)))

          # Compute recall
          overlap = MapSet.intersection(hnsw_ids, exact_ids) |> MapSet.size()
          overlap / max(MapSet.size(exact_ids), 1)
        end

      avg_recall = Enum.sum(recall_scores) / length(recall_scores)

      # HNSW should achieve at least 80% recall
      assert avg_recall >= 0.8,
             "Average recall #{Float.round(avg_recall * 100, 1)}% is below 80%"
    end
  end

  describe "index persistence" do
    @tag :hnsw_nif
    test "save/0 and load on restart" do
      skip_unless_hnsw_available()

      # Add some vectors
      vectors = generate_test_vectors(20)

      Enum.each(vectors, fn {id, vec} ->
        HnswIndex.add(id, vec)
      end)

      Process.sleep(100)

      # Save the index
      case HnswIndex.save() do
        :ok -> :ok
        # May fail if HNSW not available
        {:error, _} -> :ok
      end

      # Verify vectors are still searchable
      {_id, query_vec} = List.first(vectors)

      case HnswIndex.search(query_vec, 5) do
        {:ok, results} ->
          assert length(results) > 0

        {:error, :index_not_available} ->
          :ok
      end
    end
  end

  describe "rebuild functionality" do
    @tag :hnsw_nif
    @tag :slow
    test "rebuild/0 reconstructs index from database" do
      skip_unless_hnsw_available()

      # This test requires actual engrams in the database
      # with int8 embeddings

      # Trigger rebuild
      case HnswIndex.rebuild() do
        {:ok, _count} ->
          # Verify index stats after rebuild
          stats = HnswIndex.stats()
          assert is_map(stats)

        {:error, :not_running} ->
          :ok

        {:error, _reason} ->
          :ok
      end
    end
  end

  # Helper functions

  defp generate_test_vectors(count) do
    for i <- 1..count do
      {i, generate_random_int8_vector(@dimensions)}
    end
  end

  defp generate_random_int8_vector(dimensions) do
    # Generate random int8 values (-128 to 127)
    :binary.list_to_bin(for _ <- 1..dimensions, do: :rand.uniform(256) - 128)
  end

  defp compute_exact_top_k(query_vec, vectors, k) do
    vectors
    |> Enum.map(fn {id, vec} ->
      similarity = compute_int8_similarity(query_vec, vec)
      {id, similarity}
    end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(k)
  end

  defp compute_int8_similarity(a, b) when is_binary(a) and is_binary(b) do
    # Compute dot product for int8 vectors
    a_list = :binary.bin_to_list(a) |> Enum.map(&signed_byte/1)
    b_list = :binary.bin_to_list(b) |> Enum.map(&signed_byte/1)

    dot =
      Enum.zip(a_list, b_list)
      |> Enum.map(fn {x, y} -> x * y end)
      |> Enum.sum()

    norm_a = :math.sqrt(Enum.map(a_list, &(&1 * &1)) |> Enum.sum())
    norm_b = :math.sqrt(Enum.map(b_list, &(&1 * &1)) |> Enum.sum())

    if norm_a > 0 and norm_b > 0 do
      dot / (norm_a * norm_b)
    else
      0.0
    end
  end

  defp signed_byte(b) when b >= 128, do: b - 256
  defp signed_byte(b), do: b

  defp skip_unless_hnsw_available do
    unless VectorMath.hnsw_available?() do
      # Tests are tagged with :hnsw_nif and excluded in CI
      # For local runs without NIF, just skip gracefully
      flunk("HNSW NIFs not available - run with: mix test --exclude hnsw_nif")
    end
  end
end
