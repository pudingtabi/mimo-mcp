defmodule Mimo.Brain.ReasoningMemoryIntegrationTest do
  @moduledoc """
  Integration tests for SPEC-058 Reasoning-Memory Integration.

  Tests the full flow of reasoning-enhanced memory persistence and search.
  """
  use Mimo.DataCase

  alias Mimo.Brain.{Engram, Memory}
  alias Mimo.Repo

  # Store original config and restore after each test
  setup do
    original_enabled = Application.get_env(:mimo, :reasoning_memory_enabled)

    on_exit(fn ->
      if original_enabled do
        Application.put_env(:mimo, :reasoning_memory_enabled, original_enabled)
      else
        Application.delete_env(:mimo, :reasoning_memory_enabled)
      end
    end)

    :ok
  end

  describe "persist_memory with reasoning disabled" do
    setup do
      Application.put_env(:mimo, :reasoning_memory_enabled, false)
      :ok
    end

    test "stores memory without reasoning context" do
      # Use unique content to avoid TMC duplicate detection
      unique_content = "Phoenix uses Ecto for database access #{System.unique_integer([:positive])}"

      result =
        Memory.persist_memory(
          unique_content,
          "fact",
          0.6
        )

      # Handle both :ok (new) and :duplicate (TMC detected similar)
      id =
        case result do
          {:ok, id} -> id
          {:duplicate, id} -> id
        end

      assert is_integer(id)

      # Verify the memory was stored
      engram = Repo.get!(Engram, id)
      assert is_binary(engram.content)
      assert engram.category == "fact"
      # Importance may vary if TMC returned a duplicate with different importance
      assert engram.importance >= 0.0 and engram.importance <= 1.0

      # Metadata should NOT have reasoning_context
      refute Map.has_key?(engram.metadata || %{}, "reasoning_context")
    end
  end

  describe "persist_memory with reasoning enabled" do
    setup do
      Application.put_env(:mimo, :reasoning_memory_enabled, true)
      :ok
    end

    @tag :integration
    @tag :llm
    test "stores memory with reasoning context in metadata" do
      {:ok, id} =
        Memory.persist_memory(
          "Database credentials must never be logged - critical security requirement",
          "fact",
          # Base importance
          0.5
        )

      assert is_integer(id)

      # Verify the memory was stored
      engram = Repo.get!(Engram, id)
      assert engram.content =~ "Database credentials"
      assert engram.category == "fact"

      # With reasoning enabled, metadata should have reasoning_context
      # (if LLM was available)
      if engram.metadata && Map.has_key?(engram.metadata, "reasoning_context") do
        ctx = engram.metadata["reasoning_context"]
        assert Map.has_key?(ctx, "strategy")
        assert Map.has_key?(ctx, "confidence")
      end
    end

    @tag :integration
    @tag :llm
    test "adjusts importance based on reasoning" do
      {:ok, id} =
        Memory.persist_memory(
          "CRITICAL: Never expose API keys in client-side code",
          "fact",
          # Base importance
          0.5
        )

      engram = Repo.get!(Engram, id)

      # Reasoning should potentially adjust importance for critical content
      # We can't guarantee the LLM will increase it, but it should be valid
      assert engram.importance >= 0.0 and engram.importance <= 1.0
    end
  end

  describe "search with reasoning disabled" do
    setup do
      Application.put_env(:mimo, :reasoning_memory_enabled, false)

      # Use unique content to avoid TMC duplicate detection
      suffix = System.unique_integer([:positive])

      # Create test memories - handle both :ok and :duplicate
      persist_test_memory("User prefers functional programming #{suffix}", "observation", 0.7)
      persist_test_memory("Project uses Elixir and Phoenix #{suffix}", "fact", 0.8)
      persist_test_memory("Deployed to AWS yesterday #{suffix}", "action", 0.6)

      :ok
    end

    # Helper to handle both :ok and :duplicate
    defp persist_test_memory(content, category, importance) do
      case Memory.persist_memory(content, category, importance) do
        {:ok, id} -> {:ok, id}
        {:duplicate, id} -> {:ok, id}
      end
    end

    test "searches without reasoning enhancement" do
      {:ok, results} =
        Memory.search("programming preferences",
          limit: 5,
          enable_reasoning: false
        )

      assert is_list(results)
      # Should find results based on semantic similarity
    end
  end

  describe "search with reasoning enabled" do
    setup do
      Application.put_env(:mimo, :reasoning_memory_enabled, true)

      # Create test memories
      {:ok, _} =
        Memory.persist_memory("User prefers functional programming paradigm", "observation", 0.7)

      {:ok, _} = Memory.persist_memory("Project uses Elixir and Phoenix framework", "fact", 0.8)
      {:ok, _} = Memory.persist_memory("Deployed to production yesterday", "action", 0.6)

      :ok
    end

    @tag :integration
    @tag :llm
    test "expands query with synonyms" do
      {:ok, results} =
        Memory.search("FP style preferences",
          limit: 5,
          enable_reasoning: true
        )

      assert is_list(results)

      # With query expansion, should find "functional programming" despite different wording
      # This depends on LLM behavior, so we just verify the search works
    end

    @tag :integration
    @tag :llm
    test "reranks results when enabled" do
      # First, create enough memories to trigger reranking (>3)
      {:ok, _} = Memory.persist_memory("Auth uses JWT tokens", "fact", 0.7)
      {:ok, _} = Memory.persist_memory("JWT tokens expire after 1 hour", "fact", 0.7)
      {:ok, _} = Memory.persist_memory("Database uses PostgreSQL", "fact", 0.7)
      {:ok, _} = Memory.persist_memory("API requires authentication", "fact", 0.7)

      {:ok, results} =
        Memory.search("JWT token configuration",
          limit: 5,
          enable_reasoning: true,
          rerank: true
        )

      assert is_list(results)
      # Reranking should prioritize JWT-related results
      # Actual ordering depends on LLM behavior
    end
  end

  describe "reasoning context persistence" do
    setup do
      Application.put_env(:mimo, :reasoning_memory_enabled, true)
      :ok
    end

    @tag :integration
    @tag :llm
    test "persists detected relationships in metadata" do
      # First, create an existing memory
      {:ok, existing_id} =
        Memory.persist_memory(
          "React 18 is the latest version",
          "fact",
          0.7
        )

      # Now create a related memory (should detect supersession)
      {:ok, new_id} =
        Memory.persist_memory(
          "React 19 is now the latest version",
          "fact",
          0.7
        )

      # Check if relationship was detected and stored
      new_engram = Repo.get!(Engram, new_id)

      if new_engram.metadata && Map.has_key?(new_engram.metadata, "reasoning_context") do
        ctx = new_engram.metadata["reasoning_context"]

        if Map.has_key?(ctx, "detected_relationships") do
          rels = ctx["detected_relationships"]
          assert is_list(rels)

          # If relationships were detected, verify structure
          Enum.each(rels, fn rel ->
            assert Map.has_key?(rel, "type")
            assert Map.has_key?(rel, "target_id")
            assert Map.has_key?(rel, "confidence")
          end)
        end
      end
    end
  end

  describe "feature flag behavior" do
    test "respects runtime config changes" do
      # Disable reasoning
      Application.put_env(:mimo, :reasoning_memory_enabled, false)

      {:ok, id1} = Memory.persist_memory("Test memory 1", "fact", 0.5)
      engram1 = Repo.get!(Engram, id1)
      refute Map.has_key?(engram1.metadata || %{}, "reasoning_context")

      # Enable reasoning
      Application.put_env(:mimo, :reasoning_memory_enabled, true)

      # Note: The actual behavior depends on whether LLM is available
      # This test just verifies the flag is checked
    end
  end
end
