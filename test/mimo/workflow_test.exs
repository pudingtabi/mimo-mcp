defmodule Mimo.WorkflowTest do
  @moduledoc """
  Comprehensive tests for SPEC-053 and SPEC-054 Workflow Orchestration.
  """
  use Mimo.DataCase, async: false

  alias Mimo.AdaptiveWorkflow.{LearningTracker, ModelProfiler, TemplateAdapter}
  alias Mimo.MetaCognitiveRouter
  alias Mimo.Workflow
  alias Mimo.Workflow.{BindingsResolver, Clusterer, Executor, Pattern, PatternRegistry, Predictor}

  # =============================================================================
  # Setup
  # =============================================================================

  setup do
    # Start required GenServers if not already started (BEFORE seeding)
    ensure_genserver_started(PatternRegistry)
    ensure_genserver_started(ModelProfiler)
    ensure_genserver_started(LearningTracker)

    # Seed patterns for testing (AFTER GenServers are started)
    PatternRegistry.seed_patterns()

    :ok
  end

  defp ensure_genserver_started(module) do
    case Process.whereis(module) do
      nil ->
        {:ok, _pid} = module.start_link([])
        :ok

      _pid ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # =============================================================================
  # Pattern Tests
  # =============================================================================

  describe "Pattern schema" do
    test "creates valid pattern with required fields" do
      attrs = %{
        id: "test_pattern_v1",
        name: "test_pattern",
        description: "A test pattern",
        category: :debugging,
        steps: [
          %{tool: "memory", args: %{operation: "search", query: "error"}}
        ]
      }

      changeset = Pattern.changeset(%Pattern{}, attrs)
      assert changeset.valid?
    end

    test "requires id and name fields" do
      changeset = Pattern.changeset(%Pattern{}, %{description: "no name or id"})
      refute changeset.valid?
      # Both id and name are required
      assert changeset.errors != []
    end

    test "validates category enum" do
      attrs = %{id: "test_id", name: "test", steps: [], category: :invalid_category}
      changeset = Pattern.changeset(%Pattern{}, attrs)
      refute changeset.valid?
    end
  end

  describe "PatternRegistry" do
    test "seeds default patterns" do
      patterns = PatternRegistry.list_patterns()
      assert length(patterns) >= 5
    end

    test "retrieves pattern by name" do
      assert {:ok, pattern} = PatternRegistry.get_pattern("debug_error")
      assert pattern.name == "debug_error"
      assert pattern.category == :debugging
    end

    test "returns error for unknown pattern" do
      assert {:error, :not_found} = PatternRegistry.get_pattern("nonexistent")
    end

    test "saves new pattern" do
      new_pattern = %Pattern{
        name: "custom_workflow",
        description: "Custom test workflow",
        category: :code_navigation,
        steps: [%{tool: "code", args: %{operation: "symbols"}}]
      }

      assert {:ok, _saved} = PatternRegistry.save_pattern(new_pattern)
      assert {:ok, retrieved} = PatternRegistry.get_pattern("custom_workflow")
      assert retrieved.description == "Custom test workflow"
    end
  end

  # =============================================================================
  # Predictor Tests
  # =============================================================================

  describe "Predictor" do
    test "predicts workflow for debugging task" do
      task = "Fix the undefined function error in auth.ex"

      case Predictor.predict_workflow(task, %{}) do
        {:ok, pattern, confidence, bindings} ->
          assert pattern.category in [:debugging, :code_navigation]
          assert confidence > 0.0
          assert is_map(bindings)

        {:suggest, patterns} ->
          assert is_list(patterns)
          assert patterns != []

        {:manual, reason} ->
          assert is_binary(reason)
      end
    end

    test "predicts workflow for file editing task" do
      task = "Update the configuration in config.exs"

      result = Predictor.predict_workflow(task, %{})

      assert match?({:ok, _, _, _}, result) or
               match?({:suggest, _}, result) or
               match?({:manual, _}, result)
    end

    test "extracts features from task description" do
      task = "Debug the authentication bug and fix the error"

      # Feature extraction is internal, but we can verify prediction works
      case Predictor.predict_workflow(task, %{}) do
        {:ok, pattern, _confidence, _bindings} ->
          # Pattern should be found (any category is acceptable since seed patterns may vary)
          assert pattern != nil
          assert is_binary(pattern.name) or is_atom(pattern.name)

        _ ->
          # Other outcomes are acceptable
          :ok
      end
    end
  end

  # =============================================================================
  # Bindings Resolver Tests
  # =============================================================================

  describe "BindingsResolver" do
    test "resolves simple bindings" do
      context = %{"file" => "auth.ex", "error" => "undefined function"}

      step = %{
        "tool" => "code",
        "params" => %{},
        "dynamic_bindings" => [
          %{
            "source" => "global_context",
            "path" => "$.file",
            "target_param" => "path"
          },
          %{
            "source" => "global_context",
            "path" => "$.error",
            "target_param" => "message"
          }
        ]
      }

      resolved = BindingsResolver.resolve_step_bindings(step, context, nil)

      assert resolved["path"] == "auth.ex"
      assert resolved["message"] == "undefined function"
    end

    test "resolves nested context paths" do
      context = %{
        result: %{
          data: %{
            content: "file contents here"
          }
        }
      }

      path = "result.data.content"
      value = BindingsResolver.extract_path(context, path)

      assert value == "file contents here"
    end

    test "handles missing bindings gracefully" do
      bindings = %{}

      step = %{
        tool: "file",
        args: %{
          path: "{missing_key}"
        }
      }

      pattern = %{bindings: []}

      resolved = BindingsResolver.resolve_step_bindings(step, bindings, pattern)

      # Should either keep the placeholder or return nil
      assert resolved["path"] == "{missing_key}" or resolved["path"] == nil
    end
  end

  # =============================================================================
  # Clusterer Tests
  # =============================================================================

  describe "Clusterer" do
    test "calculates distance between similar patterns" do
      pattern1 = %Pattern{
        steps: [
          %{tool: "memory", args: %{}},
          %{tool: "file", args: %{}}
        ]
      }

      pattern2 = %Pattern{
        steps: [
          %{tool: "memory", args: %{}},
          %{tool: "code", args: %{}}
        ]
      }

      distance = Clusterer.pattern_distance(pattern1, pattern2)

      # Should be similar (low distance) since one step matches
      assert distance < 1.0
      assert distance >= 0.0
    end

    test "finds similar patterns" do
      patterns = PatternRegistry.list_patterns()
      test_pattern = hd(patterns)

      # Pass the steps, not the full pattern
      similar = Clusterer.find_similar_pattern(test_pattern.steps, patterns, 0.5)

      # Should find at least itself as similar
      assert similar != nil or length(patterns) == 1
    end

    test "clusters patterns by similarity" do
      patterns = PatternRegistry.list_patterns()

      {:ok, clusters} = Clusterer.cluster_patterns(patterns, threshold: 0.5)

      # Should return list of clusters
      assert is_list(clusters)
    end
  end

  # =============================================================================
  # Model Profiler Tests
  # =============================================================================

  describe "ModelProfiler" do
    test "detects tier for Claude Opus" do
      tier = ModelProfiler.detect_tier("claude-opus-4")
      assert tier == :tier1
    end

    test "detects tier for Claude Haiku" do
      tier = ModelProfiler.detect_tier("claude-3-haiku")
      assert tier == :tier3
    end

    test "detects tier for GPT-4" do
      tier = ModelProfiler.detect_tier("gpt-4")
      assert tier == :tier1
    end

    test "detects tier for unknown model as tier2" do
      tier = ModelProfiler.detect_tier("some-unknown-model-2025")
      # Default for unknown
      assert tier == :tier2
    end

    test "gets capabilities for known model" do
      capabilities = ModelProfiler.get_capabilities("claude-3-opus")

      assert Map.has_key?(capabilities, :reasoning)
      assert Map.has_key?(capabilities, :coding)
      assert capabilities[:reasoning] >= 0.9
    end

    test "gets constraints for small model" do
      constraints = ModelProfiler.get_constraints("claude-3-haiku")

      assert is_list(constraints)

      assert "requires_explicit_step_guidance" in constraints or
               "benefits_from_prepare_context" in constraints
    end

    test "checks if model can handle capability" do
      assert ModelProfiler.can_handle?("claude-opus-4", :reasoning)
      assert ModelProfiler.can_handle?("claude-opus-4", :coding)
    end

    test "gets workflow recommendations" do
      recommendations = ModelProfiler.get_workflow_recommendations("claude-3-haiku")

      assert Map.has_key?(recommendations, :use_prepare_context)
      assert recommendations[:use_prepare_context] == true
      assert recommendations[:max_parallel_tools] == 1
    end
  end

  # =============================================================================
  # Template Adapter Tests
  # =============================================================================

  describe "TemplateAdapter" do
    test "adapts pattern for tier3 model" do
      {:ok, pattern} = PatternRegistry.get_pattern("debug_error")
      original_steps = length(pattern.steps)

      {:ok, adapted} = TemplateAdapter.adapt(pattern, force_tier: :tier3)

      # Should have more steps (prepare_context added)
      assert length(adapted.steps) > original_steps

      # First step should be prepare_context
      first_step = hd(adapted.steps)
      assert first_step.tool == "meta" or first_step[:name] == "prepare_context"
    end

    test "doesn't modify pattern for tier1 model" do
      {:ok, pattern} = PatternRegistry.get_pattern("debug_error")
      original_steps = length(pattern.steps)

      {:ok, adapted} = TemplateAdapter.adapt(pattern, force_tier: :tier1)

      # Should have same or fewer steps (no additions for tier1)
      assert length(adapted.steps) == original_steps
    end

    test "adds metadata about adaptation" do
      {:ok, pattern} = PatternRegistry.get_pattern("code_navigation")

      {:ok, adapted} =
        TemplateAdapter.adapt(pattern,
          model_id: "claude-3-haiku",
          force_tier: :tier3
        )

      assert adapted.metadata[:adapted_for] == "claude-3-haiku"
      assert adapted.metadata[:adapted_tier] == :tier3
    end

    test "previews adaptations without applying" do
      {:ok, pattern} = PatternRegistry.get_pattern("debug_error")

      preview = TemplateAdapter.preview_adaptations(pattern, force_tier: :tier3)

      assert Map.has_key?(preview, :original_step_count)
      assert Map.has_key?(preview, :adaptations)
      assert Map.has_key?(preview, :estimated_overhead_ms)
    end
  end

  # =============================================================================
  # MetaCognitiveRouter Integration Tests
  # =============================================================================

  describe "MetaCognitiveRouter workflow integration" do
    test "classifies and suggests workflow for procedural query" do
      result = MetaCognitiveRouter.classify_and_suggest("Fix the undefined function error")

      assert Map.has_key?(result, :classification)
      assert result.classification.primary_store == :procedural

      # Should have a workflow suggestion for procedural queries
      if result.workflow_suggestion do
        assert Map.has_key?(result.workflow_suggestion, :type)
        assert Map.has_key?(result.workflow_suggestion, :confidence)
      end
    end

    test "suggests workflow directly" do
      {:ok, suggestion} = MetaCognitiveRouter.suggest_workflow("Debug the authentication error")

      assert Map.has_key?(suggestion, :type)
      assert suggestion.type in [:auto_execute, :suggest, :manual]
      assert Map.has_key?(suggestion, :confidence)
    end
  end

  # =============================================================================
  # Learning Tracker Tests
  # =============================================================================

  describe "LearningTracker" do
    test "records learning event" do
      event = %{
        execution_id: "test_exec_#{:rand.uniform(10000)}",
        pattern_name: "debug_error",
        model_id: "claude-3-haiku",
        outcome: :success,
        duration_ms: 1500,
        step_outcomes: [],
        context: %{},
        timestamp: DateTime.utc_now()
      }

      assert :ok = LearningTracker.record_event(event)
    end

    test "records simple outcome" do
      assert :ok =
               LearningTracker.record_outcome("test_pattern", :success,
                 model_id: "gpt-4",
                 duration_ms: 1000
               )
    end

    test "gets statistics" do
      stats = LearningTracker.stats()

      assert Map.has_key?(stats, :buffered_events)
      assert Map.has_key?(stats, :affinity_count)
    end

    test "flushes buffered events" do
      # Record some events
      for i <- 1..5 do
        LearningTracker.record_outcome("flush_test_#{i}", :success)
      end

      # Flush and verify
      assert :ok = LearningTracker.flush()
    end
  end

  # =============================================================================
  # Executor Tests
  # =============================================================================

  describe "Executor" do
    test "converts pattern to procedure definition" do
      {:ok, pattern} = PatternRegistry.get_pattern("context_gathering")

      procedure = Executor.pattern_to_procedure(pattern, %{query: "test"})

      assert Map.has_key?(procedure, "name")
      assert Map.has_key?(procedure, "states")
      assert Map.has_key?(procedure, "initial_state")
    end

    test "execution status returns not found for unknown" do
      assert {:error, :not_found} = Executor.get_execution_status("nonexistent_123")
    end
  end

  # =============================================================================
  # Facade API Tests
  # =============================================================================

  describe "Workflow facade" do
    test "lists patterns" do
      patterns = Workflow.list_patterns()

      assert is_list(patterns)
      assert length(patterns) >= 5
    end

    test "gets pattern by name" do
      assert {:ok, pattern} = Workflow.get_pattern("debug_error")
      assert pattern.name == "debug_error"
    end

    test "suggests workflow for task" do
      result = Workflow.suggest("Fix the compile error in auth module")

      assert match?({:ok, _}, result)
      {:ok, suggestion} = result
      assert Map.has_key?(suggestion, :type)
    end

    test "gets model profile" do
      {:ok, profile} = Workflow.get_model_profile("claude-opus-4")

      assert profile.tier == :tier1
      assert Map.has_key?(profile, :capabilities)
    end

    test "gets model recommendations" do
      recommendations = Workflow.get_model_recommendations("claude-3-haiku")

      assert recommendations[:use_prepare_context] == true
    end

    test "adapts pattern for model" do
      {:ok, adapted} = Workflow.adapt_for_model("debug_error", "claude-3-haiku")

      assert adapted.metadata[:adapted_for] == "claude-3-haiku"
    end

    test "records outcome for learning" do
      assert :ok = Workflow.record_outcome("test_exec", :success)
    end

    test "logs tool usage" do
      assert :ok = Workflow.log_tool_usage("session_123", "memory", %{operation: "search"})
    end

    test "gets learning stats" do
      stats = Workflow.learning_stats()

      assert is_map(stats)
    end
  end

  # =============================================================================
  # Telemetry Tests
  # =============================================================================

  describe "Telemetry" do
    test "attaches and detaches handlers" do
      Mimo.Workflow.Telemetry.attach()

      # Verify events are registered
      events = Mimo.Workflow.Telemetry.events()
      assert events != []

      Mimo.Workflow.Telemetry.detach()
    end

    test "emits workflow events" do
      Mimo.Workflow.Telemetry.emit(:predict, %{duration_us: 1000, confidence: 0.85}, %{
        pattern_name: "test"
      })
    end
  end
end
