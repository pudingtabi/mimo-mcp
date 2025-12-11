defmodule Mimo.Tools.Dispatchers.Cognitive do
  @moduledoc """
  Cognitive operations dispatcher.

  Handles epistemic uncertainty and meta-cognitive operations:
  - assess: Evaluate confidence (Cognitive.ConfidenceAssessor.assess)
  - gaps: Detect knowledge gaps (Cognitive.GapDetector.analyze)
  - query: Full epistemic query (Cognitive.EpistemicBrain.query + CalibratedResponse)
  - can_answer: Check if topic is answerable (Cognitive.EpistemicBrain.can_answer?)
  - suggest: Get learning suggestions (Cognitive.UncertaintyTracker.suggest_learning_targets)
  - stats: Tracker statistics (Cognitive.UncertaintyTracker.stats)

  Also handles the 'think' tool operations:
  - thought: Single reasoning step
  - plan: Planning with steps
  - sequential: Sequential thinking chain

  Also handles the 'reason' tool operations (SPEC-035 Unified Reasoning Engine):
  - guided: Start guided reasoning with strategy selection
  - decompose: Break problem into sub-problems
  - step: Record a reasoning step and get feedback
  - verify: Verify reasoning chain for consistency
  - reflect: Reflect on completed reasoning (Reflexion pattern)
  - branch: Create a new reasoning branch (ToT pattern)
  - backtrack: Backtrack to previous branch (ToT pattern)
  - conclude: Conclude reasoning and generate final answer
  """

  alias Mimo.Tools.Helpers
  alias Mimo.Cognitive.Reasoner

  @doc """
  Dispatch cognitive operation based on args.
  """
  def dispatch(args) do
    op = args["operation"] || "assess"

    case op do
      "assess" ->
        dispatch_assess(args)

      "gaps" ->
        dispatch_gaps(args)

      "query" ->
        dispatch_query(args)

      "can_answer" ->
        dispatch_can_answer(args)

      "suggest" ->
        dispatch_suggest(args)

      "stats" ->
        dispatch_stats()

      # SPEC-AI-TEST: Verification tracking operations
      "verification_stats" ->
        dispatch_verification_stats()

      "verification_overconfidence" ->
        dispatch_verification_overconfidence(args)

      "verification_success_by_type" ->
        dispatch_verification_success_by_type()

      "verification_brier_score" ->
        dispatch_verification_brier_score()

      # === VERIFY TOOL OPERATIONS (SPEC-AI-TEST) ===
      # Direct access to verify operations for MCP cache workaround
      "verify_count" ->
        Mimo.Tools.Dispatchers.Verify.dispatch(Map.put(args, "operation", "count"))

      "verify_math" ->
        Mimo.Tools.Dispatchers.Verify.dispatch(Map.put(args, "operation", "math"))

      "verify_logic" ->
        Mimo.Tools.Dispatchers.Verify.dispatch(Map.put(args, "operation", "logic"))

      "verify_compare" ->
        Mimo.Tools.Dispatchers.Verify.dispatch(Map.put(args, "operation", "compare"))

      "verify_self_check" ->
        Mimo.Tools.Dispatchers.Verify.dispatch(Map.put(args, "operation", "self_check"))

      # === EMERGENCE TOOL OPERATIONS (SPEC-044) ===
      # Direct access to emergence operations for MCP cache workaround
      "emergence_detect" ->
        Mimo.Tools.Dispatchers.Emergence.dispatch(Map.put(args, "operation", "detect"))

      "emergence_dashboard" ->
        Mimo.Tools.Dispatchers.Emergence.dispatch(Map.put(args, "operation", "dashboard"))

      "emergence_alerts" ->
        Mimo.Tools.Dispatchers.Emergence.dispatch(Map.put(args, "operation", "alerts"))

      "emergence_amplify" ->
        Mimo.Tools.Dispatchers.Emergence.dispatch(Map.put(args, "operation", "amplify"))

      "emergence_promote" ->
        Mimo.Tools.Dispatchers.Emergence.dispatch(Map.put(args, "operation", "promote"))

      "emergence_cycle" ->
        Mimo.Tools.Dispatchers.Emergence.dispatch(Map.put(args, "operation", "cycle"))

      "emergence_list" ->
        Mimo.Tools.Dispatchers.Emergence.dispatch(Map.put(args, "operation", "list"))

      "emergence_search" ->
        Mimo.Tools.Dispatchers.Emergence.dispatch(Map.put(args, "operation", "search"))

      "emergence_suggest" ->
        Mimo.Tools.Dispatchers.Emergence.dispatch(Map.put(args, "operation", "suggest"))

      "emergence_status" ->
        Mimo.Tools.Dispatchers.Emergence.dispatch(Map.put(args, "operation", "status"))

      # === REFLECTOR TOOL OPERATIONS (SPEC-043) ===
      # Direct access to reflector operations for MCP cache workaround
      "reflector_reflect" ->
        Mimo.Tools.Dispatchers.Reflector.dispatch(Map.put(args, "operation", "reflect"))

      "reflector_evaluate" ->
        Mimo.Tools.Dispatchers.Reflector.dispatch(Map.put(args, "operation", "evaluate"))

      "reflector_confidence" ->
        Mimo.Tools.Dispatchers.Reflector.dispatch(Map.put(args, "operation", "confidence"))

      "reflector_errors" ->
        Mimo.Tools.Dispatchers.Reflector.dispatch(Map.put(args, "operation", "errors"))

      "reflector_format" ->
        Mimo.Tools.Dispatchers.Reflector.dispatch(Map.put(args, "operation", "format"))

      "reflector_config" ->
        Mimo.Tools.Dispatchers.Reflector.dispatch(Map.put(args, "operation", "config"))

      # === LIFECYCLE TOOL OPERATIONS (SPEC-042) ===
      # Cognitive lifecycle tracking operations
      "lifecycle_stats" ->
        dispatch_lifecycle_stats()

      "lifecycle_distribution" ->
        dispatch_lifecycle_distribution(args)

      "lifecycle_warnings" ->
        dispatch_lifecycle_warnings(args)

      # === OPTIMIZER TOOL OPERATIONS (Evaluator-Optimizer Pattern) ===
      # Self-improving evaluation feedback loop
      "optimizer_stats" ->
        dispatch_optimizer_stats()

      "optimizer_metrics" ->
        dispatch_optimizer_metrics()

      "optimizer_recommendations" ->
        dispatch_optimizer_recommendations()

      "optimizer_record_outcome" ->
        dispatch_optimizer_record_outcome(args)

      "optimizer_optimize" ->
        dispatch_optimizer_optimize(args)

      # === SPEC-062: CALIBRATION OPERATIONS ===
      # Confidence calibration and tracking
      "calibration_log_claim" ->
        dispatch_calibration_log_claim(args)

      "calibration_log_outcome" ->
        dispatch_calibration_log_outcome(args)

      "calibration_brier_score" ->
        dispatch_calibration_brier_score()

      "calibration_stats" ->
        dispatch_calibration_stats()

      "calibration_overconfidence" ->
        dispatch_calibration_overconfidence()

      "calibration_curve" ->
        dispatch_calibration_curve()

      # === SPEC-064: FILE INTERCEPTION STATS ===
      "file_interception_stats" ->
        dispatch_file_interception_stats()

      # === SPEC-062: META-TASK DETECTION OPERATIONS ===
      "meta_task_detect" ->
        dispatch_meta_task_detect(args)

      "meta_task_enhance" ->
        dispatch_meta_task_enhance(args)

      # === SPEC-065: INJECTION FEEDBACK OPERATIONS ===
      # Track when injected memories are helpful vs ignored
      "injection_feedback" ->
        dispatch_injection_feedback(args)

      "injection_feedback_stats" ->
        dispatch_injection_feedback_stats()

      # === AUTO-REASONING ADOPTION METRICS ===
      # Track when cognitive assess is used as first tool (measures AUTO-REASONING adoption)
      "adoption_metrics" ->
        dispatch_adoption_metrics()

      # === SYSTEM HEALTH MONITORING (Q1 2026 Phase 1) ===
      # Track memory corpus size, query latency, ETS usage
      "system_health" ->
        dispatch_system_health()

      # === MEMORY QUALITY AUDIT (Q1 2026 Phase 1) ===
      # Detect contradictions, duplicates, obsolete facts
      "memory_audit" ->
        dispatch_memory_audit(args)

      # === AUTO PROCEDURE GENERATION (Q1 2026 Phase 2) ===
      # Convert successful reasoning sessions to procedures
      "auto_generate_procedure" ->
        dispatch_auto_generate_procedure(args)

      "procedure_candidates" ->
        dispatch_procedure_candidates(args)

      "procedure_suitability" ->
        dispatch_procedure_suitability(args)

      # === DOCUMENTATION VALIDATION (Q1 2026 Phase 4) ===
      "docs_validate" ->
        dispatch_docs_validate(args)

      "docs_validate_file" ->
        dispatch_docs_validate_file(args)

      # === WORKFLOW HEALTH (Q1 2026 Phase 4) ===
      "workflow_health" ->
        dispatch_workflow_health(args)

      _ ->
        {:error,
         "Unknown cognitive operation: #{op}. Available: assess, gaps, query, can_answer, suggest, stats, verification_*, verify_*, emergence_*, reflector_*, lifecycle_*, optimizer_*, calibration_*, meta_task_*, injection_feedback*, adoption_metrics, file_interception_stats, system_health, memory_audit, auto_generate_procedure, procedure_candidates, procedure_suitability, docs_validate, docs_validate_file, workflow_health"}
    end
  end

  @doc """
  Dispatch think tool operations.
  """
  def dispatch_think(args) do
    op = args["operation"] || "thought"

    case op do
      "thought" ->
        Mimo.Skills.Cognition.think(args["thought"] || "")

      "plan" ->
        Mimo.Skills.Cognition.plan(args["steps"] || [])

      "sequential" ->
        Mimo.Skills.Cognition.sequential_thinking(%{
          "thought" => args["thought"] || "",
          "thoughtNumber" => args["thoughtNumber"] || 1,
          "totalThoughts" => args["totalThoughts"] || 1,
          "nextThoughtNeeded" => args["nextThoughtNeeded"] || false
        })

      "template" ->
        # Think with template guidance (Anthropic Think Tool pattern)
        scenario = String.to_atom(args["scenario"] || "debug")
        Mimo.Skills.Cognition.think_with_template(args["thought"] || "", scenario)

      "templates" ->
        # List available thinking templates
        Mimo.Skills.Cognition.list_templates()

      _ ->
        {:error,
         "Unknown think operation: #{op}. Available: thought, plan, sequential, template, templates"}
    end
  end

  # ==========================================================================
  # PRIVATE HELPERS
  # ==========================================================================

  defp dispatch_assess(args) do
    topic = args["topic"] || ""

    if topic == "" do
      {:error, "Topic is required for assess operation"}
    else
      uncertainty = Mimo.Cognitive.ConfidenceAssessor.assess(topic)

      # Track the assessment for stats (fixes missing instrumentation)
      Mimo.Cognitive.UncertaintyTracker.record(topic, uncertainty)

      {:ok, Helpers.format_uncertainty(uncertainty)}
    end
  end

  defp dispatch_gaps(args) do
    topic = args["topic"] || ""

    if topic == "" do
      {:error, "Topic is required for gaps operation"}
    else
      gap = Mimo.Cognitive.GapDetector.analyze(topic)

      {:ok,
       %{
         topic: topic,
         gap_type: gap.gap_type,
         severity: gap.severity,
         suggestion: gap.suggestion,
         actions: gap.actions,
         details: gap.details
       }}
    end
  end

  defp dispatch_query(args) do
    topic = args["topic"] || ""

    if topic == "" do
      {:error, "Topic is required for query operation"}
    else
      {:ok, result} = Mimo.Cognitive.EpistemicBrain.query(topic)

      {:ok,
       %{
         response: result.response,
         confidence: result.uncertainty.confidence,
         score: Float.round(result.uncertainty.score, 3),
         gap_type: result.gap_analysis.gap_type,
         actions_taken: result.actions_taken,
         can_answer: result.uncertainty.confidence in [:high, :medium]
       }}
    end
  end

  defp dispatch_can_answer(args) do
    topic = args["topic"] || ""
    min_confidence_val = args["min_confidence"] || 0.4

    if topic == "" do
      {:error, "Topic is required for can_answer operation"}
    else
      # Convert numeric confidence to confidence level
      min_level =
        cond do
          min_confidence_val >= 0.7 -> :high
          min_confidence_val >= 0.4 -> :medium
          min_confidence_val >= 0.2 -> :low
          true -> :unknown
        end

      can_answer = Mimo.Cognitive.EpistemicBrain.can_answer?(topic, min_level)
      uncertainty = Mimo.Cognitive.ConfidenceAssessor.assess(topic)

      {:ok,
       %{
         topic: topic,
         can_answer: can_answer,
         confidence: uncertainty.confidence,
         score: Float.round(uncertainty.score, 3),
         recommendation: if(can_answer, do: "proceed", else: "research_needed")
       }}
    end
  end

  defp dispatch_suggest(args) do
    limit = args["limit"] || 5
    targets = Mimo.Cognitive.UncertaintyTracker.suggest_learning_targets(limit: limit)

    {:ok,
     %{
       learning_targets:
         Enum.map(targets, fn t ->
           %{
             topic: t.topic,
             priority: Float.round(t.priority, 3),
             reason: t.reason,
             suggested_action: t.suggested_action
           }
         end),
       count: length(targets)
     }}
  end

  defp dispatch_stats do
    stats = Mimo.Cognitive.UncertaintyTracker.stats()
    avg_conf = Map.get(stats, :avg_confidence) || Map.get(stats, :average_confidence) || 0.0

    {:ok,
     %{
       total_queries: stats.total_queries,
       unique_topics: stats.unique_topics,
       gaps_detected: stats.gaps_detected,
       confidence_distribution: Map.get(stats, :confidence_distribution, %{}),
       average_confidence: Float.round(avg_conf * 1.0, 3)
     }}
  end

  # ==========================================================================
  # REASON TOOL DISPATCHER (SPEC-035)
  # ==========================================================================

  @doc """
  Dispatch reason tool operations for unified reasoning engine.
  """
  def dispatch_reason(args) do
    op = args["operation"] || "guided"

    case op do
      "guided" ->
        dispatch_reason_guided(args)

      "decompose" ->
        dispatch_reason_decompose(args)

      "step" ->
        dispatch_reason_step(args)

      "verify" ->
        dispatch_reason_verify(args)

      "reflect" ->
        dispatch_reason_reflect(args)

      "branch" ->
        dispatch_reason_branch(args)

      "backtrack" ->
        dispatch_reason_backtrack(args)

      "conclude" ->
        dispatch_reason_conclude(args)

      "enrich" ->
        dispatch_reason_enrich(args)

      "steps" ->
        dispatch_reason_steps(args)

      _ ->
        {:error,
         "Unknown reason operation: #{op}. Available: guided, decompose, step, enrich, steps, verify, reflect, branch, backtrack, conclude"}
    end
  end

  defp dispatch_reason_guided(args) do
    problem = args["problem"] || ""

    if problem == "" do
      {:error, "Problem is required for guided reasoning"}
    else
      strategy = parse_strategy(args["strategy"])
      opts = if strategy, do: [strategy: strategy], else: []

      Reasoner.guided(problem, opts)
    end
  end

  defp dispatch_reason_decompose(args) do
    problem = args["problem"] || ""

    if problem == "" do
      {:error, "Problem is required for decompose operation"}
    else
      strategy = parse_strategy(args["strategy"])
      opts = if strategy, do: [strategy: strategy], else: []

      Reasoner.decompose(problem, opts)
    end
  end

  defp dispatch_reason_step(args) do
    session_id = args["session_id"] || ""
    thought = args["thought"] || ""

    cond do
      session_id == "" ->
        {:error, "session_id is required for step operation"}

      thought == "" ->
        {:error, "thought is required for step operation"}

      true ->
        Reasoner.step(session_id, thought)
    end
  end

  defp dispatch_reason_verify(args) do
    session_id = args["session_id"]
    thoughts = args["thoughts"]

    cond do
      session_id != nil and session_id != "" ->
        Reasoner.verify(session_id)

      thoughts != nil and is_list(thoughts) ->
        Reasoner.verify(thoughts)

      true ->
        {:error, "Either session_id or thoughts list is required for verify operation"}
    end
  end

  defp dispatch_reason_reflect(args) do
    session_id = args["session_id"] || ""
    success = args["success"] || false
    error = args["error"]
    result = args["result"]

    if session_id == "" do
      {:error, "session_id is required for reflect operation"}
    else
      outcome = %{
        success: success,
        error: error,
        result: result
      }

      Reasoner.reflect(session_id, outcome)
    end
  end

  defp dispatch_reason_branch(args) do
    session_id = args["session_id"] || ""
    thought = args["thought"] || ""

    cond do
      session_id == "" ->
        {:error, "session_id is required for branch operation"}

      thought == "" ->
        {:error, "thought is required for branch operation"}

      true ->
        Reasoner.branch(session_id, thought)
    end
  end

  defp dispatch_reason_backtrack(args) do
    session_id = args["session_id"] || ""
    to_branch = args["to_branch"]

    if session_id == "" do
      {:error, "session_id is required for backtrack operation"}
    else
      opts = if to_branch, do: [to_branch: to_branch], else: []
      Reasoner.backtrack(session_id, opts)
    end
  end

  defp dispatch_reason_conclude(args) do
    session_id = args["session_id"] || ""

    if session_id == "" do
      {:error, "session_id is required for conclude operation"}
    else
      Reasoner.conclude(session_id)
    end
  end

  defp dispatch_reason_enrich(args) do
    session_id = args["session_id"] || ""
    step_number = args["step_number"] || 1

    if session_id == "" do
      {:error, "session_id is required for enrich operation"}
    else
      Reasoner.enrich(session_id, step_number)
    end
  end

  defp dispatch_reason_steps(args) do
    session_id = args["session_id"] || ""
    thoughts = args["thoughts"] || []

    if session_id == "" do
      {:error, "session_id is required for steps operation"}
    else
      Reasoner.steps(session_id, thoughts)
    end
  end

  defp parse_strategy(strategy) do
    case strategy do
      "auto" -> :auto
      "cot" -> :cot
      "tot" -> :tot
      "react" -> :react
      "reflexion" -> :reflexion
      nil -> nil
      _ -> nil
    end
  end

  # ==========================================================================
  # SPEC-AI-TEST: Verification Tracker Operations
  # ==========================================================================

  defp dispatch_verification_stats do
    case Mimo.Brain.VerificationTracker.stats() do
      stats when is_map(stats) ->
        {:ok, stats}

      error ->
        {:error, "Failed to retrieve verification stats: #{inspect(error)}"}
    end
  end

  defp dispatch_verification_overconfidence(args) do
    threshold = args["brier_threshold"] || 0.3

    case Mimo.Brain.VerificationTracker.detect_overconfidence(brier_threshold: threshold) do
      patterns when is_list(patterns) ->
        {:ok,
         %{
           threshold: threshold,
           patterns_detected: length(patterns),
           patterns: patterns
         }}

      error ->
        {:error, "Failed to detect overconfidence: #{inspect(error)}"}
    end
  end

  defp dispatch_verification_success_by_type do
    case Mimo.Brain.VerificationTracker.success_by_type() do
      success_map when is_map(success_map) ->
        {:ok, success_map}

      error ->
        {:error, "Failed to retrieve success by type: #{inspect(error)}"}
    end
  end

  defp dispatch_verification_brier_score do
    case Mimo.Brain.VerificationTracker.brier_score() do
      result when is_map(result) ->
        {:ok, result}

      error ->
        {:error, "Failed to calculate Brier score: #{inspect(error)}"}
    end
  end

  # ==========================================================================
  # SPEC-042: Cognitive Lifecycle Operations
  # ==========================================================================

  defp dispatch_lifecycle_stats do
    alias Mimo.Brain.CognitiveLifecycle

    try do
      stats = CognitiveLifecycle.stats()

      {:ok,
       %{
         type: "lifecycle_stats",
         description: "Cognitive lifecycle tracking statistics (SPEC-042)",
         data: stats,
         target_distribution: %{
           context: "15-20% - Gathering memories, knowledge, context",
           deliberate: "15-20% - Reasoning, planning, assessing options",
           action: "45-55% - Executing tools, making changes",
           learn: "10-15% - Storing insights, updating knowledge"
         }
       }}
    rescue
      e ->
        {:error, "Failed to retrieve lifecycle stats: #{inspect(e)}"}
    end
  end

  defp dispatch_lifecycle_distribution(args) do
    alias Mimo.Brain.CognitiveLifecycle
    alias Mimo.Brain.ThreadManager

    try do
      thread_id = args["thread_id"] || ThreadManager.get_current_thread_id()

      if thread_id do
        distribution = CognitiveLifecycle.get_phase_distribution(thread_id)

        {:ok,
         %{
           type: "lifecycle_distribution",
           thread_id: thread_id,
           distribution: distribution,
           recommendations: generate_recommendations(distribution)
         }}
      else
        {:error, "No active thread. Use thread_id parameter or start a session first."}
      end
    rescue
      e ->
        {:error, "Failed to retrieve lifecycle distribution: #{inspect(e)}"}
    end
  end

  defp dispatch_lifecycle_warnings(args) do
    alias Mimo.Brain.CognitiveLifecycle
    alias Mimo.Brain.ThreadManager

    try do
      thread_id = args["thread_id"] || ThreadManager.get_current_thread_id()

      if thread_id do
        warnings = CognitiveLifecycle.check_anti_patterns(thread_id)

        {:ok,
         %{
           type: "lifecycle_warnings",
           thread_id: thread_id,
           warning_count: length(warnings),
           warnings:
             Enum.map(warnings, fn w ->
               %{
                 type: w.type,
                 message: w.message,
                 severity: w.severity,
                 timestamp: DateTime.to_iso8601(w.timestamp)
               }
             end),
           guidance:
             if(warnings == [],
               do: "No anti-patterns detected. Great workflow!",
               else: "Consider addressing the detected anti-patterns."
             )
         }}
      else
        {:error, "No active thread. Use thread_id parameter or start a session first."}
      end
    rescue
      e ->
        {:error, "Failed to retrieve lifecycle warnings: #{inspect(e)}"}
    end
  end

  defp generate_recommendations(distribution) do
    case distribution.health do
      :healthy ->
        ["Excellent workflow balance! Continue with this pattern."]

      :insufficient_data ->
        ["Need more interactions to assess workflow health. Keep using tools."]

      :minor_imbalance ->
        check_phase_balance(distribution.percentages, distribution.target_ranges)

      :moderate_imbalance ->
        ["Workflow imbalance detected. Review the phase distribution."] ++
          check_phase_balance(distribution.percentages, distribution.target_ranges)

      :significant_imbalance ->
        ["⚠️ Significant workflow imbalance detected!"] ++
          check_phase_balance(distribution.percentages, distribution.target_ranges)
    end
  end

  defp check_phase_balance(percentages, target_ranges) do
    Enum.flat_map(percentages, fn {phase, pct} ->
      {min, max} = Map.get(target_ranges, phase, {0, 100})
      min_pct = min * 100
      max_pct = max * 100

      cond do
        pct < min_pct * 0.5 ->
          ["⚠️ #{phase} phase severely underused (#{pct}%). Target: #{min_pct}-#{max_pct}%"]

        pct < min_pct ->
          ["#{phase} phase slightly low (#{pct}%). Target: #{min_pct}-#{max_pct}%"]

        pct > max_pct * 1.5 ->
          ["⚠️ #{phase} phase overused (#{pct}%). Target: #{min_pct}-#{max_pct}%"]

        pct > max_pct ->
          ["#{phase} phase slightly high (#{pct}%). Target: #{min_pct}-#{max_pct}%"]

        true ->
          []
      end
    end)
  end

  # ==========================================================================
  # Evaluator-Optimizer Pattern: Self-improving evaluation feedback loop
  # ==========================================================================

  defp dispatch_optimizer_stats do
    alias Mimo.Brain.Reflector.Optimizer

    try do
      stats = Optimizer.stats()

      {:ok,
       %{
         type: "optimizer_stats",
         description: "Evaluator-Optimizer pattern statistics (Phase 2 Cognitive Enhancement)",
         data: stats,
         status: "operational"
       }}
    rescue
      e ->
        {:error, "Failed to retrieve optimizer stats: #{inspect(e)}"}
    catch
      :exit, {:noproc, _} ->
        {:ok,
         %{
           type: "optimizer_stats",
           status: "not_running",
           message: "Optimizer GenServer not started"
         }}
    end
  end

  defp dispatch_optimizer_metrics do
    alias Mimo.Brain.Reflector.Optimizer

    try do
      case Optimizer.get_metrics() do
        {:ok, metrics} ->
          {:ok,
           %{
             type: "optimizer_metrics",
             description: "Optimization metrics for self-improvement feedback loop",
             metrics: metrics,
             dimensions: Map.keys(metrics.dimension_accuracy),
             summary: %{
               avg_dimension_accuracy: average(Map.values(metrics.dimension_accuracy)),
               total_predictions: metrics.total_predictions,
               total_outcomes: metrics.total_outcomes,
               threshold_current: metrics.threshold_performance.current,
               last_optimization: metrics.last_optimization
             }
           }}

        {:error, reason} ->
          {:error, "Failed to get metrics: #{inspect(reason)}"}
      end
    rescue
      e ->
        {:error, "Failed to retrieve optimizer metrics: #{inspect(e)}"}
    catch
      :exit, {:noproc, _} ->
        {:ok,
         %{
           type: "optimizer_metrics",
           status: "not_running",
           message: "Optimizer GenServer not started"
         }}
    end
  end

  defp dispatch_optimizer_recommendations do
    alias Mimo.Brain.Reflector.Optimizer

    try do
      case Optimizer.get_recommendations() do
        {:ok, recommendations} ->
          {:ok,
           %{
             type: "optimizer_recommendations",
             description: "Self-improvement recommendations based on prediction accuracy",
             recommendation_count: length(recommendations),
             recommendations: recommendations,
             action_needed: Enum.any?(recommendations, &(&1.priority == :high))
           }}

        {:error, reason} ->
          {:error, "Failed to get recommendations: #{inspect(reason)}"}
      end
    rescue
      e ->
        {:error, "Failed to retrieve optimizer recommendations: #{inspect(e)}"}
    catch
      :exit, {:noproc, _} ->
        {:ok,
         %{
           type: "optimizer_recommendations",
           status: "not_running",
           message: "Optimizer GenServer not started"
         }}
    end
  end

  defp dispatch_optimizer_record_outcome(args) do
    alias Mimo.Brain.Reflector.Optimizer

    context_hash = args["context_hash"]
    outcome = args["outcome"]

    if is_nil(context_hash) or is_nil(outcome) do
      {:error,
       "Both context_hash and outcome are required. outcome should be 'success', 'partial', or 'failure'."}
    else
      outcome_atom =
        case outcome do
          "success" -> :success
          "partial" -> :partial
          "failure" -> :failure
          _ -> :partial
        end

      try do
        case Optimizer.record_outcome(context_hash, outcome_atom) do
          {:ok, count} ->
            {:ok,
             %{
               type: "optimizer_record_outcome",
               context_hash: context_hash,
               outcome: outcome,
               predictions_updated: count,
               message: "Recorded outcome for #{count} prediction(s)"
             }}

          {:error, reason} ->
            {:error, "Failed to record outcome: #{inspect(reason)}"}
        end
      rescue
        e ->
          {:error, "Failed to record outcome: #{inspect(e)}"}
      catch
        :exit, {:noproc, _} ->
          {:error, "Optimizer GenServer not running"}
      end
    end
  end

  defp dispatch_optimizer_optimize(args) do
    alias Mimo.Brain.Reflector.Optimizer

    force = args["force"] == true || args["force"] == "true"
    apply_changes = args["apply"] == true || args["apply"] == "true"

    try do
      case Optimizer.optimize(force: force, apply: apply_changes) do
        {:ok, result} ->
          {:ok,
           %{
             type: "optimizer_optimize",
             description: "Optimization cycle result",
             optimized: result[:optimized] || false,
             samples_analyzed: result[:samples_analyzed] || 0,
             threshold_analysis: result[:threshold_analysis],
             recommended_threshold: result[:recommended_threshold],
             dimension_accuracy: result[:dimension_accuracy],
             refinement_success_rate: result[:refinement_success_rate],
             changes_applied: apply_changes,
             summary: result[:summary] || result[:reason]
           }}

        {:error, reason} ->
          {:error, "Optimization failed: #{inspect(reason)}"}
      end
    rescue
      e ->
        {:error, "Failed to run optimization: #{inspect(e)}"}
    catch
      :exit, {:noproc, _} ->
        {:error, "Optimizer GenServer not running"}
    end
  end

  # ==========================================================================
  # SPEC-062: CALIBRATION OPERATIONS
  # ==========================================================================

  defp dispatch_calibration_log_claim(args) do
    alias Mimo.Cognitive.Calibration

    claim = args["claim"] || ""
    confidence = args["confidence"]
    answer = args["answer"] || ""

    cond do
      claim == "" ->
        {:error, "claim is required for calibration_log_claim"}

      confidence == nil ->
        {:error, "confidence (0.0-1.0) is required for calibration_log_claim"}

      not is_number(confidence) or confidence < 0.0 or confidence > 1.0 ->
        {:error, "confidence must be a number between 0.0 and 1.0"}

      answer == "" ->
        {:error, "answer is required for calibration_log_claim"}

      true ->
        # Convert confidence from 0.0-1.0 to percentage for log_claim
        confidence_pct = confidence * 100

        case Calibration.log_claim(claim, confidence_pct, answer) do
          {:ok, result} ->
            {:ok,
             %{
               type: "calibration_claim_logged",
               claim_id: result[:memory_id] || result["memory_id"],
               claim: claim,
               confidence: confidence,
               answer: answer,
               message: "Claim logged. Use calibration_log_outcome to record result."
             }}

          {:error, reason} ->
            {:error, "Failed to log claim: #{inspect(reason)}"}
        end
    end
  end

  defp dispatch_calibration_log_outcome(args) do
    alias Mimo.Cognitive.Calibration

    claim_id = args["claim_id"]
    outcome = args["outcome"]

    cond do
      claim_id == nil ->
        {:error, "claim_id is required for calibration_log_outcome"}

      outcome == nil ->
        {:error, "outcome (true/false) is required for calibration_log_outcome"}

      true ->
        outcome_bool = outcome == true or outcome == "true"

        case Calibration.log_outcome(claim_id, outcome_bool) do
          :ok ->
            {:ok,
             %{
               type: "calibration_outcome_logged",
               claim_id: claim_id,
               outcome: outcome_bool,
               message: "Outcome recorded. Brier score updated."
             }}

          {:error, reason} ->
            {:error, "Failed to log outcome: #{inspect(reason)}"}
        end
    end
  end

  defp dispatch_calibration_brier_score do
    alias Mimo.Cognitive.Calibration

    case Calibration.brier_score() do
      {:ok, score} ->
        interpretation =
          cond do
            score < 0.1 -> "Excellent calibration"
            score < 0.2 -> "Good calibration"
            score < 0.3 -> "Moderate calibration"
            true -> "Poor calibration - consider adjusting confidence levels"
          end

        {:ok,
         %{
           type: "calibration_brier_score",
           brier_score: Float.round(score, 4),
           interpretation: interpretation,
           note: "Lower is better. Perfect calibration = 0.0"
         }}

      {:error, reason} ->
        {:error, "Failed to get Brier score: #{inspect(reason)}"}
    end
  end

  defp dispatch_calibration_stats do
    alias Mimo.Cognitive.Calibration

    case Calibration.stats() do
      {:ok, stats} ->
        {:ok,
         %{
           type: "calibration_stats",
           total_claims: stats[:total_claims] || 0,
           resolved_claims: stats[:resolved_claims] || 0,
           pending_claims: stats[:pending_claims] || 0,
           brier_score: stats[:brier_score],
           average_confidence: stats[:average_confidence],
           accuracy_rate: stats[:accuracy_rate]
         }}

      {:error, reason} ->
        {:error, "Failed to get calibration stats: #{inspect(reason)}"}
    end
  end

  defp dispatch_calibration_overconfidence do
    alias Mimo.Cognitive.Calibration

    case Calibration.overconfidence_analysis() do
      {:ok, analysis} ->
        {:ok,
         %{
           type: "calibration_overconfidence",
           is_overconfident: analysis[:is_overconfident] || false,
           overconfidence_ratio: analysis[:overconfidence_ratio],
           high_confidence_accuracy: analysis[:high_confidence_accuracy],
           recommendations: analysis[:recommendations] || [],
           sample_size: analysis[:sample_size] || 0
         }}

      {:error, reason} ->
        {:error, "Failed to analyze overconfidence: #{inspect(reason)}"}
    end
  end

  defp dispatch_calibration_curve do
    alias Mimo.Cognitive.Calibration

    case Calibration.calibration_curve() do
      {:ok, curve} ->
        {:ok,
         %{
           type: "calibration_curve",
           buckets: curve[:buckets] || [],
           perfect_calibration_note: "When predicted confidence matches actual accuracy",
           usage: "Compare predicted vs actual in each bucket to assess calibration"
         }}

      {:error, reason} ->
        {:error, "Failed to generate calibration curve: #{inspect(reason)}"}
    end
  end

  # ==========================================================================
  # SPEC-062: META-TASK DETECTION OPERATIONS
  # ==========================================================================

  defp dispatch_meta_task_detect(args) do
    alias Mimo.Cognitive.MetaTaskDetector

    task = args["task"] || args["problem"] || ""

    if task == "" do
      {:error, "task or problem is required for meta_task_detect"}
    else
      case MetaTaskDetector.detect(task) do
        {:ok, result} ->
          {:ok,
           %{
             type: "meta_task_detection",
             is_meta_task: result.is_meta_task,
             meta_task_type: result.type,
             confidence: result.confidence,
             task: task,
             warning:
               if(result.is_meta_task,
                 do: "Meta-task detected. Self-generated content requires verification.",
                 else: nil
               )
           }}

        {:error, reason} ->
          {:error, "Failed to detect meta-task: #{inspect(reason)}"}
      end
    end
  end

  defp dispatch_meta_task_enhance(args) do
    alias Mimo.Cognitive.MetaTaskDetector

    task = args["task"] || args["problem"] || ""

    if task == "" do
      {:error, "task or problem is required for meta_task_enhance"}
    else
      case MetaTaskDetector.enhance_if_meta_task(task) do
        {:ok, enhanced} ->
          {:ok,
           %{
             type: "meta_task_enhanced",
             original_task: task,
             enhanced_task: enhanced.enhanced_task,
             is_meta_task: enhanced.is_meta_task,
             meta_task_type: enhanced.type,
             enhancements_applied: enhanced.enhancements || [],
             verification_guidance: enhanced.verification_guidance
           }}

        {:error, reason} ->
          {:error, "Failed to enhance meta-task: #{inspect(reason)}"}
      end
    end
  end

  # ==========================================================================
  # SPEC-064: FILE INTERCEPTION STATS
  # ==========================================================================

  defp dispatch_file_interception_stats do
    alias Mimo.Skills.FileReadInterceptor
    alias Mimo.Skills.FileReadCache

    interceptor_stats = FileReadInterceptor.stats()
    cache_stats = FileReadCache.stats()

    {:ok,
     %{
       type: "file_interception_stats",
       interceptor: %{
         total_intercepts: interceptor_stats.total_intercepts,
         memory_hits: interceptor_stats.memory_hits,
         cache_hits: interceptor_stats.cache_hits,
         symbol_suggestions: interceptor_stats.symbol_suggestions,
         partial_hits: interceptor_stats.partial_hits,
         misses: interceptor_stats.misses,
         bypasses: interceptor_stats.bypasses,
         hit_rate: interceptor_stats.hit_rate,
         savings_estimate: interceptor_stats.savings_estimate
       },
       cache: %{
         entries: cache_stats.entries,
         memory_kb: cache_stats.memory_kb,
         max_entries: cache_stats.max_entries,
         utilization: cache_stats.utilization
       },
       spec: "SPEC-064",
       description: "Memory-first file read interception for token optimization"
     }}
  rescue
    e ->
      {:error, "Failed to get file interception stats: #{inspect(e)}"}
  end

  # ==========================================================================
  # SPEC-065: INJECTION FEEDBACK OPERATIONS
  # ==========================================================================

  # Record feedback on injected memories - tracks when injections are helpful.
  #
  # Feedback types:
  # - :used - Memory was actively used in reasoning/response
  # - :referenced - Memory was mentioned/acknowledged
  # - :helpful - Memory contributed to better outcome
  # - :ignored - Memory was not relevant (negative signal)
  defp dispatch_injection_feedback(args) do
    alias Mimo.Knowledge.PreToolInjector

    injection_id = args["injection_id"]
    feedback_type = args["feedback_type"] || args["type"] || "used"

    if injection_id == nil or injection_id == "" do
      {:error, "injection_id is required for injection_feedback"}
    else
      feedback_atom =
        case feedback_type do
          type when is_atom(type) -> type
          "used" -> :used
          "referenced" -> :referenced
          "helpful" -> :helpful
          "ignored" -> :ignored
          other -> String.to_atom(other)
        end

      case PreToolInjector.record_feedback(injection_id, feedback_atom) do
        :ok ->
          {:ok,
           %{
             type: "injection_feedback_recorded",
             injection_id: injection_id,
             feedback_type: feedback_atom,
             spec: "SPEC-065",
             description: "Feedback recorded. Positive feedback reinforces memory access patterns."
           }}

        {:error, :injection_not_found} ->
          {:error, "Injection not found: #{injection_id}. May have expired from tracking."}

        {:error, reason} ->
          {:error, "Failed to record feedback: #{inspect(reason)}"}
      end
    end
  end

  # Get statistics on injection feedback to see what's working.
  defp dispatch_injection_feedback_stats do
    alias Mimo.Knowledge.PreToolInjector

    stats = PreToolInjector.feedback_stats()

    # Handle :no_data status when ETS table is fresh
    case Map.get(stats, :status) do
      :no_data ->
        {:ok,
         %{
           type: "injection_feedback_stats",
           status: "no_data",
           total_injections: 0,
           with_feedback: 0,
           feedback_rate: 0.0,
           positive_rate: 0.0,
           by_type: %{},
           spec: "SPEC-065",
           description:
             "No injection events tracked yet. Stats will populate after tool calls with memory injection.",
           hint: "Run any file/terminal/web tool to trigger injection tracking"
         }}

      _ ->
        {:ok,
         %{
           type: "injection_feedback_stats",
           total_injections: stats.total_injections,
           with_feedback: stats.with_feedback,
           feedback_rate: stats.feedback_rate,
           positive_rate: stats.positive_rate,
           by_type: stats.by_type,
           spec: "SPEC-065",
           description: "Statistics on proactive memory injection effectiveness",
           interpretation: %{
             feedback_rate: "% of injections that received feedback",
             positive_rate: "% of feedback that was positive (used/referenced/helpful vs ignored)",
             by_type: "Breakdown of feedback by type"
           }
         }}
    end
  end

  # Get AUTO-REASONING adoption metrics.
  #
  # Returns statistics on when cognitive assess is used as the first tool in a session,
  # which measures adoption of the AUTO-REASONING workflow pattern.
  defp dispatch_adoption_metrics do
    stats = Mimo.AdoptionMetrics.get_stats()

    {:ok,
     %{
       type: "adoption_metrics",
       total_sessions: stats.total_sessions,
       assess_first_count: stats.assess_first_count,
       assess_first_rate: stats.assess_first_rate,
       first_tool_breakdown: stats.first_tool_breakdown,
       description: "Tracks when cognitive assess is used as first tool (AUTO-REASONING adoption)",
       interpretation: %{
         assess_first_rate: "% of sessions that start with cognitive assess (target: >80%)",
         first_tool_breakdown: "Distribution of first tool used across all sessions"
       },
       context: "AUTO-REASONING workflow: cognitive assess → reason guided → action → reflect"
     }}
  end

  # Get system health metrics.
  #
  # Returns visibility into memory corpus size, query latency, ETS usage.
  # Provides early warning before performance degradation.
  defp dispatch_system_health do
    metrics = Mimo.SystemHealth.get_metrics()

    {:ok,
     %{
       type: "system_health",
       timestamp: metrics.timestamp,
       metrics: metrics.metrics,
       alerts:
         Enum.map(metrics.alerts || [], fn {key, value, threshold} ->
           %{metric: key, current: value, threshold: threshold}
         end),
       healthy: length(metrics.alerts || []) == 0,
       thresholds: %{
         memory_count: 50_000,
         relationship_count: 100_000,
         ets_table_mb: 500,
         query_latency_ms: 1000,
         description: "70% of estimated capacity before performance degradation"
       },
       interpretation: %{
         memory_count: "Total memories in episodic store",
         relationship_count: "Total relationships in semantic store",
         ets_total_mb: "Total ETS table memory across all Mimo tables",
         query_latency_ms: "Latency of semantic search benchmark query"
       }
     }}
  end

  # Audit memory quality.
  #
  # Returns visibility into memory health issues:
  # - Exact duplicates
  # - Potential contradictions
  # - Obsolete memory candidates
  defp dispatch_memory_audit(args) do
    limit = args["limit"] || 20
    days_old = args["days_old"] || 90

    audit_results = Mimo.Brain.MemoryAuditor.audit(limit: limit, days_old: days_old)
    recommendations = Mimo.Brain.MemoryAuditor.generate_recommendations(audit_results)

    {:ok,
     %{
       type: "memory_audit",
       summary: %{
         exact_duplicates: length(audit_results.exact_duplicates),
         potential_contradictions: length(audit_results.potential_contradictions),
         obsolete_candidates: length(audit_results.obsolete_candidates)
       },
       exact_duplicates: audit_results.exact_duplicates,
       potential_contradictions: audit_results.potential_contradictions,
       obsolete_candidates: audit_results.obsolete_candidates,
       recommendations: recommendations,
       parameters: %{
         limit: limit,
         days_old: days_old
       }
     }}
  end

  # ============================================================================
  # AUTO PROCEDURE GENERATION (Q1 2026 Phase 2)
  # ============================================================================

  # Generate a procedure from a completed reasoning session.
  #
  # Converts successful reasoning sessions into deterministic procedures
  # that can be executed without LLM involvement.
  defp dispatch_auto_generate_procedure(args) do
    alias Mimo.ProceduralStore.AutoGenerator

    session_id = args["session_id"]

    if is_nil(session_id) do
      {:error, "session_id is required"}
    else
      opts =
        [
          name: args["name"],
          version: args["version"] || "1.0",
          description: args["description"],
          auto_register: args["auto_register"] || false
        ]
        |> Enum.filter(fn {_, v} -> not is_nil(v) end)

      case AutoGenerator.generate_from_session(session_id, opts) do
        {:ok, procedure} ->
          {:ok,
           %{
             type: "auto_generate_procedure",
             session_id: session_id,
             procedure: %{
               name: procedure.name,
               version: procedure.version,
               description: procedure.description,
               states_count: map_size(procedure.definition["states"] || %{}),
               registered: Keyword.get(opts, :auto_register, false)
             },
             hint: "Use run_procedure name=\"#{procedure.name}\" to execute"
           }}

        {:error, :session_not_found} ->
          {:error, "Session not found: #{session_id}"}

        {:error, :too_few_steps} ->
          {:error, "Session has too few extractable steps for procedure generation"}

        {:error, reason} ->
          {:error, "Failed to generate procedure: #{inspect(reason)}"}
      end
    end
  end

  # List reasoning sessions that are good candidates for procedure generation.
  defp dispatch_procedure_candidates(args) do
    alias Mimo.ProceduralStore.AutoGenerator

    opts = [
      limit: args["limit"] || 10,
      min_success_rate: args["min_success_rate"] || 0.7
    ]

    candidates = AutoGenerator.list_candidates(opts)

    {:ok,
     %{
       type: "procedure_candidates",
       count: length(candidates),
       candidates:
         Enum.map(candidates, fn c ->
           %{
             session_id: c.session_id,
             suitable: c.suitable,
             steps_extractable: c.steps_extractable,
             total_thoughts: c.total_thoughts,
             extractable_ratio: c.extractable_ratio,
             strategy: c.strategy
           }
         end),
       hint: "Use auto_generate_procedure with session_id to convert a candidate"
     }}
  end

  # Analyze a specific session's suitability for procedure generation.
  defp dispatch_procedure_suitability(args) do
    alias Mimo.ProceduralStore.AutoGenerator

    session_id = args["session_id"]

    if is_nil(session_id) do
      {:error, "session_id is required"}
    else
      case AutoGenerator.analyze_suitability(session_id) do
        {:ok, analysis} ->
          {:ok,
           %{
             type: "procedure_suitability",
             session_id: session_id,
             suitable: analysis.suitable,
             reasons: analysis.reasons,
             steps_extractable: analysis.steps_extractable,
             total_thoughts: analysis.total_thoughts,
             extractable_ratio: analysis.extractable_ratio,
             strategy: analysis.strategy,
             suggested_improvements: analysis.suggested_improvements,
             next_steps:
               if(analysis.suitable,
                 do: "Use auto_generate_procedure session_id=\"#{session_id}\" to generate",
                 else: "Address suggested improvements, then re-analyze"
               )
           }}

        {:error, :session_not_found} ->
          {:error, "Session not found: #{session_id}"}

        {:error, reason} ->
          {:error, "Failed to analyze suitability: #{inspect(reason)}"}
      end
    end
  end

  # ============================================================================
  # DOCUMENTATION VALIDATION (Q1 2026 Phase 4)
  # ============================================================================

  # Validate all documentation files for accuracy.
  defp dispatch_docs_validate(_args) do
    alias Mimo.Docs.Validator

    case Validator.validate_all() do
      {:ok, result} ->
        {:ok,
         %{
           type: "docs_validation",
           files_checked: result.stats.files_checked,
           issues: format_docs_issues(result.issues),
           warnings: format_docs_issues(result.warnings),
           suggestions: format_docs_issues(result.suggestions),
           summary: %{
             total_issues: result.stats.total_issues,
             total_warnings: result.stats.total_warnings,
             total_suggestions: result.stats.total_suggestions,
             status:
               if(result.stats.total_issues == 0 and result.stats.total_warnings == 0,
                 do: :healthy,
                 else: :needs_attention
               )
           },
           hint:
             "Use 'cognitive operation=docs_validate_file' with path parameter for single file validation"
         }}

      {:error, reason} ->
        {:error, "Documentation validation failed: #{inspect(reason)}"}
    end
  end

  # Validate a specific documentation file.
  defp dispatch_docs_validate_file(args) do
    alias Mimo.Docs.Validator

    path = args["path"]

    if is_nil(path) do
      {:error, "Missing required parameter: path"}
    else
      case Validator.validate_file(path) do
        {:ok, result} ->
          {:ok,
           %{
             type: "docs_validation_file",
             file: path,
             issues: format_docs_issues(result.issues),
             warnings: format_docs_issues(result.warnings),
             suggestions: format_docs_issues(result.suggestions),
             summary: %{
               total_issues: length(result.issues),
               total_warnings: length(result.warnings),
               total_suggestions: length(result.suggestions)
             }
           }}

        {:error, reason} ->
          {:error, "File validation failed: #{inspect(reason)}"}
      end
    end
  end

  defp format_docs_issues(issues) when is_list(issues) do
    Enum.map(issues, fn issue ->
      %{
        type: issue.type,
        file: issue.file,
        line: issue.line,
        message: issue.message,
        context: issue.context
      }
    end)
  end

  defp format_docs_issues(_), do: []

  # ============================================================================
  # WORKFLOW HEALTH (Q1 2026 Phase 4)
  # ============================================================================

  # Get workflow health metrics from AdoptionMetrics.
  defp dispatch_workflow_health(_args) do
    alias Mimo.AdoptionMetrics

    try do
      health = AdoptionMetrics.get_workflow_health()
      stats = AdoptionMetrics.get_stats()

      {:ok,
       %{
         type: "workflow_health",
         workflow: %{
           phase_distribution: health.phase_distribution,
           distribution_health: health.distribution_health,
           overall_health: health.overall_health,
           context_first_rate: health.context_first_rate,
           learning_completion_rate: health.learning_completion_rate,
           status: health.status,
           recommendations: health.recommendations
         },
         adoption: %{
           total_sessions: stats.total_sessions,
           assess_first_count: stats.assess_first_count,
           assess_first_rate: stats.assess_first_rate,
           first_tool_breakdown: stats.first_tool_breakdown
         },
         summary: generate_workflow_summary(health, stats),
         hint:
           "Use workflow_health regularly to monitor agent behavior patterns and identify improvement opportunities"
       }}
    rescue
      e ->
        {:error, "Failed to get workflow health: #{inspect(e)}"}
    end
  end

  defp generate_workflow_summary(health, stats) do
    status_emoji =
      case health.status do
        :healthy -> "✅"
        :needs_improvement -> "⚠️"
        :unhealthy -> "❌"
      end

    """
    #{status_emoji} Workflow Health: #{health.overall_health * 100}%

    📊 Phase Distribution:
    • Context: #{Float.round((health.phase_distribution[:context] || 0) * 100, 1)}% (target: 15-20%)
    • Intelligence: #{Float.round((health.phase_distribution[:intelligence] || 0) * 100, 1)}% (target: 15-20%)
    • Action: #{Float.round((health.phase_distribution[:action] || 0) * 100, 1)}% (target: 45-55%)
    • Learning: #{Float.round((health.phase_distribution[:learning] || 0) * 100, 1)}% (target: 10-15%)

    🎯 AUTO-REASONING Adoption:
    • Assess First Rate: #{Float.round(stats.assess_first_rate * 100, 1)}% (target: >80%)
    • Total Sessions: #{stats.total_sessions}

    💡 Recommendations:
    #{Enum.map_join(health.recommendations, "\n", fn r -> "• #{r}" end)}
    """
  end

  defp average([]), do: 0.0

  defp average(list), do: Enum.sum(list) / length(list)
end
