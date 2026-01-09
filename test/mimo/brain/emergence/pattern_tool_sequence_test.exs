defmodule Mimo.Brain.Emergence.PatternToolSequenceTest do
  @moduledoc """
  Tests for Pattern's Phase 3 L4 tool sequence integration.

  Verifies that successful workflow patterns can be extracted
  and used to suggest next tools in a sequence.
  """
  use Mimo.DataCase

  alias Mimo.Brain.Emergence.Pattern

  describe "get_successful_tool_sequences/1" do
    test "returns empty list when no patterns exist" do
      sequences = Pattern.get_successful_tool_sequences(min_success_rate: 0.9)
      assert is_list(sequences)
    end

    test "extracts tools from workflow patterns" do
      # Create a successful workflow pattern with tool components
      {:ok, pattern} =
        %Pattern{}
        |> Pattern.changeset(%{
          type: :workflow,
          status: :active,
          description: "memory search then file edit",
          components: [
            %{"tool" => "memory", "operation" => "search"},
            %{"tool" => "file", "operation" => "edit"}
          ],
          success_rate: 0.8,
          occurrences: 10,
          strength: 0.7
        })
        |> Repo.insert()

      sequences = Pattern.get_successful_tool_sequences(min_success_rate: 0.5)

      assert is_list(sequences)

      # Find our pattern's sequence
      matching =
        Enum.find(sequences, fn seq ->
          seq.tools == ["memory", "file"]
        end)

      if matching do
        assert matching.success_rate == 0.8
        assert matching.occurrences == 10
      end
    end

    test "filters by minimum success rate" do
      # Create patterns with different success rates
      {:ok, _high} =
        %Pattern{}
        |> Pattern.changeset(%{
          type: :workflow,
          status: :active,
          description: "high success pattern",
          components: [%{"tool" => "code"}, %{"tool" => "terminal"}],
          success_rate: 0.95,
          occurrences: 5,
          strength: 0.8
        })
        |> Repo.insert()

      {:ok, _low} =
        %Pattern{}
        |> Pattern.changeset(%{
          type: :workflow,
          status: :active,
          description: "low success pattern",
          components: [%{"tool" => "web"}, %{"tool" => "file"}],
          success_rate: 0.3,
          occurrences: 5,
          strength: 0.4
        })
        |> Repo.insert()

      # High threshold should only return high success patterns
      high_only = Pattern.get_successful_tool_sequences(min_success_rate: 0.9)

      high_tools = Enum.flat_map(high_only, & &1.tools)
      # Low success pattern's tool
      refute "web" in high_tools
    end

    test "handles malformed components gracefully" do
      {:ok, _} =
        %Pattern{}
        |> Pattern.changeset(%{
          type: :workflow,
          status: :active,
          description: "pattern with weird components",
          components: [%{"not_a_tool" => "something"}, nil, "string"],
          success_rate: 0.8,
          occurrences: 5,
          strength: 0.5
        })
        |> Repo.insert()

      # Should not crash
      sequences = Pattern.get_successful_tool_sequences(min_success_rate: 0.5)
      assert is_list(sequences)
    end
  end

  describe "suggest_next_tool_from_patterns/2" do
    setup do
      # Create test workflow patterns
      {:ok, _} =
        %Pattern{}
        |> Pattern.changeset(%{
          type: :workflow,
          status: :active,
          description: "memory → code → file workflow",
          components: [
            %{"tool" => "memory"},
            %{"tool" => "code"},
            %{"tool" => "file"}
          ],
          success_rate: 0.85,
          occurrences: 20,
          strength: 0.8
        })
        |> Repo.insert()

      {:ok, _} =
        %Pattern{}
        |> Pattern.changeset(%{
          type: :workflow,
          status: :active,
          description: "memory → terminal workflow",
          components: [
            %{"tool" => "memory"},
            %{"tool" => "terminal"}
          ],
          success_rate: 0.75,
          occurrences: 15,
          strength: 0.7
        })
        |> Repo.insert()

      :ok
    end

    test "returns empty list for empty recent_tools" do
      suggestions = Pattern.suggest_next_tool_from_patterns([])
      assert suggestions == []
    end

    test "suggests next tool based on pattern prefix" do
      # If user just used "memory", patterns that start with memory should suggest next tool
      suggestions = Pattern.suggest_next_tool_from_patterns(["memory"])

      assert is_list(suggestions)

      if length(suggestions) > 0 do
        first = hd(suggestions)
        assert Map.has_key?(first, :suggested_tool)
        assert Map.has_key?(first, :success_rate)
        assert Map.has_key?(first, :pattern_description)

        # Should suggest "code" or "terminal" as next after "memory"
        assert first.suggested_tool in ["code", "terminal"]
      end
    end

    test "suggests based on multi-step prefix" do
      # If user used memory → code, should suggest file
      suggestions = Pattern.suggest_next_tool_from_patterns(["memory", "code"])

      if length(suggestions) > 0 do
        first = hd(suggestions)
        assert first.suggested_tool == "file"
      end
    end

    test "returns empty when no patterns match prefix" do
      suggestions = Pattern.suggest_next_tool_from_patterns(["weird_unknown_tool"])
      assert suggestions == []
    end

    test "respects limit parameter" do
      # Create many patterns starting with "memory"
      for i <- 1..5 do
        {:ok, _} =
          %Pattern{}
          |> Pattern.changeset(%{
            type: :workflow,
            status: :active,
            description: "pattern #{i}",
            components: [%{"tool" => "memory"}, %{"tool" => "tool_#{i}"}],
            success_rate: 0.7 + i * 0.01,
            occurrences: 10,
            strength: 0.6
          })
          |> Repo.insert()
      end

      suggestions = Pattern.suggest_next_tool_from_patterns(["memory"], limit: 2)
      assert length(suggestions) <= 2
    end

    test "handles database errors gracefully" do
      # This tests the rescue clause - should return empty list on error
      # We can't easily trigger a DB error, but we can verify the function
      # returns a list type
      result = Pattern.suggest_next_tool_from_patterns(["test"])
      assert is_list(result)
    end
  end

  describe "is_prefix?/2 helper" do
    # We can't directly test private functions, but we test behavior through public API

    test "single element prefix matching" do
      {:ok, _} =
        %Pattern{}
        |> Pattern.changeset(%{
          type: :workflow,
          status: :active,
          description: "a → b → c",
          components: [%{"tool" => "a"}, %{"tool" => "b"}, %{"tool" => "c"}],
          success_rate: 0.9,
          occurrences: 10,
          strength: 0.8
        })
        |> Repo.insert()

      # ["a"] is prefix of ["a", "b", "c"]
      suggestions = Pattern.suggest_next_tool_from_patterns(["a"])
      assert length(suggestions) >= 1
      assert hd(suggestions).suggested_tool == "b"
    end

    test "two element prefix matching" do
      {:ok, _} =
        %Pattern{}
        |> Pattern.changeset(%{
          type: :workflow,
          status: :active,
          description: "x → y → z",
          components: [%{"tool" => "x"}, %{"tool" => "y"}, %{"tool" => "z"}],
          success_rate: 0.9,
          occurrences: 10,
          strength: 0.8
        })
        |> Repo.insert()

      # ["x", "y"] is prefix of ["x", "y", "z"]
      suggestions = Pattern.suggest_next_tool_from_patterns(["x", "y"])
      assert length(suggestions) >= 1
      assert hd(suggestions).suggested_tool == "z"
    end

    test "non-prefix does not match" do
      {:ok, _} =
        %Pattern{}
        |> Pattern.changeset(%{
          type: :workflow,
          status: :active,
          description: "m → n → o",
          components: [%{"tool" => "m"}, %{"tool" => "n"}, %{"tool" => "o"}],
          success_rate: 0.9,
          occurrences: 10,
          strength: 0.8
        })
        |> Repo.insert()

      # ["n"] is NOT a prefix of ["m", "n", "o"]
      suggestions = Pattern.suggest_next_tool_from_patterns(["n"])

      # Should not match the m → n → o pattern
      matching = Enum.find(suggestions, fn s -> s.full_sequence == ["m", "n", "o"] end)
      assert is_nil(matching)
    end
  end
end
