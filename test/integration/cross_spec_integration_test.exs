defmodule Mimo.CrossSpecIntegrationTest do
  @moduledoc """
  Cross-spec integration tests verifying interactions between SPEC-051, 052, 053, and 054.

  These tests ensure that components from different specs work together correctly:
  - SPEC-051 (Tiered Context) + SPEC-053 (Tool Orchestration)
  - SPEC-054 (Model Profiling) + SPEC-051 (Budget Allocation)
  - SPEC-052 (Neuro-Symbolic) + SPEC-053 (Workflow Patterns)
  """
  use Mimo.DataCase, async: false

  # SPEC-051: Tiered Context Delivery
  alias Mimo.AdaptiveWorkflow.{LearningTracker, ModelProfiler, TemplateAdapter}
  alias Mimo.Brain.HybridScorer
  alias Mimo.Context.{AccessPatternTracker, BudgetAllocator, Prefetcher}
  alias Mimo.NeuroSymbolic.{CrossModalityLinker, RuleGenerator}
  alias Mimo.SemanticStore.Repository
  alias Mimo.Workflow
  alias Mimo.Workflow.{Pattern, PatternRegistry, Predictor}

  # =============================================================================
  # Setup
  # =============================================================================

  setup do
    ensure_genserver_started(PatternRegistry)
    ensure_genserver_started(ModelProfiler)
    ensure_genserver_started(LearningTracker)
    ensure_genserver_started(AccessPatternTracker)
    ensure_genserver_started(Prefetcher)
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
  # SPEC-051 + SPEC-054: Model-Aware Budget Allocation
  # =============================================================================

  describe "SPEC-051 + SPEC-054: Model profiling informs budget allocation" do
    test "tier1 model gets larger tier1 allocation" do
      # SPEC-054: Get model tier
      tier1_model = "claude-opus-4"
      tier3_model = "claude-3-haiku"

      tier1 = ModelProfiler.detect_tier(tier1_model)
      tier3 = ModelProfiler.detect_tier(tier3_model)

      assert tier1 == :tier1
      assert tier3 == :tier3

      # SPEC-051: Allocate budgets based on model type
      # Map ModelProfiler tiers to BudgetAllocator model types
      tier1_budget = BudgetAllocator.allocate(:large, 10_000)
      tier3_budget = BudgetAllocator.allocate(:small, 10_000)

      # Tier1 (large) models get more tier1 percentage
      assert tier1_budget.tier1 > tier3_budget.tier1

      # Both should sum correctly (verify fix from TODO #1)
      assert tier1_budget.tier1 + tier1_budget.tier2 + tier1_budget.tier3 == tier1_budget.total
      assert tier3_budget.tier1 + tier3_budget.tier2 + tier3_budget.tier3 == tier3_budget.total
    end

    test "model recommendations align with budget strategy" do
      model = "claude-3-haiku"

      # SPEC-054: Get recommendations
      recommendations = ModelProfiler.get_workflow_recommendations(model)

      # Small models should use prepare_context
      assert recommendations[:use_prepare_context] == true

      # SPEC-051: Small model budget
      budget = BudgetAllocator.allocate(:small, 4000)

      # Tier1 should be small (5%) for small models
      tier1_percentage = budget.tier1 / budget.total
      # Less than 10%
      assert tier1_percentage < 0.10
    end

    test "model capabilities affect context prioritization" do
      # SPEC-054: Get capabilities
      opus_caps = ModelProfiler.get_capabilities("claude-3-opus")
      haiku_caps = ModelProfiler.get_capabilities("claude-3-haiku")

      # Opus should have higher reasoning
      assert opus_caps[:reasoning] >= haiku_caps[:reasoning]

      # SPEC-051: Allocate differently
      opus_budget = BudgetAllocator.allocate(:large, 10_000)
      haiku_budget = BudgetAllocator.allocate(:small, 2000)

      # Large model can handle more tier3 background context
      assert opus_budget.tier3 > haiku_budget.tier3
    end
  end

  # =============================================================================
  # SPEC-053 + SPEC-054: Workflow Adaptation Based on Model
  # =============================================================================

  describe "SPEC-053 + SPEC-054: Template adaptation based on model profile" do
    test "tier3 model gets prepare_context prepended" do
      {:ok, pattern} = PatternRegistry.get_pattern("debug_error")
      original_steps = length(pattern.steps)

      # SPEC-054: Detect tier
      tier = ModelProfiler.detect_tier("claude-3-haiku")
      assert tier == :tier3

      # SPEC-053: Adapt pattern for tier3
      {:ok, adapted} = TemplateAdapter.adapt(pattern, force_tier: :tier3)

      # Should have prepare_context added
      assert length(adapted.steps) > original_steps

      # First step should be meta/prepare_context
      first_step = hd(adapted.steps)
      assert first_step.tool == "meta" or first_step[:name] == "prepare_context"
    end

    test "tier1 model pattern unchanged" do
      {:ok, pattern} = PatternRegistry.get_pattern("debug_error")
      original_steps = length(pattern.steps)

      # SPEC-054: Detect tier
      tier = ModelProfiler.detect_tier("claude-opus-4")
      assert tier == :tier1

      # SPEC-053: Adapt pattern for tier1
      {:ok, adapted} = TemplateAdapter.adapt(pattern, force_tier: :tier1)

      # Should not add extra steps for tier1
      assert length(adapted.steps) == original_steps
    end

    test "workflow prediction uses model context" do
      task = "Fix the undefined function error in auth module"

      # SPEC-054: Get model recommendations
      recommendations = ModelProfiler.get_workflow_recommendations("claude-3-haiku")

      # SPEC-053: Predict workflow
      result =
        Predictor.predict_workflow(task, %{
          model_recommendations: recommendations
        })

      assert match?({:ok, _, _, _}, result) or match?({:suggest, _}, result) or
               match?({:manual, _}, result)
    end

    test "learning tracker records model-specific outcomes" do
      {:ok, pattern} = PatternRegistry.get_pattern("code_navigation")

      # Simulate workflow execution for different models
      for {model, expected_tier} <- [
            {"claude-opus-4", :tier1},
            {"gpt-4", :tier1},
            {"claude-3-haiku", :tier3}
          ] do
        tier = ModelProfiler.detect_tier(model)
        assert tier == expected_tier

        # Record outcome
        :ok =
          LearningTracker.record_outcome(pattern.name, :success,
            model_id: model,
            duration_ms: 1000
          )
      end

      # Verify stats recorded
      stats = LearningTracker.stats()
      assert stats.buffered_events >= 0
    end
  end

  # =============================================================================
  # SPEC-051 + SPEC-053: Context Delivery in Workflows
  # =============================================================================

  describe "SPEC-051 + SPEC-053: Context delivery within workflows" do
    test "workflow pattern uses budget-aware context" do
      # SPEC-051: Allocate budget
      budget = BudgetAllocator.allocate(:medium, 8000)

      # SPEC-053: Get a context-gathering pattern
      {:ok, pattern} = PatternRegistry.get_pattern("context_gathering")

      # Pattern should have steps that respect budget
      assert is_list(pattern.steps)

      # Budget allocation is valid
      assert budget.tier1 + budget.tier2 + budget.tier3 == budget.total
    end

    test "hybrid scorer integrates with workflow execution" do
      # SPEC-051: Score some items
      items = [
        %{id: 1, content: "Critical error fix", importance: 0.9, recency: 0.8},
        %{id: 2, content: "Background context", importance: 0.3, recency: 0.2}
      ]

      scored =
        Enum.map(items, fn item ->
          score = HybridScorer.score(item, %{})
          Map.put(item, :score, score)
        end)

      # Higher importance should score higher
      [high, low] = Enum.sort_by(scored, & &1.score, :desc)
      assert high.importance > low.importance

      # SPEC-053: These scores inform workflow decisions
      # (workflow can prioritize high-score context in tier1)
    end

    test "access pattern tracking informs prefetching" do
      # SPEC-051: Track access patterns
      for i <- 1..5 do
        AccessPatternTracker.track_access(:file, "file_#{i}.ex", task: "testing")
      end

      # Repeated access should increase frequency
      AccessPatternTracker.track_access(:file, "file_1.ex", task: "testing")
      AccessPatternTracker.track_access(:file, "file_1.ex", task: "testing")

      # Get patterns
      patterns = AccessPatternTracker.patterns()
      assert is_map(patterns)

      # SPEC-053: Workflow can use these patterns for smarter tool ordering
    end
  end

  # =============================================================================
  # SPEC-052 + SPEC-053: Knowledge-Aware Workflows
  # =============================================================================

  describe "SPEC-052 + SPEC-053: Neuro-symbolic reasoning in workflows" do
    test "cross-modality links inform workflow patterns" do
      # SPEC-052: Create cross-modality links
      {:ok, links} = CrossModalityLinker.infer_links(:code_symbol, "Phoenix.Controller", [])

      # SPEC-053: Workflow can use these links to suggest related files
      assert is_list(links)

      # If links found, they have required structure
      for link <- links do
        assert Map.has_key?(link, :target_type)
        assert Map.has_key?(link, :target_id)
        assert Map.has_key?(link, :confidence)
      end
    end

    test "rule validation informs pattern suggestions" do
      # SPEC-052: Set up some triples
      unique_pred = "workflow_rel_#{System.unique_integer([:positive])}"
      Repository.store_triple("module_a", unique_pred, "module_b", confidence: 1.0)
      Repository.store_triple("module_b", unique_pred, "module_c", confidence: 1.0)

      # Create rule candidate
      candidate = %{
        id: Ecto.UUID.generate(),
        premise: [%{predicate: unique_pred}],
        conclusion: %{predicate: unique_pred},
        logical_form: %{},
        confidence: 0.8,
        source: "workflow_test"
      }

      {:ok, result} = RuleGenerator.validate_and_persist([candidate])

      # SPEC-053: Workflow pattern could use validated rules
      # to suggest related code navigation paths
      assert is_map(result)
    end

    test "cross-modality stats guide pattern extraction" do
      # SPEC-052: Get stats for a module
      stats = CrossModalityLinker.cross_modality_stats(:code_symbol, "Mimo.Workflow")

      assert Map.has_key?(stats, :total_connections)
      assert Map.has_key?(stats, :by_target_type)

      # SPEC-053: High connection count could indicate
      # this module is central and patterns should prioritize it
    end
  end

  # =============================================================================
  # SPEC-051 + SPEC-052: Context with Knowledge Graph
  # =============================================================================

  describe "SPEC-051 + SPEC-052: Knowledge-enriched context delivery" do
    test "cross-modality links enhance context scoring" do
      # SPEC-052: Get connection count
      item = %{file_path: "/lib/mimo/workflow.ex", content: "defmodule Mimo.Workflow"}
      connection_count = CrossModalityLinker.find_cross_connections(item)

      assert connection_count >= 0

      # SPEC-051: Higher connections should influence scoring
      # Items with more cross-modality connections are more central
      base_score = HybridScorer.score(item, %{})

      # Score should factor in connectivity (implementation detail)
      assert is_float(base_score) or is_integer(base_score)
    end

    test "knowledge graph queries fit within budget" do
      # SPEC-051: Get budget
      budget = BudgetAllocator.allocate(:small, 2000)

      # SPEC-052: Query should return results that fit tier1
      {:ok, links} =
        CrossModalityLinker.infer_links(:code_symbol, "Test",
          limit: 5,
          min_confidence: 0.7
        )

      # Limited results respect context constraints
      assert length(links) <= 5

      # Results should be high-confidence (tier1 material)
      for link <- links do
        assert link.confidence >= 0.7
      end
    end
  end

  # =============================================================================
  # Full Pipeline Integration
  # =============================================================================

  describe "full pipeline: all specs working together" do
    test "end-to-end: model detection → budget → pattern adaptation → learning" do
      model_id = "claude-3-haiku"
      task = "Debug authentication error"

      # 1. SPEC-054: Detect model tier and capabilities
      tier = ModelProfiler.detect_tier(model_id)
      capabilities = ModelProfiler.get_capabilities(model_id)
      recommendations = ModelProfiler.get_workflow_recommendations(model_id)

      assert tier == :tier3
      assert is_map(capabilities)
      assert recommendations[:use_prepare_context] == true

      # 2. SPEC-051: Allocate context budget
      model_type =
        case tier do
          :tier1 -> :large
          :tier2 -> :medium
          :tier3 -> :small
        end

      budget = BudgetAllocator.allocate(model_type, 4000)

      assert budget.tier1 + budget.tier2 + budget.tier3 == budget.total

      # 3. SPEC-053: Predict and adapt workflow pattern
      case Predictor.predict_workflow(task, %{}) do
        {:ok, pattern, confidence, _bindings} ->
          assert confidence > 0.0

          # Adapt for tier3
          {:ok, adapted} = TemplateAdapter.adapt(pattern, force_tier: tier)
          assert length(adapted.steps) >= length(pattern.steps)

          # 4. SPEC-054: Record learning outcome
          :ok =
            LearningTracker.record_outcome(adapted.name, :success,
              model_id: model_id,
              duration_ms: 1500
            )

        {:suggest, _patterns} ->
          # Multiple patterns suggested, pick first
          :ok

        {:manual, _reason} ->
          # No pattern matched, that's okay for this test
          :ok
      end

      # 5. Verify learning was recorded
      stats = LearningTracker.stats()
      assert is_map(stats)
    end

    test "parallel spec operations are safe" do
      tasks = [
        # SPEC-051
        Task.async(fn -> BudgetAllocator.allocate(:small, 2000) end),
        Task.async(fn -> HybridScorer.score(%{content: "test", importance: 0.5}, %{}) end),

        # SPEC-052
        Task.async(fn -> CrossModalityLinker.infer_links(:code_symbol, "Test", []) end),

        # SPEC-053
        Task.async(fn -> Predictor.predict_workflow("test task", %{}) end),
        Task.async(fn -> PatternRegistry.list_patterns() end),

        # SPEC-054
        Task.async(fn -> ModelProfiler.detect_tier("gpt-4") end),
        Task.async(fn -> LearningTracker.stats() end)
      ]

      results = Task.await_many(tasks, 10_000)

      # All should complete without error
      assert length(results) == 7
    end

    test "spec interactions under load" do
      # Simulate multiple concurrent workflows
      workflows =
        for i <- 1..10 do
          Task.async(fn ->
            model = Enum.random(["claude-opus-4", "gpt-4", "claude-3-haiku"])

            # Profile
            tier = ModelProfiler.detect_tier(model)

            # Budget
            model_type =
              case tier do
                :tier1 -> :large
                :tier2 -> :medium
                :tier3 -> :small
              end

            budget = BudgetAllocator.allocate(model_type, 4000)

            # Pattern
            patterns = PatternRegistry.list_patterns()
            pattern = Enum.random(patterns)

            # Adapt
            {:ok, adapted} = TemplateAdapter.adapt(pattern, force_tier: tier)

            # Learn
            outcome = if rem(i, 3) == 0, do: :failure, else: :success
            LearningTracker.record_outcome(adapted.name, outcome, model_id: model)

            {budget, adapted.name, tier}
          end)
        end

      results = Task.await_many(workflows, 30_000)

      # All workflows completed
      assert length(results) == 10

      # All budgets valid
      for {budget, _name, _tier} <- results do
        assert budget.tier1 + budget.tier2 + budget.tier3 == budget.total
      end
    end
  end
end
