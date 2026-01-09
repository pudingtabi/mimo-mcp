defmodule Mimo.Brain.VocabularyIndexTest do
  use Mimo.DataCase, async: false

  alias Mimo.Brain.{Engram, VocabularyIndex}
  alias Mimo.Repo

  @moduletag :vocabulary_index

  describe "available?/0" do
    test "returns true when FTS5 table exists" do
      assert VocabularyIndex.available?() == true
    end
  end

  describe "search/2" do
    setup do
      # Create test engrams with unique content
      test_id = System.unique_integer([:positive])

      {:ok, engram1} =
        Repo.insert(%Engram{
          content: "vocabulary_test_#{test_id}_authentication_login_user",
          category: "fact",
          importance: 0.7
        })

      {:ok, engram2} =
        Repo.insert(%Engram{
          content: "vocabulary_test_#{test_id}_authorization_permissions_role",
          category: "fact",
          importance: 0.6
        })

      {:ok, engram3} =
        Repo.insert(%Engram{
          content: "vocabulary_test_#{test_id}_database_query_optimization",
          category: "observation",
          importance: 0.8
        })

      on_exit(fn ->
        Repo.delete(engram1)
        Repo.delete(engram2)
        Repo.delete(engram3)
      end)

      %{engrams: [engram1, engram2, engram3], test_id: test_id}
    end

    test "finds memories by single term", %{test_id: test_id} do
      {:ok, results} =
        VocabularyIndex.search("vocabulary_test_#{test_id}_authentication", limit: 10)

      assert results != []
      {memory, score} = hd(results)
      assert memory.content =~ "authentication"
      assert score > 0 and score <= 1.0
    end

    test "finds memories with OR query", %{test_id: test_id} do
      {:ok, results} =
        VocabularyIndex.search(
          "vocabulary_test_#{test_id}_authentication OR vocabulary_test_#{test_id}_database",
          limit: 10
        )

      assert length(results) >= 2
    end

    test "returns empty list for no matches" do
      {:ok, results} = VocabularyIndex.search("xyznonexistent12345abcdef", limit: 10)
      assert results == []
    end

    test "respects limit option", %{test_id: test_id} do
      {:ok, results} = VocabularyIndex.search("vocabulary_test_#{test_id}", limit: 1)
      assert length(results) == 1
    end

    test "returns normalized BM25 scores between 0 and 1", %{test_id: test_id} do
      {:ok, results} = VocabularyIndex.search("vocabulary_test_#{test_id}", limit: 10)

      for {_memory, score} <- results do
        assert score >= 0.0 and score <= 1.0
      end
    end

    test "handles empty query gracefully" do
      {:ok, results} = VocabularyIndex.search("", limit: 10)
      assert results == []
    end

    test "handles query with only spaces" do
      {:ok, results} = VocabularyIndex.search("   ", limit: 10)
      assert results == []
    end
  end

  describe "special character handling" do
    test "handles quotes in query" do
      result = VocabularyIndex.search("test \"quoted\" query", limit: 5)
      assert {:ok, _} = result
    end

    test "handles single quotes" do
      result = VocabularyIndex.search("it's a user's thing", limit: 5)
      assert {:ok, _} = result
    end

    test "handles asterisks" do
      result = VocabularyIndex.search("test*query", limit: 5)
      assert {:ok, _} = result
    end

    test "handles parentheses" do
      result = VocabularyIndex.search("test(query)", limit: 5)
      assert {:ok, _} = result
    end

    test "handles colons" do
      result = VocabularyIndex.search("column:value", limit: 5)
      assert {:ok, _} = result
    end

    test "handles carets" do
      result = VocabularyIndex.search("boost^2", limit: 5)
      assert {:ok, _} = result
    end

    test "handles backslashes" do
      result = VocabularyIndex.search("path\\to\\file", limit: 5)
      assert {:ok, _} = result
    end

    test "handles mixed special characters" do
      result = VocabularyIndex.search("user*auth(login):test", limit: 5)
      assert {:ok, _} = result
    end
  end

  describe "phrase_search/2" do
    setup do
      test_id = System.unique_integer([:positive])

      {:ok, engram} =
        Repo.insert(%Engram{
          content: "phrase_test_#{test_id} the quick brown fox jumps over",
          category: "fact",
          importance: 0.5
        })

      on_exit(fn -> Repo.delete(engram) end)

      %{engram: engram, test_id: test_id}
    end

    test "finds exact phrase matches", %{test_id: test_id} do
      {:ok, results} =
        VocabularyIndex.phrase_search("phrase_test_#{test_id} the quick brown", limit: 10)

      assert results != []
    end

    test "handles empty phrase" do
      {:ok, results} = VocabularyIndex.phrase_search("", limit: 10)
      assert results == []
    end
  end

  describe "stats/0" do
    test "returns FTS index statistics" do
      {:ok, stats} = VocabularyIndex.stats()

      assert is_map(stats)
      assert Map.has_key?(stats, :fts5_count)
      assert Map.has_key?(stats, :engram_count)
      assert Map.has_key?(stats, :in_sync)
      assert Map.has_key?(stats, :available)
      assert is_integer(stats.fts5_count)
      assert is_integer(stats.engram_count)
    end

    test "in_sync indicates sync health" do
      {:ok, stats} = VocabularyIndex.stats()
      assert is_boolean(stats.in_sync)
      assert stats.available == true
    end
  end

  describe "trigger synchronization" do
    test "INSERT trigger syncs new engrams to FTS" do
      test_id = System.unique_integer([:positive])
      unique_content = "insert_trigger_test_#{test_id}_unique_content"

      {:ok, engram} =
        Repo.insert(%Engram{
          content: unique_content,
          category: "fact",
          importance: 0.5
        })

      # Should be searchable immediately
      {:ok, results} = VocabularyIndex.search(unique_content, limit: 5)
      assert length(results) == 1

      Repo.delete(engram)
    end

    test "UPDATE trigger syncs modified engrams" do
      test_id = System.unique_integer([:positive])
      original_content = "update_trigger_test_#{test_id}_original"
      updated_content = "update_trigger_test_#{test_id}_modified"

      {:ok, engram} =
        Repo.insert(%Engram{
          content: original_content,
          category: "fact",
          importance: 0.5
        })

      # Update the engram
      {:ok, updated_engram} =
        engram
        |> Ecto.Changeset.change(%{content: updated_content})
        |> Repo.update()

      # Old content should not be found
      {:ok, old_results} = VocabularyIndex.search(original_content, limit: 5)
      assert Enum.empty?(old_results)

      # New content should be found
      {:ok, new_results} = VocabularyIndex.search(updated_content, limit: 5)
      assert length(new_results) == 1

      Repo.delete(updated_engram)
    end

    test "DELETE trigger removes engrams from FTS" do
      test_id = System.unique_integer([:positive])
      unique_content = "delete_trigger_test_#{test_id}_unique"

      {:ok, engram} =
        Repo.insert(%Engram{
          content: unique_content,
          category: "fact",
          importance: 0.5
        })

      # Verify it exists
      {:ok, before_results} = VocabularyIndex.search(unique_content, limit: 5)
      assert length(before_results) == 1

      # Delete it
      Repo.delete(engram)

      # Should no longer be found
      {:ok, after_results} = VocabularyIndex.search(unique_content, limit: 5)
      assert Enum.empty?(after_results)
    end
  end

  describe "normalize_bm25/1" do
    test "converts negative BM25 scores to 0-1 range" do
      # BM25 scores from SQLite are negative (lower = better)
      assert VocabularyIndex.normalize_bm25(-10.0) > 0.9
      assert VocabularyIndex.normalize_bm25(-1.0) > 0.5
      assert VocabularyIndex.normalize_bm25(0.0) == 0.5
      assert VocabularyIndex.normalize_bm25(10.0) < 0.1
    end

    test "handles edge cases" do
      # Very large negative (excellent match)
      score = VocabularyIndex.normalize_bm25(-100.0)
      assert score > 0.99

      # Positive score (poor match)
      score = VocabularyIndex.normalize_bm25(100.0)
      assert score < 0.01
    end
  end
end
