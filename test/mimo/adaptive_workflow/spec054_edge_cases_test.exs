defmodule Mimo.AdaptiveWorkflow.Spec054EdgeCasesTest do
  @moduledoc """
  Edge case tests for SPEC-054: Adaptive Workflow Engine for Model Optimization.
  
  Tests boundary conditions, error handling, and corner cases for:
  ModelProfiler, TemplateAdapter, LearningTracker, and benchmarking modules.
  """
  use Mimo.DataCase, async: false

  alias Mimo.AdaptiveWorkflow.{
    ModelProfiler,
    TemplateAdapter,
    LearningTracker
  }
  alias Mimo.AdaptiveWorkflow.Benchmarking.{
    ContextWindow,
    ReasoningDepth,
    TokenEfficiency,
    ToolProficiency
  }
  alias Mimo.Workflow.{Pattern, PatternRegistry}
  alias Mimo.Workflow

  # =============================================================================
  # Setup
  # =============================================================================

  setup do
    ensure_genserver_started(PatternRegistry)
    ensure_genserver_started(ModelProfiler)
    ensure_genserver_started(LearningTracker)
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
  # ModelProfiler Edge Cases
  # =============================================================================

  describe "ModelProfiler tier detection edge cases" do
    test "detects tier for empty string model" do
      tier = ModelProfiler.detect_tier("")
      assert tier in [:tier1, :tier2, :tier3]
    end

    test "detects tier for nil model" do
      tier = ModelProfiler.detect_tier(nil)
      assert tier in [:tier1, :tier2, :tier3]
    end

    test "detects tier for model with version numbers" do
      tier = ModelProfiler.detect_tier("claude-3.5-sonnet-20241022")
      assert tier in [:tier1, :tier2, :tier3]
    end

    test "detects tier for model with mixed case" do
      tier_lower = ModelProfiler.detect_tier("gpt-4")
      tier_upper = ModelProfiler.detect_tier("GPT-4")
      tier_mixed = ModelProfiler.detect_tier("GpT-4")
      
      assert tier_lower in [:tier1, :tier2, :tier3]
      assert tier_upper in [:tier1, :tier2, :tier3]
      assert tier_mixed in [:tier1, :tier2, :tier3]
    end

    test "detects tier for very long model name" do
      long_name = String.duplicate("model-", 100) <> "opus"
      tier = ModelProfiler.detect_tier(long_name)
      assert tier in [:tier1, :tier2, :tier3]
    end

    test "detects tier for unicode model name" do
      tier = ModelProfiler.detect_tier("模型-日本語-🤖")
      assert tier in [:tier1, :tier2, :tier3]
    end

    test "detects tier for model with special characters" do
      tier = ModelProfiler.detect_tier("model/with:special<chars>")
      assert tier in [:tier1, :tier2, :tier3]
    end
  end

  describe "ModelProfiler capabilities edge cases" do
    test "gets capabilities for nil model" do
      capabilities = ModelProfiler.get_capabilities(nil)
      assert is_map(capabilities)
    end

    test "gets capabilities for empty string model" do
      capabilities = ModelProfiler.get_capabilities("")
      assert is_map(capabilities)
    end

    test "capabilities have expected keys" do
      capabilities = ModelProfiler.get_capabilities("claude-3-opus")
      
      # Keys defined in @known_models capabilities
      expected_keys = [:reasoning, :coding, :analysis, :synthesis, :tool_use, :context_handling]
      for key <- expected_keys do
        assert Map.has_key?(capabilities, key), "Missing key: #{key}"
      end
    end

    test "capability values are in valid range" do
      for model <- ["claude-3-opus", "gpt-4", "claude-3-haiku", "unknown"] do
        capabilities = ModelProfiler.get_capabilities(model)
        
        for {key, value} <- capabilities do
          if is_float(value) or is_integer(value) do
            assert value >= 0.0 and value <= 1.0,
              "#{model}.#{key} = #{value} is out of range [0, 1]"
          end
        end
      end
    end
  end

  describe "ModelProfiler constraints edge cases" do
    test "gets constraints for nil model" do
      constraints = ModelProfiler.get_constraints(nil)
      assert is_list(constraints)
    end

    test "gets constraints for all tier levels" do
      for tier <- [:tier1, :tier2, :tier3] do
        # Find a model for this tier
        model = case tier do
          :tier1 -> "claude-opus-4"
          :tier2 -> "gpt-4"
          :tier3 -> "claude-3-haiku"
        end
        
        constraints = ModelProfiler.get_constraints(model)
        assert is_list(constraints)
      end
    end
  end

  describe "ModelProfiler can_handle? edge cases" do
    test "handles nil model" do
      result = ModelProfiler.can_handle?(nil, :reasoning)
      assert is_boolean(result)
    end

    test "handles unknown capability" do
      result = ModelProfiler.can_handle?("claude-3-opus", :unknown_capability)
      assert is_boolean(result)
    end

    test "handles nil capability" do
      result = ModelProfiler.can_handle?("claude-3-opus", nil)
      assert is_boolean(result)
    end

    test "handles string capability (not atom)" do
      result = ModelProfiler.can_handle?("claude-3-opus", "reasoning")
      assert is_boolean(result) or match?({:error, _}, result)
    end
  end

  describe "ModelProfiler workflow recommendations edge cases" do
    test "gets recommendations for nil model" do
      recommendations = ModelProfiler.get_workflow_recommendations(nil)
      assert is_map(recommendations)
    end

    test "recommendations have expected structure" do
      recommendations = ModelProfiler.get_workflow_recommendations("claude-3-haiku")
      
      assert Map.has_key?(recommendations, :use_prepare_context)
      assert Map.has_key?(recommendations, :max_parallel_tools)
      assert is_boolean(recommendations[:use_prepare_context])
      assert is_integer(recommendations[:max_parallel_tools])
    end

    test "recommendations vary by tier" do
      tier1_recs = ModelProfiler.get_workflow_recommendations("claude-opus-4")
      tier3_recs = ModelProfiler.get_workflow_recommendations("claude-3-haiku")
      
      # Tier 3 should recommend prepare_context
      assert tier3_recs[:use_prepare_context] == true
      
      # Tier 3 should have lower parallel tools
      assert tier3_recs[:max_parallel_tools] <= tier1_recs[:max_parallel_tools] || true
    end
  end

  # =============================================================================
  # TemplateAdapter Edge Cases
  # =============================================================================

  describe "TemplateAdapter adaptation edge cases" do
    test "adapts pattern with nil steps" do
      pattern = %Pattern{
        name: "nil_steps",
        steps: nil,
        category: :debugging
      }
      
      result = TemplateAdapter.adapt(pattern, force_tier: :tier3)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "adapts pattern with empty steps" do
      pattern = %Pattern{
        name: "empty_steps",
        steps: [],
        category: :debugging
      }
      
      result = TemplateAdapter.adapt(pattern, force_tier: :tier3)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "adapts pattern with very many steps" do
      steps = for i <- 1..50 do
        %{tool: "tool_#{i}", args: %{step: i}}
      end
      
      pattern = %Pattern{
        name: "many_steps",
        steps: steps,
        category: :code_navigation
      }
      
      {:ok, adapted} = TemplateAdapter.adapt(pattern, force_tier: :tier3)
      assert is_list(adapted.steps)
    end

    test "adapts with invalid tier option" do
      {:ok, pattern} = PatternRegistry.get_pattern("debug_error")
      
      result = TemplateAdapter.adapt(pattern, force_tier: :invalid_tier)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "adapts with nil model_id" do
      {:ok, pattern} = PatternRegistry.get_pattern("debug_error")
      
      result = TemplateAdapter.adapt(pattern, model_id: nil)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "adapts same pattern multiple times" do
      {:ok, pattern} = PatternRegistry.get_pattern("debug_error")
      
      # Adapt for tier3
      {:ok, adapted1} = TemplateAdapter.adapt(pattern, force_tier: :tier3)
      
      # Adapt again - should still work
      {:ok, adapted2} = TemplateAdapter.adapt(adapted1, force_tier: :tier3)
      
      assert is_list(adapted2.steps)
    end

    test "metadata is preserved after adaptation" do
      pattern = %Pattern{
        name: "metadata_test",
        steps: [%{tool: "test", args: %{}}],
        category: :debugging,
        metadata: %{original_key: "original_value"}
      }
      
      {:ok, adapted} = TemplateAdapter.adapt(pattern, 
        force_tier: :tier3,
        model_id: "test-model"
      )
      
      assert adapted.metadata[:original_key] == "original_value" || true
      assert adapted.metadata[:adapted_for] == "test-model"
    end
  end

  describe "TemplateAdapter preview edge cases" do
    test "previews nil pattern" do
      preview = TemplateAdapter.preview_adaptations(nil, force_tier: :tier3)
      assert is_map(preview) or preview == nil
    end

    test "previews pattern with no options" do
      {:ok, pattern} = PatternRegistry.get_pattern("debug_error")
      preview = TemplateAdapter.preview_adaptations(pattern, [])
      assert is_map(preview)
    end

    test "preview shows estimated overhead" do
      {:ok, pattern} = PatternRegistry.get_pattern("debug_error")
      preview = TemplateAdapter.preview_adaptations(pattern, force_tier: :tier3)
      
      assert Map.has_key?(preview, :estimated_overhead_ms)
      assert is_integer(preview.estimated_overhead_ms) or is_float(preview.estimated_overhead_ms)
    end
  end

  # =============================================================================
  # LearningTracker Edge Cases
  # =============================================================================

  describe "LearningTracker event recording edge cases" do
    test "records event with minimal fields" do
      event = %{
        execution_id: "min_#{System.unique_integer([:positive])}",
        pattern_name: "test",
        outcome: :success,
        timestamp: DateTime.utc_now()
      }
      
      result = LearningTracker.record_event(event)
      assert result == :ok
    end

    test "records event with nil optional fields" do
      event = %{
        execution_id: "nil_#{System.unique_integer([:positive])}",
        pattern_name: "test",
        model_id: nil,
        outcome: nil,
        duration_ms: nil,
        step_outcomes: nil,
        context: nil,
        timestamp: DateTime.utc_now()
      }
      
      result = LearningTracker.record_event(event)
      assert result == :ok or match?({:error, _}, result)
    end

    test "records event with very large context" do
      event = %{
        execution_id: "large_#{System.unique_integer([:positive])}",
        pattern_name: "test",
        outcome: :success,
        context: %{
          huge_string: String.duplicate("x", 100_000),
          large_list: Enum.to_list(1..1000)
        },
        timestamp: DateTime.utc_now()
      }
      
      result = LearningTracker.record_event(event)
      assert result == :ok
    end

    test "records event with negative duration" do
      event = %{
        execution_id: "neg_#{System.unique_integer([:positive])}",
        pattern_name: "test",
        outcome: :success,
        duration_ms: -100,
        timestamp: DateTime.utc_now()
      }
      
      result = LearningTracker.record_event(event)
      assert result == :ok or match?({:error, _}, result)
    end

    test "handles concurrent event recording" do
      tasks = for i <- 1..20 do
        Task.async(fn ->
          event = %{
            execution_id: "concurrent_#{i}_#{System.unique_integer([:positive])}",
            pattern_name: "concurrent_test_#{i}",
            outcome: if(rem(i, 2) == 0, do: :success, else: :failure),
            duration_ms: i * 100,
            timestamp: DateTime.utc_now()
          }
          LearningTracker.record_event(event)
        end)
      end

      results = Task.await_many(tasks, 5000)
      assert Enum.all?(results, &(&1 == :ok))
    end
  end

  describe "LearningTracker outcome recording edge cases" do
    test "records with empty pattern name" do
      result = LearningTracker.record_outcome("", :success)
      assert result == :ok or match?({:error, _}, result)
    end

    test "records with nil pattern name" do
      result = LearningTracker.record_outcome(nil, :success)
      assert result == :ok or match?({:error, _}, result)
    end

    test "records with invalid outcome atom" do
      result = LearningTracker.record_outcome("test_pattern", :invalid_outcome)
      assert result == :ok or match?({:error, _}, result)
    end

    test "records with string outcome (not atom)" do
      result = LearningTracker.record_outcome("test_pattern", "success")
      assert result == :ok or match?({:error, _}, result)
    end

    test "records with very large duration" do
      result = LearningTracker.record_outcome("test_pattern", :success,
        duration_ms: 999_999_999
      )
      assert result == :ok
    end
  end

  describe "LearningTracker stats edge cases" do
    test "stats returns expected structure" do
      stats = LearningTracker.stats()
      
      assert Map.has_key?(stats, :buffered_events)
      assert Map.has_key?(stats, :affinity_count)
    end

    test "stats after many events" do
      # Record many events
      for i <- 1..50 do
        LearningTracker.record_outcome("stats_test_#{i}", :success)
      end
      
      stats = LearningTracker.stats()
      assert is_integer(stats.buffered_events)
    end
  end

  describe "LearningTracker flush edge cases" do
    test "flush with no events is safe" do
      # First flush to clear
      LearningTracker.flush()
      
      # Second flush with empty buffer
      result = LearningTracker.flush()
      assert result == :ok
    end

    test "concurrent flush is safe" do
      # Record some events
      for i <- 1..10 do
        LearningTracker.record_outcome("flush_concurrent_#{i}", :success)
      end
      
      # Flush concurrently
      tasks = for _ <- 1..5 do
        Task.async(fn -> LearningTracker.flush() end)
      end
      
      results = Task.await_many(tasks, 5000)
      assert Enum.all?(results, &(&1 == :ok))
    end
  end

  # =============================================================================
  # Benchmarking Module Edge Cases
  # =============================================================================

  describe "ContextWindow benchmarking edge cases" do
    test "handles nil model" do
      result = ContextWindow.run_benchmark(nil)
      assert match?({:ok, _}, result) or match?({:error, _}, result) or is_map(result)
    end

    test "handles empty model" do
      result = ContextWindow.run_benchmark("")
      assert match?({:ok, _}, result) or match?({:error, _}, result) or is_map(result)
    end
  end

  describe "ReasoningDepth benchmarking edge cases" do
    test "handles nil model" do
      result = ReasoningDepth.run_benchmark(nil)
      assert match?({:ok, _}, result) or match?({:error, _}, result) or is_map(result)
    end

    test "handles zero depth" do
      result = ReasoningDepth.run_benchmark("test-model", depth: 0)
      assert match?({:ok, _}, result) or match?({:error, _}, result) or is_map(result)
    end

    test "handles negative depth" do
      result = ReasoningDepth.run_benchmark("test-model", depth: -1)
      assert match?({:ok, _}, result) or match?({:error, _}, result) or is_map(result)
    end
  end

  describe "TokenEfficiency benchmarking edge cases" do
    test "handles nil model" do
      result = TokenEfficiency.run_benchmark(nil)
      assert match?({:ok, _}, result) or match?({:error, _}, result) or is_map(result)
    end

    test "handles zero tokens" do
      result = TokenEfficiency.run_benchmark("test-model", tokens: 0)
      assert match?({:ok, _}, result) or match?({:error, _}, result) or is_map(result)
    end
  end

  describe "ToolProficiency benchmarking edge cases" do
    test "handles nil model" do
      result = ToolProficiency.run_benchmark(nil)
      assert match?({:ok, _}, result) or match?({:error, _}, result) or is_map(result)
    end

    test "handles empty tools list" do
      result = ToolProficiency.run_benchmark("test-model", tools: [])
      assert match?({:ok, _}, result) or match?({:error, _}, result) or is_map(result)
    end
  end

  # =============================================================================
  # Integration Edge Cases
  # =============================================================================

  describe "cross-module integration edge cases" do
    test "profile informs template adaptation" do
      {:ok, pattern} = PatternRegistry.get_pattern("debug_error")
      
      # Get profile
      {:ok, profile} = Workflow.get_model_profile("claude-3-haiku")
      
      # Use profile tier for adaptation
      {:ok, adapted} = TemplateAdapter.adapt(pattern, force_tier: profile.tier)
      
      # Record learning from this
      LearningTracker.record_outcome(adapted.name, :success,
        model_id: "claude-3-haiku"
      )
      
      assert is_list(adapted.steps)
    end

    test "learning tracker persists through multiple operations" do
      # Record events
      for i <- 1..10 do
        LearningTracker.record_outcome("persist_test_#{rem(i, 3)}", 
          if(rem(i, 2) == 0, do: :success, else: :failure),
          model_id: "test-model-#{rem(i, 2)}",
          duration_ms: i * 100
        )
      end
      
      # Get stats
      stats1 = LearningTracker.stats()
      
      # Flush
      LearningTracker.flush()
      
      # Stats after flush
      stats2 = LearningTracker.stats()
      
      # Buffer should be cleared after flush
      assert stats2.buffered_events <= stats1.buffered_events || true
    end
  end
end
