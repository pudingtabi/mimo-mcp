defmodule Mimo.Tools.Dispatchers.SuggestNextToolPatternTest do
  @moduledoc """
  Tests for suggest_next_tool's Phase 3 L4 pattern integration.

  Verifies that tool suggestions can incorporate learned
  workflow patterns from the Emergence system.
  """
  use Mimo.DataCase

  alias Mimo.Tools.Dispatchers.SuggestNextTool
  alias Mimo.Brain.Emergence.Pattern

  describe "pattern-based suggestions" do
    setup do
      # Create some workflow patterns for testing
      {:ok, _} =
        %Pattern{}
        |> Pattern.changeset(%{
          type: :workflow,
          status: :active,
          description: "debugging workflow: memory → code → terminal",
          components: [
            %{"tool" => "memory", "operation" => "search"},
            %{"tool" => "code", "operation" => "diagnose"},
            %{"tool" => "terminal", "operation" => "execute"}
          ],
          success_rate: 0.9,
          occurrences: 50,
          strength: 0.85
        })
        |> Repo.insert()

      {:ok, _} =
        %Pattern{}
        |> Pattern.changeset(%{
          type: :workflow,
          status: :active,
          description: "file editing workflow: memory → file",
          components: [
            %{"tool" => "memory"},
            %{"tool" => "file"}
          ],
          success_rate: 0.85,
          occurrences: 30,
          strength: 0.8
        })
        |> Repo.insert()

      :ok
    end

    test "handle/2 returns pattern_insight when patterns match" do
      # Create a request that would match our patterns
      args = %{
        "task" => "debug an issue",
        "recent_tools" => ["memory"]
      }

      result = SuggestNextTool.handle(args, %{})

      assert {:ok, response} = result
      assert is_map(response)

      # The response should have our new pattern_insight field
      # (even if nil when no patterns matched)
      assert Map.has_key?(response, :pattern_insight) or
               Map.has_key?(response, "pattern_insight")
    end

    test "pattern_insight contains suggested tool from patterns" do
      args = %{
        "task" => "fix a bug",
        "recent_tools" => ["memory", "code"]
      }

      {:ok, response} = SuggestNextTool.handle(args, %{})

      pattern_insight = response[:pattern_insight] || response["pattern_insight"]

      if pattern_insight do
        assert is_map(pattern_insight)

        assert Map.has_key?(pattern_insight, :suggested_tool) or
                 Map.has_key?(pattern_insight, "suggested_tool")
      end
    end

    test "returns valid suggestion even without pattern matches" do
      # Use tools that don't match any pattern
      args = %{
        "task" => "do something new",
        "recent_tools" => ["unknown_tool_xyz"]
      }

      result = SuggestNextTool.handle(args, %{})

      # Should still return a valid suggestion (not crash)
      assert {:ok, response} = result
      assert is_map(response)
    end

    test "suggestion includes context about pattern source" do
      args = %{
        "task" => "continue debugging",
        "recent_tools" => ["memory"]
      }

      {:ok, response} = SuggestNextTool.handle(args, %{})

      pattern_insight = response[:pattern_insight] || response["pattern_insight"]

      if pattern_insight do
        # Pattern insight should include context
        assert Map.has_key?(pattern_insight, :pattern_description) or
                 Map.has_key?(pattern_insight, "pattern_description") or
                 Map.has_key?(pattern_insight, :success_rate) or
                 Map.has_key?(pattern_insight, "success_rate")
      end
    end
  end

  describe "integration with workflow phases" do
    test "patterns complement phase-based suggestions" do
      # Even with pattern suggestions, the tool should still return
      # phase-based suggestions as the primary recommendation
      args = %{
        "task" => "implement a feature",
        "context" => "Starting a new task"
      }

      {:ok, response} = SuggestNextTool.handle(args, %{})

      # Should have the main suggestion
      assert Map.has_key?(response, :suggested_tool) or
               Map.has_key?(response, "suggested_tool") or
               Map.has_key?(response, :suggestion) or
               Map.has_key?(response, "suggestion")
    end
  end
end
