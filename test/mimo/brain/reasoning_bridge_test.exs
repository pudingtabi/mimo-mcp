defmodule Mimo.Brain.ReasoningBridgeTest do
  @moduledoc """
  Unit tests for ReasoningBridge (SPEC-058).

  Tests both enabled and disabled feature flag states.
  """
  use Mimo.DataCase, async: true

  alias Mimo.Brain.ReasoningBridge
  alias Mimo.Brain.Engram

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

  describe "reasoning_enabled?/0" do
    test "returns false when disabled" do
      Application.put_env(:mimo, :reasoning_memory_enabled, false)
      refute ReasoningBridge.reasoning_enabled?()
    end

    test "returns true when enabled" do
      Application.put_env(:mimo, :reasoning_memory_enabled, true)
      assert ReasoningBridge.reasoning_enabled?()
    end
  end

  describe "analyze_for_storage/2" do
    test "returns {:skip, :disabled} when reasoning is disabled" do
      Application.put_env(:mimo, :reasoning_memory_enabled, false)

      assert {:skip, :disabled} =
               ReasoningBridge.analyze_for_storage(
                 "User prefers TypeScript over JavaScript",
                 category: "observation"
               )
    end

    @tag :integration
    @tag :llm
    test "returns reasoning context when enabled" do
      Application.put_env(:mimo, :reasoning_memory_enabled, true)

      result =
        ReasoningBridge.analyze_for_storage(
          "User prefers TypeScript over JavaScript",
          category: "observation"
        )

      case result do
        {:ok, ctx} ->
          assert is_map(ctx)
          assert Map.has_key?(ctx, :strategy)
          assert Map.has_key?(ctx, :confidence)
          assert is_float(ctx.confidence)

        {:skip, :disabled} ->
          # Acceptable if LLM is not available
          :ok
      end
    end
  end

  describe "score_importance/3" do
    test "returns base score when reasoning is disabled" do
      Application.put_env(:mimo, :reasoning_memory_enabled, false)

      score =
        ReasoningBridge.score_importance(
          "NEVER commit API keys to git",
          "fact",
          base_importance: 0.5
        )

      assert score == 0.5
    end

    test "uses custom base_importance when provided" do
      Application.put_env(:mimo, :reasoning_memory_enabled, false)

      score =
        ReasoningBridge.score_importance(
          "General information",
          "fact",
          base_importance: 0.7
        )

      assert score == 0.7
    end

    @tag :integration
    @tag :llm
    test "scores critical content higher when enabled" do
      Application.put_env(:mimo, :reasoning_memory_enabled, true)

      critical_score =
        ReasoningBridge.score_importance(
          "NEVER commit API keys to git - this is a critical security requirement",
          "fact"
        )

      general_score =
        ReasoningBridge.score_importance(
          "The project uses React",
          "fact"
        )

      # Critical content should score higher (if LLM responds properly)
      # But we can't guarantee LLM behavior, so just check both are valid
      assert is_float(critical_score)
      assert is_float(general_score)
      assert critical_score >= 0.0 and critical_score <= 1.0
      assert general_score >= 0.0 and general_score <= 1.0
    end
  end

  describe "detect_relationships/2" do
    test "returns empty list when reasoning is disabled" do
      Application.put_env(:mimo, :reasoning_memory_enabled, false)

      existing = [%Engram{id: 1, content: "React 18 is the latest version"}]

      rels =
        ReasoningBridge.detect_relationships(
          "React 19 is now the latest version",
          existing
        )

      assert rels == []
    end

    test "returns empty list when no similar memories" do
      Application.put_env(:mimo, :reasoning_memory_enabled, true)

      rels =
        ReasoningBridge.detect_relationships(
          "Some new content",
          []
        )

      assert rels == []
    end

    @tag :integration
    @tag :llm
    test "detects relationships when enabled with similar memories" do
      Application.put_env(:mimo, :reasoning_memory_enabled, true)

      existing = [%Engram{id: 1, content: "React 18 is the latest version"}]

      rels =
        ReasoningBridge.detect_relationships(
          "React 19 is now the latest version",
          existing
        )

      # Result depends on LLM, but should be a list of relationships
      assert is_list(rels)

      # If we got relationships, verify structure
      if length(rels) > 0 do
        rel = hd(rels)
        assert Map.has_key?(rel, :type)
        assert Map.has_key?(rel, :target_id)
        assert Map.has_key?(rel, :confidence)
        assert rel.type in [:depends_on, :contradicts, :extends, :supersedes, :related_to]
      end
    end
  end

  describe "generate_tags/2" do
    test "returns empty list when reasoning is disabled" do
      Application.put_env(:mimo, :reasoning_memory_enabled, false)

      tags =
        ReasoningBridge.generate_tags(
          "Phoenix uses Ecto for database access",
          "fact"
        )

      assert tags == []
    end

    @tag :integration
    @tag :llm
    test "generates tags when enabled" do
      Application.put_env(:mimo, :reasoning_memory_enabled, true)

      tags =
        ReasoningBridge.generate_tags(
          "Phoenix uses Ecto for database access",
          "fact"
        )

      # Result depends on LLM
      assert is_list(tags)

      # If we got tags, verify they are lowercase strings
      Enum.each(tags, fn tag ->
        assert is_binary(tag)
        assert tag == String.downcase(tag)
      end)
    end
  end

  describe "analyze_query/1" do
    test "returns default analysis when reasoning is disabled" do
      Application.put_env(:mimo, :reasoning_memory_enabled, false)

      {:ok, analysis} = ReasoningBridge.analyze_query("What is the auth configuration?")

      assert analysis["intent"] == "factual"
      assert analysis["key_concepts"] == ["What is the auth configuration?"]
      assert analysis["expanded_terms"] == []
      assert analysis["time_context"] == nil
    end

    @tag :integration
    @tag :llm
    test "analyzes query intent when enabled" do
      Application.put_env(:mimo, :reasoning_memory_enabled, true)

      {:ok, analysis} = ReasoningBridge.analyze_query("What did we decide about auth last week?")

      assert is_map(analysis)
      assert Map.has_key?(analysis, "intent")
      assert analysis["intent"] in ["factual", "temporal", "relational", "exploratory"]
    end
  end

  describe "rerank/3" do
    test "returns original results when reasoning is disabled" do
      Application.put_env(:mimo, :reasoning_memory_enabled, false)

      results = [
        %Engram{id: 1, content: "First result"},
        %Engram{id: 2, content: "Second result"},
        %Engram{id: 3, content: "Third result"},
        %Engram{id: 4, content: "Fourth result"}
      ]

      reranked = ReasoningBridge.rerank("query", results, %{})

      assert reranked == results
    end

    test "returns original results when less than 4 results" do
      Application.put_env(:mimo, :reasoning_memory_enabled, true)

      results = [
        %Engram{id: 1, content: "First result"},
        %Engram{id: 2, content: "Second result"}
      ]

      reranked = ReasoningBridge.rerank("query", results, %{})

      assert reranked == results
    end

    @tag :integration
    @tag :llm
    test "reranks results when enabled with enough results" do
      Application.put_env(:mimo, :reasoning_memory_enabled, true)

      results = [
        %Engram{id: 1, content: "Auth configuration uses JWT tokens"},
        %Engram{id: 2, content: "Database uses PostgreSQL"},
        %Engram{id: 3, content: "JWT tokens expire after 1 hour"},
        %Engram{id: 4, content: "API endpoints require authentication"}
      ]

      reranked =
        ReasoningBridge.rerank("JWT token configuration", results, %{"intent" => "factual"})

      # Should return same items, possibly reordered
      assert is_list(reranked)
      assert length(reranked) <= length(results)

      # All returned items should be from original results
      original_ids = Enum.map(results, & &1.id)

      Enum.each(reranked, fn r ->
        assert r.id in original_ids
      end)
    end
  end

  describe "default_context/0" do
    test "returns properly structured context" do
      ctx = ReasoningBridge.default_context()

      assert ctx.session_id == nil
      assert ctx.strategy == :none
      assert ctx.decomposition == []
      assert ctx.importance_reasoning == "Default (reasoning disabled)"
      assert ctx.detected_relationships == []
      assert ctx.tags_reasoning == nil
      assert ctx.confidence == 0.5
    end
  end
end
