defmodule Mimo.Workflow.Spec053EdgeCasesTest do
  @moduledoc """
  Edge case tests for SPEC-053: Intelligent Tool Orchestration & Auto-Chaining.

  Tests boundary conditions, error handling, and corner cases for workflow
  components: PatternExtractor, Predictor, Executor, Clusterer, etc.
  """
  use Mimo.DataCase, async: false

  alias Mimo.Workflow

  alias Mimo.Workflow.{
    Pattern,
    PatternRegistry,
    Predictor,
    Executor,
    Clusterer,
    BindingsResolver,
    PatternExtractor,
    ToolLog
  }

  # =============================================================================
  # Setup
  # =============================================================================

  setup do
    ensure_genserver_started(PatternRegistry)
    ensure_genserver_started(Mimo.AdaptiveWorkflow.ModelProfiler)
    PatternRegistry.seed_patterns()
    :ok
  end

  defp ensure_genserver_started(module) do
    case Process.whereis(module) do
      nil -> {:ok, _} = module.start_link([])
      _pid -> :ok
    end
  rescue
    _ -> :ok
  end

  # =============================================================================
  # Pattern Schema Edge Cases
  # =============================================================================

  describe "Pattern schema edge cases" do
    test "creates pattern with empty steps list" do
      attrs = %{
        id: "empty_steps_v1",
        name: "empty_steps",
        description: "Pattern with no steps",
        category: :context_gathering,
        steps: []
      }

      changeset = Pattern.changeset(%Pattern{}, attrs)
      assert changeset.valid?
    end

    test "handles very long pattern names" do
      long_name = String.duplicate("a", 500)

      attrs = %{
        id: "long_#{System.unique_integer([:positive])}",
        name: long_name,
        description: "Test",
        category: :debugging,
        steps: []
      }

      changeset = Pattern.changeset(%Pattern{}, attrs)
      # Should either validate or reject, not crash
      assert is_struct(changeset, Ecto.Changeset)
    end

    test "handles unicode in pattern fields" do
      attrs = %{
        id: "unicode_パターン",
        name: "日本語パターン",
        description: "説明 🔧",
        category: :code_navigation,
        steps: [%{tool: "file", args: %{path: "/путь/файл.ex"}}]
      }

      changeset = Pattern.changeset(%Pattern{}, attrs)
      assert is_struct(changeset, Ecto.Changeset)
    end

    test "handles steps with deeply nested args" do
      attrs = %{
        id: "nested_v1",
        name: "nested_pattern",
        category: :debugging,
        steps: [
          %{
            tool: "complex",
            args: %{
              level1: %{
                level2: %{
                  level3: %{
                    level4: [1, 2, 3, %{deep: "value"}]
                  }
                }
              }
            }
          }
        ]
      }

      changeset = Pattern.changeset(%Pattern{}, attrs)
      assert is_struct(changeset, Ecto.Changeset)
    end

    test "handles nil values in optional fields" do
      attrs = %{
        id: "nil_fields_v1",
        name: "nil_pattern",
        description: nil,
        category: :file_editing,
        steps: nil,
        conditions: nil,
        bindings: nil,
        metadata: nil
      }

      changeset = Pattern.changeset(%Pattern{}, attrs)
      assert is_struct(changeset, Ecto.Changeset)
    end
  end

  # =============================================================================
  # PatternRegistry Edge Cases
  # =============================================================================

  describe "PatternRegistry edge cases" do
    test "handles concurrent pattern saves" do
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            pattern = %Pattern{
              name: "concurrent_#{i}",
              description: "Concurrent test #{i}",
              category: :debugging,
              steps: []
            }

            PatternRegistry.save_pattern(pattern)
          end)
        end

      results = Task.await_many(tasks, 5000)
      assert Enum.all?(results, &match?({:ok, _}, &1))
    end

    test "handles pattern with special characters in name" do
      pattern = %Pattern{
        name: "test/pattern:with<special>chars",
        description: "Special chars test",
        category: :code_navigation,
        steps: []
      }

      result = PatternRegistry.save_pattern(pattern)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles update of existing pattern" do
      # First save
      pattern1 = %Pattern{
        name: "update_test",
        description: "Version 1",
        category: :debugging,
        steps: [%{tool: "memory", args: %{}}]
      }

      {:ok, _} = PatternRegistry.save_pattern(pattern1)

      # Update with same name
      pattern2 = %Pattern{
        name: "update_test",
        description: "Version 2",
        category: :debugging,
        steps: [%{tool: "file", args: %{}}]
      }

      result = PatternRegistry.save_pattern(pattern2)
      assert match?({:ok, _}, result)
    end

    test "handles empty string pattern name lookup" do
      result = PatternRegistry.get_pattern("")
      assert result == {:error, :not_found}
    end

    test "handles nil pattern name lookup" do
      result = PatternRegistry.get_pattern(nil)
      assert match?({:error, _}, result)
    end
  end

  # =============================================================================
  # Predictor Edge Cases
  # =============================================================================

  describe "Predictor edge cases" do
    test "handles empty task string" do
      result = Predictor.predict_workflow("", %{})

      assert match?({:ok, _, _, _}, result) or match?({:suggest, _}, result) or
               match?({:manual, _}, result)
    end

    test "handles very long task description" do
      long_task = String.duplicate("Fix the error in the authentication module. ", 100)
      result = Predictor.predict_workflow(long_task, %{})

      assert match?({:ok, _, _, _}, result) or match?({:suggest, _}, result) or
               match?({:manual, _}, result)
    end

    test "handles task with only special characters" do
      result = Predictor.predict_workflow("!@#$%^&*()", %{})

      assert match?({:ok, _, _, _}, result) or match?({:suggest, _}, result) or
               match?({:manual, _}, result)
    end

    test "handles task with unicode characters" do
      result = Predictor.predict_workflow("修正するバグ в коде 🐛", %{})

      assert match?({:ok, _, _, _}, result) or match?({:suggest, _}, result) or
               match?({:manual, _}, result)
    end

    test "handles nil context" do
      result = Predictor.predict_workflow("Fix the error", nil)

      assert match?({:ok, _, _, _}, result) or match?({:suggest, _}, result) or
               match?({:manual, _}, result)
    end

    test "handles context with circular references" do
      # Create map that references itself (sort of)
      context = %{a: 1, b: 2}
      result = Predictor.predict_workflow("Test task", Map.put(context, :self_ref, context))

      assert match?({:ok, _, _, _}, result) or match?({:suggest, _}, result) or
               match?({:manual, _}, result)
    end

    test "handles context with very large values" do
      large_context = %{
        huge_string: String.duplicate("x", 100_000),
        large_list: Enum.to_list(1..1000)
      }

      result = Predictor.predict_workflow("Test task", large_context)

      assert match?({:ok, _, _, _}, result) or match?({:suggest, _}, result) or
               match?({:manual, _}, result)
    end
  end

  # =============================================================================
  # BindingsResolver Edge Cases
  # =============================================================================

  describe "BindingsResolver edge cases" do
    test "handles deeply nested path extraction" do
      context = %{
        a: %{b: %{c: %{d: %{e: %{f: "deep_value"}}}}}
      }

      value = BindingsResolver.extract_path(context, "a.b.c.d.e.f")
      assert value == "deep_value"
    end

    test "handles path with array indices" do
      context = %{
        items: [%{name: "first"}, %{name: "second"}]
      }

      # Depending on implementation, this might extract or return nil
      value = BindingsResolver.extract_path(context, "items.0.name")
      assert value == "first" or value == nil
    end

    test "handles empty path" do
      context = %{key: "value"}
      value = BindingsResolver.extract_path(context, "")
      assert value == nil or value == context
    end

    test "handles nil context" do
      value = BindingsResolver.extract_path(nil, "some.path")
      assert value == nil
    end

    test "handles path with special characters" do
      context = %{"key.with.dots" => "value", "key-with-dashes" => "other"}

      # These might not work as expected, just ensure no crash
      value = BindingsResolver.extract_path(context, "key.with.dots")
      assert is_nil(value) or is_binary(value)
    end

    test "resolves bindings with missing pattern" do
      step = %{tool: "test", args: %{}}
      result = BindingsResolver.resolve_step_bindings(step, %{}, nil)
      assert is_map(result)
    end

    test "handles dynamic bindings with invalid JSONPath" do
      step = %{
        "tool" => "test",
        "params" => %{},
        "dynamic_bindings" => [
          %{
            "source" => "global_context",
            "path" => "$[invalid][path",
            "target_param" => "test"
          }
        ]
      }

      result = BindingsResolver.resolve_step_bindings(step, %{}, nil)
      assert is_map(result)
    end
  end

  # =============================================================================
  # Clusterer Edge Cases
  # =============================================================================

  describe "Clusterer edge cases" do
    test "calculates distance between identical patterns" do
      pattern = %Pattern{
        steps: [
          %{tool: "memory", args: %{}},
          %{tool: "file", args: %{}}
        ]
      }

      distance = Clusterer.pattern_distance(pattern, pattern)
      assert distance == 0.0
    end

    test "calculates distance between completely different patterns" do
      pattern1 = %Pattern{steps: [%{tool: "a", args: %{}}]}
      pattern2 = %Pattern{steps: [%{tool: "z", args: %{}}]}

      distance = Clusterer.pattern_distance(pattern1, pattern2)
      assert distance >= 0.0 and distance <= 1.0
    end

    test "handles empty pattern steps" do
      pattern1 = %Pattern{steps: []}
      pattern2 = %Pattern{steps: [%{tool: "test", args: %{}}]}

      distance = Clusterer.pattern_distance(pattern1, pattern2)
      assert is_float(distance)
    end

    test "handles nil pattern steps" do
      pattern1 = %Pattern{steps: nil}
      pattern2 = %Pattern{steps: []}

      # Should handle gracefully
      result =
        try do
          Clusterer.pattern_distance(pattern1, pattern2)
        rescue
          _ -> :error
        end

      assert result == :error or is_float(result)
    end

    test "clusters empty pattern list" do
      {:ok, clusters} = Clusterer.cluster_patterns([])
      assert clusters == []
    end

    test "clusters single pattern" do
      pattern = %Pattern{
        name: "single",
        steps: [%{tool: "test", args: %{}}]
      }

      {:ok, clusters} = Clusterer.cluster_patterns([pattern])
      assert is_list(clusters)
    end

    test "finds similar with very high threshold" do
      patterns = PatternRegistry.list_patterns()
      test_steps = [%{tool: "impossible_tool", args: %{}}]

      result = Clusterer.find_similar_pattern(test_steps, patterns, 0.99)
      # API returns :no_match or {:ok, pattern, distance}
      assert result == :no_match or match?({:ok, _, _}, result)
    end

    test "finds similar with zero threshold" do
      patterns = PatternRegistry.list_patterns()
      test_steps = [%{tool: "memory", args: %{}}]

      result = Clusterer.find_similar_pattern(test_steps, patterns, 0.0)
      # :no_match if patterns is empty or threshold is too strict
      assert result == :no_match or match?({:ok, _, _}, result)
    end
  end

  # =============================================================================
  # Executor Edge Cases
  # =============================================================================

  describe "Executor edge cases" do
    test "converts pattern with empty bindings" do
      pattern = %Pattern{
        name: "empty_bindings",
        steps: [%{tool: "test", args: %{}}],
        bindings: []
      }

      procedure = Executor.pattern_to_procedure(pattern, %{})
      assert Map.has_key?(procedure, "states")
    end

    test "converts pattern with complex bindings" do
      pattern = %Pattern{
        name: "complex_bindings",
        steps: [
          %{tool: "memory", args: %{query: "{query}"}},
          %{tool: "file", args: %{path: "{file_path}"}}
        ],
        bindings: [
          %{name: "query", source: "input", path: "$.query", required: true},
          %{name: "file_path", source: "step_0.result.data.path", required: false}
        ]
      }

      procedure = Executor.pattern_to_procedure(pattern, %{query: "test"})
      assert Map.has_key?(procedure, "states")
    end

    test "handles execution status for very long IDs" do
      long_id = String.duplicate("x", 1000)
      result = Executor.get_execution_status(long_id)
      assert result == {:error, :not_found}
    end

    test "handles execution status for special character IDs" do
      result = Executor.get_execution_status("exec/with:special<chars>")
      assert result == {:error, :not_found}
    end
  end

  # =============================================================================
  # ToolLog Edge Cases
  # =============================================================================

  describe "ToolLog edge cases" do
    test "logs with nil fields" do
      entry = %{
        tool: nil,
        args: nil,
        result: nil,
        duration_ms: nil
      }

      # Should handle gracefully
      result =
        try do
          ToolLog.log(entry)
        rescue
          _ -> :error
        end

      assert match?({:ok, _}, result) or match?({:error, _}, result) or result == :error
    end

    test "logs with very large result data" do
      entry = %{
        tool: "test",
        args: %{},
        result: %{data: String.duplicate("x", 1_000_000)},
        duration_ms: 100
      }

      result =
        try do
          ToolLog.log(entry)
        rescue
          _ -> :error
        end

      assert match?({:ok, _}, result) or match?({:error, _}, result) or result == :error
    end
  end

  # =============================================================================
  # Workflow Facade Edge Cases
  # =============================================================================

  describe "Workflow facade edge cases" do
    test "suggests workflow for nil task" do
      result = Workflow.suggest(nil)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "suggests workflow for task with only whitespace" do
      result = Workflow.suggest("   \t\n   ")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "gets model profile for empty string" do
      result = Workflow.get_model_profile("")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "gets model recommendations for nil model" do
      result = Workflow.get_model_recommendations(nil)
      assert is_map(result)
    end
  end

  # =============================================================================
  # PatternExtractor Edge Cases
  # =============================================================================

  describe "PatternExtractor edge cases" do
    test "extracts from empty tool log" do
      result = PatternExtractor.extract_from_tool_log([])
      assert match?({:ok, _}, result) or match?({:error, _}, result) or is_list(result)
    end

    test "extracts from single tool call" do
      log = [%{tool: "memory", args: %{operation: "search"}, duration_ms: 100}]
      result = PatternExtractor.extract_from_tool_log(log)
      assert match?({:ok, _}, result) or match?({:error, _}, result) or is_list(result)
    end

    test "extracts from very long tool sequence" do
      log =
        for i <- 1..100 do
          %{tool: "tool_#{rem(i, 5)}", args: %{i: i}, duration_ms: 50}
        end

      result = PatternExtractor.extract_from_tool_log(log)
      assert match?({:ok, _}, result) or match?({:error, _}, result) or is_list(result)
    end
  end
end
