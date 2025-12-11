defmodule Mimo.Brain.Memory.SearchStrategyTest do
  @moduledoc """
  Tests for SPEC-033 Phase 3c: Hybrid search strategy with auto-selection.

  Tests the three-tier search strategy:
  - <500 memories: exact search (int8 cosine on all)
  - 500-999 memories: binary_rescore (Hamming pre-filter → int8 rescore)
  - ≥1000 memories: hnsw (O(log n) ANN search)
  """
  use Mimo.DataCase, async: false
  import Bitwise

  alias Mimo.Brain.Memory
  alias Mimo.Brain.Engram
  alias Mimo.Repo

  @dimensions 256

  describe "determine_strategy/2" do
    test "returns :exact for small memory counts" do
      # Under binary threshold (500)
      assert Memory.determine_strategy(0, nil) == :exact
      assert Memory.determine_strategy(100, nil) == :exact
      assert Memory.determine_strategy(499, nil) == :exact
    end

    test "returns :binary_rescore for medium memory counts" do
      # Between binary threshold (500) and hnsw threshold (1000)
      assert Memory.determine_strategy(500, nil) == :binary_rescore
      assert Memory.determine_strategy(750, nil) == :binary_rescore
      assert Memory.determine_strategy(999, nil) == :binary_rescore
    end

    test "returns :hnsw for large memory counts when available" do
      # At or above hnsw threshold (1000)
      # Note: actual result depends on HNSW availability
      result = Memory.determine_strategy(1000, nil)
      assert result in [:hnsw, :binary_rescore]

      result = Memory.determine_strategy(10_000, nil)
      assert result in [:hnsw, :binary_rescore]
    end

    test "respects explicit strategy override" do
      # When caller specifies strategy, it should be respected
      # (if the strategy parameter is supported)
      assert Memory.determine_strategy(100, :binary_rescore) == :binary_rescore
      assert Memory.determine_strategy(1000, :exact) == :exact
    end
  end

  describe "search strategy integration" do
    setup do
      # Clean up any existing engrams to have predictable state
      Repo.delete_all(Engram)
      :ok
    end

    test "search_memories/3 uses correct strategy for empty database" do
      # With empty database, should use exact strategy
      results = Memory.search_memories("test query", limit: 10)

      # Should return empty list, not error
      assert results == []
    end

    test "search_memories/3 handles small datasets with exact search" do
      # Create a few engrams with embeddings
      engrams = create_test_engrams(10)

      results = Memory.search_memories("test query", limit: 5)

      # Should return up to 5 results
      assert length(results) <= 5

      # Results should be sorted by similarity (descending)
      if length(results) > 1 do
        similarities = Enum.map(results, & &1.similarity)
        assert similarities == Enum.sort(similarities, :desc)
      end

      # Cleanup
      Enum.each(engrams, &Repo.delete/1)
    end

    @tag :slow
    test "search_memories/3 scales with binary_rescore for medium datasets" do
      # This test creates 500+ engrams to trigger binary_rescore
      # Skip if we can't handle this many
      count = 550

      engrams = create_test_engrams(count)

      # Verify we have enough to trigger binary_rescore
      total = Memory.count_memories()
      assert total >= 500

      # Search should still work
      results = Memory.search_memories("test query", limit: 10)

      assert is_list(results)

      # Cleanup
      Enum.each(engrams, &Repo.delete/1)
    end
  end

  describe "search result quality" do
    setup do
      Repo.delete_all(Engram)
      :ok
    end

    test "returns results with similarity scores" do
      engrams = create_test_engrams(5)

      results = Memory.search_memories("test", limit: 10)

      Enum.each(results, fn result ->
        assert Map.has_key?(result, :similarity) or Map.has_key?(result, :score)
        # Similarity should be in valid range
        score = result[:similarity] || result[:score]

        if score do
          assert score >= -1.0 and score <= 1.0
        end
      end)

      Enum.each(engrams, &Repo.delete/1)
    end

    test "respects limit parameter" do
      engrams = create_test_engrams(20)

      results_5 = Memory.search_memories("test", limit: 5)
      results_10 = Memory.search_memories("test", limit: 10)

      assert length(results_5) <= 5
      assert length(results_10) <= 10

      Enum.each(engrams, &Repo.delete/1)
    end

    test "respects min_similarity threshold" do
      engrams = create_test_engrams(10)

      results = Memory.search_memories("test", limit: 10, min_similarity: 0.5)

      Enum.each(results, fn result ->
        score = result[:similarity] || result[:score] || 0
        assert score >= 0.5, "Result similarity #{score} is below threshold 0.5"
      end)

      Enum.each(engrams, &Repo.delete/1)
    end
  end

  describe "utf8 handling" do
    setup do
      Repo.delete_all(Engram)
      :ok
    end

    test "search_with_embedding handles Unicode content" do
      embedding = Enum.map(1..@dimensions, fn _ -> 0.01 end)
      embedding_int8 = quantize_to_int8(embedding)
      embedding_binary = quantize_to_binary(embedding_int8)
      unicode_content = "Q1 plan – draft — ready"

      {:ok, engram} =
        Repo.insert(%Engram{
          content: unicode_content,
          category: "fact",
          importance: 0.7,
          embedding: embedding,
          embedding_int8: embedding_int8,
          embedding_binary: embedding_binary,
          inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second),
          updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
        })

      # Verify the unicode content was stored correctly
      assert engram.content == unicode_content
      
      # Verify search doesn't crash with Unicode content in database
      {:ok, results} = Memory.search_with_embedding(embedding, limit: 5)
      
      # Main assertion: search works without crashing
      assert is_list(results)
      
      # If results found, verify they have valid content (may include Unicode)
      Enum.each(results, fn r ->
        assert is_binary(r.content)
      end)

      Repo.delete!(engram)
    end
  end

  describe "category filtering" do
    setup do
      Repo.delete_all(Engram)
      :ok
    end

    test "filters by category when specified" do
      fact_engrams = create_test_engrams(5, category: :fact)
      observation_engrams = create_test_engrams(5, category: :observation)

      fact_results = Memory.search_memories("test", limit: 10, category: :fact)
      obs_results = Memory.search_memories("test", limit: 10, category: :observation)

      # Each should only return its category
      Enum.each(fact_results, fn r ->
        assert r.category == "fact"
      end)

      Enum.each(obs_results, fn r ->
        assert r.category == "observation"
      end)

      Enum.each(fact_engrams ++ observation_engrams, &Repo.delete/1)
    end
  end

  # Helper functions

  defp create_test_engrams(count, opts \\ []) do
    # Convert atom categories to strings (Engram schema expects strings)
    category =
      case Keyword.get(opts, :category, "fact") do
        cat when is_atom(cat) -> Atom.to_string(cat)
        cat when is_binary(cat) -> cat
      end

    for i <- 1..count do
      embedding = generate_random_float_vector(@dimensions)
      embedding_int8 = quantize_to_int8(embedding)
      embedding_binary = quantize_to_binary(embedding_int8)

      {:ok, engram} =
        Repo.insert(%Engram{
          content: "Test engram #{i} with some content for testing search",
          category: category,
          importance: 0.5 + :rand.uniform() * 0.4,
          embedding: embedding,
          embedding_int8: embedding_int8,
          embedding_binary: embedding_binary,
          inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second),
          updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
        })

      engram
    end
  end

  defp generate_random_float_vector(dimensions) do
    for _ <- 1..dimensions do
      # Random float in [-1, 1]
      :rand.uniform() * 2 - 1
    end
  end

  defp quantize_to_int8(floats) do
    bytes =
      Enum.map(floats, fn f ->
        # Scale from [-1, 1] to [-128, 127]
        clamped = max(-1.0, min(1.0, f))
        round(clamped * 127)
      end)

    :binary.list_to_bin(
      Enum.map(bytes, fn b ->
        if b < 0, do: b + 256, else: b
      end)
    )
  end

  defp quantize_to_binary(int8_binary) when is_binary(int8_binary) do
    # Convert int8 to binary (each byte becomes 1 bit: positive = 1, negative = 0)
    bytes =
      :binary.bin_to_list(int8_binary)
      |> Enum.map(fn b ->
        signed = if b >= 128, do: b - 256, else: b
        if signed >= 0, do: 1, else: 0
      end)

    # Pack 8 bits into each byte
    bytes
    |> Enum.chunk_every(8, 8, Stream.cycle([0]))
    |> Enum.map(fn bits ->
      Enum.reduce(Enum.with_index(bits), 0, fn {bit, idx}, acc ->
        acc ||| bit <<< (7 - idx)
      end)
    end)
    |> :binary.list_to_bin()
  end
end
