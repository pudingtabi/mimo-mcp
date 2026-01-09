defmodule Mimo.Context.CompactorTest do
  @moduledoc """
  Tests for SPEC-2026-002: Context Compaction

  Tests both heuristic detection and compaction logic.
  LLM tests are tagged :integration to avoid API calls in regular test runs.
  """

  use ExUnit.Case, async: true

  alias Mimo.Context.Compactor

  describe "detect_intent/1 - heuristic detection" do
    test "detects file mentions" do
      messages = [
        "I need to edit lib/auth/session.ex",
        "Also check the lib/auth/token.ex file"
      ]

      result = Compactor.detect_intent(messages)

      assert "lib/auth/session.ex" in result.primary_files or
               "auth/session.ex" in result.primary_files

      assert result.source in [:heuristic, :heuristic_fallback, :llm]
    end

    test "detects auth-related intent" do
      messages = [
        "I need to implement user authentication",
        "The login flow should use JWT tokens",
        "Check password validation"
      ]

      result = Compactor.detect_intent(messages)

      assert :auth == result.intent_type or result.intent_type in [:auth, :security]
      assert result.confidence > 0
    end

    test "detects testing-related intent" do
      messages = [
        "Let's write some tests",
        "Add assertions for the edge cases",
        "Mock the external API"
      ]

      result = Compactor.detect_intent(messages)

      assert result.intent_type == :testing
      assert "test" in result.keywords or "mock" in result.keywords
    end

    test "detects database-related intent" do
      messages = [
        "Need to add a new migration",
        "The schema should have a users table",
        "Fix the Ecto query"
      ]

      result = Compactor.detect_intent(messages)

      assert result.intent_type == :database
    end

    test "returns general intent for vague messages" do
      messages = ["Hello", "How are you?"]

      result = Compactor.detect_intent(messages)

      assert result.intent_type == :general
      assert result.confidence < 0.5
    end

    test "handles empty messages" do
      result = Compactor.detect_intent([])

      assert result.primary_files == []
      assert result.keywords == []
    end

    test "handles non-list input" do
      result = Compactor.detect_intent("not a list")

      assert result.confidence == 0.0
    end
  end

  describe "compact/2" do
    test "keeps relevant messages full" do
      intent = %{
        primary_files: ["auth.ex"],
        keywords: ["login", "token"],
        intent_type: :auth,
        confidence: 0.8
      }

      messages = [
        # relevant
        "Implement login with token validation",
        # irrelevant, long
        String.duplicate("x", 600)
      ]

      result = Compactor.compact(messages, intent)

      assert Enum.at(result, 0) == "Implement login with token validation"
      assert String.contains?(Enum.at(result, 1), "[compacted:")
    end

    test "truncates long irrelevant messages" do
      intent = %{
        primary_files: ["specific.ex"],
        keywords: ["specific"],
        intent_type: :general,
        confidence: 0.5
      }

      long_msg = String.duplicate("unrelated content ", 50)
      messages = [long_msg]

      result = Compactor.compact(messages, intent)
      compacted = Enum.at(result, 0)

      assert String.length(compacted) < String.length(long_msg)
      assert String.contains?(compacted, "[compacted:")
    end

    test "keeps short messages even if irrelevant" do
      intent = %{
        primary_files: ["other.ex"],
        keywords: ["other"],
        intent_type: :general,
        confidence: 0.5
      }

      messages = ["Short message"]
      result = Compactor.compact(messages, intent)

      assert result == messages
    end

    test "handles map messages with content key" do
      intent = %{
        primary_files: ["file.ex"],
        keywords: ["keyword"],
        intent_type: :general,
        confidence: 0.5
      }

      long_content = String.duplicate("irrelevant ", 100)
      messages = [%{role: "user", content: long_content}]

      result = Compactor.compact(messages, intent)
      compacted = Enum.at(result, 0)

      assert is_map(compacted)
      assert String.contains?(compacted.content, "[compacted:")
    end
  end

  describe "compact_with_intent/1" do
    test "returns both compacted messages and intent" do
      messages = [
        "Let's fix the authentication bug in lib/auth.ex",
        "The login endpoint is broken"
      ]

      {compacted, intent} = Compactor.compact_with_intent(messages)

      assert is_list(compacted)
      assert length(compacted) == 2
      assert is_map(intent)
      assert Map.has_key?(intent, :intent_type)
      assert Map.has_key?(intent, :confidence)
    end
  end
end
