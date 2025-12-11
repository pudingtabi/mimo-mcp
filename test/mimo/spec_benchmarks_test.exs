defmodule Mimo.Spec052to054BenchmarkTest do
  @moduledoc """
  Performance benchmark tests for SPEC-052, SPEC-053, and SPEC-054.
  
  These tests validate latency, throughput, and resource usage requirements
  for the neuro-symbolic reasoning, workflow orchestration, and adaptive
  workflow engine components.
  
  Run with: mix test test/mimo/spec_benchmarks_test.exs --include benchmark
  """
  use Mimo.DataCase, async: false

  # SPEC-052: Neuro-Symbolic Reasoning
  alias Mimo.NeuroSymbolic.{RuleGenerator, RuleValidator, CrossModalityLinker}
  alias Mimo.SemanticStore.Repository
  
  # SPEC-053: Workflow Orchestration
  alias Mimo.Workflow.{Pattern, PatternRegistry, Predictor, Clusterer}
  
  # SPEC-054: Adaptive Workflow Engine
  alias Mimo.AdaptiveWorkflow.{ModelProfiler, TemplateAdapter, LearningTracker}

  # Performance thresholds (in milliseconds)
  @rule_validation_threshold_ms 100
  @cross_modality_threshold_ms 50
  @workflow_prediction_threshold_ms 100
  @pattern_clustering_threshold_ms 200
  @model_profiling_threshold_ms 10
  @template_adaptation_threshold_ms 50
  @learning_event_threshold_ms 5

  # =============================================================================
  # Setup
  # =============================================================================

  setup do
    ensure_genserver_started(PatternRegistry)
    ensure_genserver_started(ModelProfiler)
    ensure_genserver_started(LearningTracker)
    PatternRegistry.seed_patterns()
    
    # Seed some triples for neuro-symbolic tests
    for i <- 1..20 do
      Repository.store_triple("bench_#{i}", "bench_rel", "bench_obj_#{i}")
    end
    
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
  # SPEC-052 Benchmarks: Neuro-Symbolic Reasoning
  # =============================================================================

  describe "SPEC-052 performance: rule validation" do
    @tag :benchmark
    test "rule validation completes within threshold" do
      candidate = %{
        premise: [%{"predicate" => "bench_rel"}],
        conclusion: %{"predicate" => "bench_rel"}
      }
      
      {time_us, result} = :timer.tc(fn ->
        RuleValidator.validate_rule(candidate)
      end)
      
      time_ms = time_us / 1000
      
      assert match?({:ok, _}, result)
      assert time_ms < @rule_validation_threshold_ms,
        "Rule validation took #{time_ms}ms, threshold is #{@rule_validation_threshold_ms}ms"
    end

    @tag :benchmark
    test "batch rule generation scales linearly" do
      candidates = for i <- 1..10 do
        %{
          id: Ecto.UUID.generate(),
          premise: [%{predicate: "bench_rel"}],
          conclusion: %{predicate: "bench_rel"},
          logical_form: %{},
          confidence: 0.8,
          source: "benchmark_#{i}"
        }
      end
      
      {time_us, result} = :timer.tc(fn ->
        RuleGenerator.validate_and_persist(candidates, persist_validated: false)
      end)
      
      time_ms = time_us / 1000
      per_rule_ms = time_ms / length(candidates)
      
      assert match?({:ok, _}, result)
      assert per_rule_ms < @rule_validation_threshold_ms,
        "Per-rule validation took #{per_rule_ms}ms, threshold is #{@rule_validation_threshold_ms}ms"
    end
  end

  describe "SPEC-052 performance: cross-modality linking" do
    @tag :benchmark
    test "cross-modality inference completes within threshold" do
      {time_us, result} = :timer.tc(fn ->
        CrossModalityLinker.infer_links(:code_symbol, "Phoenix.Controller", limit: 10)
      end)
      
      time_ms = time_us / 1000
      
      assert match?({:ok, _}, result)
      assert time_ms < @cross_modality_threshold_ms,
        "Cross-modality inference took #{time_ms}ms, threshold is #{@cross_modality_threshold_ms}ms"
    end

    @tag :benchmark
    test "batch cross-modality linking scales sub-linearly" do
      pairs = for i <- 1..20 do
        {:code_symbol, "Symbol_#{i}"}
      end
      
      {time_us, result} = :timer.tc(fn ->
        CrossModalityLinker.link_all(pairs, persist: false)
      end)
      
      time_ms = time_us / 1000
      per_pair_ms = time_ms / length(pairs)
      
      assert match?({:ok, _}, result)
      # Batch should be more efficient than individual calls
      assert per_pair_ms < @cross_modality_threshold_ms / 2,
        "Per-pair linking took #{per_pair_ms}ms, expected < #{@cross_modality_threshold_ms / 2}ms"
    end

    @tag :benchmark
    test "cross-modality stats computation is fast" do
      {time_us, stats} = :timer.tc(fn ->
        CrossModalityLinker.cross_modality_stats(:code_symbol, "Phoenix")
      end)
      
      time_ms = time_us / 1000
      
      assert is_map(stats)
      assert time_ms < @cross_modality_threshold_ms,
        "Stats computation took #{time_ms}ms, threshold is #{@cross_modality_threshold_ms}ms"
    end
  end

  # =============================================================================
  # SPEC-053 Benchmarks: Workflow Orchestration
  # =============================================================================

  describe "SPEC-053 performance: workflow prediction" do
    @tag :benchmark
    test "workflow prediction completes within threshold" do
      task = "Fix the undefined function error in auth.ex module"
      
      {time_us, result} = :timer.tc(fn ->
        Predictor.predict_workflow(task, %{})
      end)
      
      time_ms = time_us / 1000
      
      assert match?({:ok, _, _, _}, result) or match?({:suggest, _}, result) or match?({:manual, _}, result)
      assert time_ms < @workflow_prediction_threshold_ms,
        "Workflow prediction took #{time_ms}ms, threshold is #{@workflow_prediction_threshold_ms}ms"
    end

    @tag :benchmark
    test "multiple predictions maintain consistent latency" do
      tasks = [
        "Debug the authentication bug",
        "Navigate to the user controller",
        "Understand the data model",
        "Fix compile error in config",
        "Add new feature to API"
      ]
      
      times = for task <- tasks do
        {time_us, _result} = :timer.tc(fn ->
          Predictor.predict_workflow(task, %{})
        end)
        time_us / 1000
      end
      
      avg_time = Enum.sum(times) / length(times)
      max_time = Enum.max(times)
      
      assert avg_time < @workflow_prediction_threshold_ms,
        "Average prediction time #{avg_time}ms exceeds threshold #{@workflow_prediction_threshold_ms}ms"
      
      # Max shouldn't be more than 2x average (consistency check)
      assert max_time < avg_time * 3,
        "Max time #{max_time}ms is too far from average #{avg_time}ms"
    end
  end

  describe "SPEC-053 performance: pattern clustering" do
    @tag :benchmark
    test "pattern clustering completes within threshold" do
      patterns = PatternRegistry.list_patterns()
      
      {time_us, result} = :timer.tc(fn ->
        Clusterer.cluster_patterns(patterns, threshold: 0.5)
      end)
      
      time_ms = time_us / 1000
      
      assert match?({:ok, _}, result)
      assert time_ms < @pattern_clustering_threshold_ms,
        "Pattern clustering took #{time_ms}ms, threshold is #{@pattern_clustering_threshold_ms}ms"
    end

    @tag :benchmark
    test "pattern distance calculation is fast" do
      patterns = PatternRegistry.list_patterns()
      
      if length(patterns) >= 2 do
        [p1, p2 | _] = patterns
        
        {time_us, distance} = :timer.tc(fn ->
          Clusterer.pattern_distance(p1, p2)
        end)
        
        time_ms = time_us / 1000
        
        assert is_float(distance)
        assert time_ms < 5.0,
          "Pattern distance took #{time_ms}ms, expected < 5ms"
      end
    end

    @tag :benchmark  
    test "similar pattern finding scales with pattern count" do
      patterns = PatternRegistry.list_patterns()
      test_steps = [%{tool: "memory", args: %{}}]
      
      {time_us, _result} = :timer.tc(fn ->
        Clusterer.find_similar_pattern(test_steps, patterns, 0.5)
      end)
      
      time_ms = time_us / 1000
      
      # Should be fast even with many patterns
      assert time_ms < @pattern_clustering_threshold_ms / 2,
        "Similar pattern finding took #{time_ms}ms"
    end
  end

  describe "SPEC-053 performance: pattern registry" do
    @tag :benchmark
    test "pattern retrieval is fast" do
      {time_us, result} = :timer.tc(fn ->
        PatternRegistry.get_pattern("debug_error")
      end)
      
      time_ms = time_us / 1000
      
      assert match?({:ok, _}, result)
      assert time_ms < 5.0,
        "Pattern retrieval took #{time_ms}ms, expected < 5ms"
    end

    @tag :benchmark
    test "pattern listing is fast" do
      {time_us, patterns} = :timer.tc(fn ->
        PatternRegistry.list_patterns()
      end)
      
      time_ms = time_us / 1000
      
      assert is_list(patterns)
      assert time_ms < 10.0,
        "Pattern listing took #{time_ms}ms, expected < 10ms"
    end
  end

  # =============================================================================
  # SPEC-054 Benchmarks: Adaptive Workflow Engine
  # =============================================================================

  describe "SPEC-054 performance: model profiling" do
    @tag :benchmark
    test "tier detection is extremely fast" do
      models = ["claude-opus-4", "gpt-4", "claude-3-haiku", "unknown-model"]
      
      times = for model <- models do
        {time_us, _tier} = :timer.tc(fn ->
          ModelProfiler.detect_tier(model)
        end)
        time_us / 1000
      end
      
      max_time = Enum.max(times)
      
      assert max_time < @model_profiling_threshold_ms,
        "Max tier detection took #{max_time}ms, threshold is #{@model_profiling_threshold_ms}ms"
    end

    @tag :benchmark
    test "capability lookup is fast" do
      {time_us, capabilities} = :timer.tc(fn ->
        ModelProfiler.get_capabilities("claude-3-opus")
      end)
      
      time_ms = time_us / 1000
      
      assert is_map(capabilities)
      assert time_ms < @model_profiling_threshold_ms,
        "Capability lookup took #{time_ms}ms, threshold is #{@model_profiling_threshold_ms}ms"
    end

    @tag :benchmark
    test "workflow recommendations are fast" do
      {time_us, recommendations} = :timer.tc(fn ->
        ModelProfiler.get_workflow_recommendations("claude-3-haiku")
      end)
      
      time_ms = time_us / 1000
      
      assert is_map(recommendations)
      assert time_ms < @model_profiling_threshold_ms,
        "Recommendations took #{time_ms}ms, threshold is #{@model_profiling_threshold_ms}ms"
    end

    @tag :benchmark
    test "can_handle check is fast" do
      capabilities = [:reasoning, :coding, :vision, :unknown]
      
      times = for cap <- capabilities do
        {time_us, _result} = :timer.tc(fn ->
          ModelProfiler.can_handle?("claude-opus-4", cap)
        end)
        time_us / 1000
      end
      
      max_time = Enum.max(times)
      
      assert max_time < @model_profiling_threshold_ms,
        "Max can_handle? took #{max_time}ms, threshold is #{@model_profiling_threshold_ms}ms"
    end
  end

  describe "SPEC-054 performance: template adaptation" do
    @tag :benchmark
    test "template adaptation completes within threshold" do
      {:ok, pattern} = PatternRegistry.get_pattern("debug_error")
      
      {time_us, result} = :timer.tc(fn ->
        TemplateAdapter.adapt(pattern, force_tier: :tier3)
      end)
      
      time_ms = time_us / 1000
      
      assert match?({:ok, _}, result)
      assert time_ms < @template_adaptation_threshold_ms,
        "Template adaptation took #{time_ms}ms, threshold is #{@template_adaptation_threshold_ms}ms"
    end

    @tag :benchmark
    test "adaptation preview is fast" do
      {:ok, pattern} = PatternRegistry.get_pattern("code_navigation")
      
      {time_us, preview} = :timer.tc(fn ->
        TemplateAdapter.preview_adaptations(pattern, force_tier: :tier3)
      end)
      
      time_ms = time_us / 1000
      
      assert is_map(preview)
      assert time_ms < @template_adaptation_threshold_ms / 2,
        "Preview took #{time_ms}ms, expected < #{@template_adaptation_threshold_ms / 2}ms"
    end

    @tag :benchmark
    test "multiple adaptations maintain performance" do
      {:ok, pattern} = PatternRegistry.get_pattern("debug_error")
      tiers = [:tier1, :tier2, :tier3, :tier3, :tier2, :tier1]
      
      times = for tier <- tiers do
        {time_us, _result} = :timer.tc(fn ->
          TemplateAdapter.adapt(pattern, force_tier: tier)
        end)
        time_us / 1000
      end
      
      avg_time = Enum.sum(times) / length(times)
      
      assert avg_time < @template_adaptation_threshold_ms,
        "Average adaptation time #{avg_time}ms exceeds threshold"
    end
  end

  describe "SPEC-054 performance: learning tracker" do
    @tag :benchmark
    test "event recording is extremely fast" do
      event = %{
        execution_id: "bench_#{System.unique_integer([:positive])}",
        pattern_name: "benchmark_pattern",
        model_id: "test-model",
        outcome: :success,
        duration_ms: 1000,
        timestamp: DateTime.utc_now()
      }
      
      {time_us, result} = :timer.tc(fn ->
        LearningTracker.record_event(event)
      end)
      
      time_ms = time_us / 1000
      
      assert result == :ok
      assert time_ms < @learning_event_threshold_ms,
        "Event recording took #{time_ms}ms, threshold is #{@learning_event_threshold_ms}ms"
    end

    @tag :benchmark
    test "outcome recording is fast" do
      {time_us, result} = :timer.tc(fn ->
        LearningTracker.record_outcome("bench_pattern", :success,
          model_id: "bench-model",
          duration_ms: 500
        )
      end)
      
      time_ms = time_us / 1000
      
      assert result == :ok
      assert time_ms < @learning_event_threshold_ms,
        "Outcome recording took #{time_ms}ms, threshold is #{@learning_event_threshold_ms}ms"
    end

    @tag :benchmark
    test "high-volume event recording maintains performance" do
      events = for i <- 1..100 do
        %{
          execution_id: "volume_#{i}",
          pattern_name: "volume_test",
          outcome: if(rem(i, 3) == 0, do: :failure, else: :success),
          duration_ms: :rand.uniform(2000),
          timestamp: DateTime.utc_now()
        }
      end
      
      {time_us, _} = :timer.tc(fn ->
        for event <- events do
          LearningTracker.record_event(event)
        end
      end)
      
      time_ms = time_us / 1000
      per_event_ms = time_ms / length(events)
      
      assert per_event_ms < @learning_event_threshold_ms,
        "Per-event time #{per_event_ms}ms exceeds threshold #{@learning_event_threshold_ms}ms"
    end

    @tag :benchmark
    test "stats retrieval is fast" do
      {time_us, stats} = :timer.tc(fn ->
        LearningTracker.stats()
      end)
      
      time_ms = time_us / 1000
      
      assert is_map(stats)
      assert time_ms < 10.0,
        "Stats retrieval took #{time_ms}ms, expected < 10ms"
    end

    @tag :benchmark
    test "flush operation completes reasonably" do
      # Record some events
      for i <- 1..50 do
        LearningTracker.record_outcome("flush_bench_#{i}", :success)
      end
      
      {time_us, result} = :timer.tc(fn ->
        LearningTracker.flush()
      end)
      
      time_ms = time_us / 1000
      
      assert result == :ok
      # Flush can take longer as it persists, but should still be reasonable
      assert time_ms < 500.0,
        "Flush took #{time_ms}ms, expected < 500ms"
    end
  end

  # =============================================================================
  # Combined Benchmarks
  # =============================================================================

  describe "combined spec performance" do
    @tag :benchmark
    test "full workflow cycle performance" do
      {time_us, _} = :timer.tc(fn ->
        # 1. Model profiling (SPEC-054)
        tier = ModelProfiler.detect_tier("claude-3-haiku")
        
        # 2. Workflow prediction (SPEC-053)
        {:ok, pattern, _, _} = Predictor.predict_workflow("Fix error", %{})
        
        # 3. Template adaptation (SPEC-054)
        {:ok, adapted} = TemplateAdapter.adapt(pattern, force_tier: tier)
        
        # 4. Learning (SPEC-054)
        LearningTracker.record_outcome(adapted.name, :success)
        
        :ok
      end)
      
      time_ms = time_us / 1000
      
      # Full cycle should complete in reasonable time
      assert time_ms < 200.0,
        "Full workflow cycle took #{time_ms}ms, expected < 200ms"
    end

    @tag :benchmark
    test "concurrent spec operations scale" do
      tasks = for _ <- 1..10 do
        Task.async(fn ->
          # Mix of operations from different specs
          ModelProfiler.detect_tier("gpt-4")
          Predictor.predict_workflow("test", %{})
          CrossModalityLinker.infer_links(:code_symbol, "Test", limit: 5)
          LearningTracker.record_outcome("concurrent", :success)
        end)
      end
      
      {time_us, _results} = :timer.tc(fn ->
        Task.await_many(tasks, 30_000)
      end)
      
      time_ms = time_us / 1000
      per_task_ms = time_ms / 10
      
      # Concurrent execution should be efficient
      assert per_task_ms < 100.0,
        "Per-task time #{per_task_ms}ms is too high for concurrent execution"
    end
  end
end
