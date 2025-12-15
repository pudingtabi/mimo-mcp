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

  # =============================================================================
  # Operation Group Definitions (for pattern matching guards)
  # =============================================================================

  @epistemic_ops ~w[assess gaps query can_answer suggest stats]
  @verification_ops ~w[verification_stats verification_overconfidence verification_success_by_type verification_brier_score]
  @verify_ops ~w[verify_count verify_math verify_logic verify_compare verify_self_check]
  @emergence_ops ~w[emergence_detect emergence_dashboard emergence_alerts emergence_amplify emergence_promote emergence_cycle emergence_list emergence_search emergence_suggest emergence_status]
  @reflector_ops ~w[reflector_reflect reflector_evaluate reflector_confidence reflector_errors reflector_format reflector_config]
  @lifecycle_ops ~w[lifecycle_stats lifecycle_distribution lifecycle_warnings]
  @optimizer_ops ~w[optimizer_stats optimizer_metrics optimizer_recommendations optimizer_record_outcome optimizer_optimize]
  @calibration_ops ~w[calibration_log_claim calibration_log_outcome calibration_brier_score calibration_stats calibration_overconfidence calibration_curve]
  @meta_task_ops ~w[meta_task_detect meta_task_enhance]
  @injection_ops ~w[injection_feedback injection_feedback_stats]
  @procedure_ops ~w[auto_generate_procedure procedure_candidates procedure_suitability]
  @docs_ops ~w[docs_validate docs_validate_file]
  @misc_ops ~w[adoption_metrics system_health memory_audit workflow_health file_interception_stats]

  @all_ops @epistemic_ops ++
             @verification_ops ++
             @verify_ops ++
             @emergence_ops ++
             @reflector_ops ++
             @lifecycle_ops ++
             @optimizer_ops ++
             @calibration_ops ++
             @meta_task_ops ++
             @injection_ops ++
             @procedure_ops ++
             @docs_ops ++
             @misc_ops

  # =============================================================================
  # Main Dispatch Function - Multi-head with Guards
  # =============================================================================

  @doc """
  Dispatch cognitive operation based on args.
  Uses pattern matching with guards for cleaner routing.
  """
  def dispatch(args) do
    op = args["operation"] || "assess"
    do_dispatch(op, args)
  end

  # --- Epistemic Operations (Core Cognitive) ---
  defp do_dispatch("assess", args), do: dispatch_assess(args)
  defp do_dispatch("gaps", args), do: dispatch_gaps(args)
  defp do_dispatch("query", args), do: dispatch_query(args)
  defp do_dispatch("can_answer", args), do: dispatch_can_answer(args)
  defp do_dispatch("suggest", args), do: dispatch_suggest(args)
  defp do_dispatch("stats", _args), do: dispatch_stats()

  # --- Verification Tracking Operations (SPEC-AI-TEST) ---
  defp do_dispatch("verification_stats", _args), do: dispatch_verification_stats()

  defp do_dispatch("verification_overconfidence", args),
    do: dispatch_verification_overconfidence(args)

  defp do_dispatch("verification_success_by_type", _args),
    do: dispatch_verification_success_by_type()

  defp do_dispatch("verification_brier_score", _args), do: dispatch_verification_brier_score()

  # --- Verify Tool Operations (SPEC-AI-TEST) ---
  defp do_dispatch(op, args) when op in @verify_ops do
    # Extract the actual operation (e.g., "verify_count" -> "count")
    actual_op = String.replace_prefix(op, "verify_", "")
    Mimo.Tools.Dispatchers.Verify.dispatch(Map.put(args, "operation", actual_op))
  end

  # --- Emergence Tool Operations (SPEC-044) ---
  defp do_dispatch(op, args) when op in @emergence_ops do
    actual_op = String.replace_prefix(op, "emergence_", "")
    Mimo.Tools.Dispatchers.Emergence.dispatch(Map.put(args, "operation", actual_op))
  end

  # --- Reflector Tool Operations (SPEC-043) ---
  defp do_dispatch(op, args) when op in @reflector_ops do
    actual_op = String.replace_prefix(op, "reflector_", "")
    Mimo.Tools.Dispatchers.Reflector.dispatch(Map.put(args, "operation", actual_op))
  end

  # --- Lifecycle Tool Operations (SPEC-042) ---
  defp do_dispatch("lifecycle_stats", _args), do: dispatch_lifecycle_stats()
  defp do_dispatch("lifecycle_distribution", args), do: dispatch_lifecycle_distribution(args)
  defp do_dispatch("lifecycle_warnings", args), do: dispatch_lifecycle_warnings(args)

  # --- Optimizer Tool Operations (Evaluator-Optimizer Pattern) ---
  defp do_dispatch("optimizer_stats", _args), do: dispatch_optimizer_stats()
  defp do_dispatch("optimizer_metrics", _args), do: dispatch_optimizer_metrics()
  defp do_dispatch("optimizer_recommendations", _args), do: dispatch_optimizer_recommendations()
  defp do_dispatch("optimizer_record_outcome", args), do: dispatch_optimizer_record_outcome(args)
  defp do_dispatch("optimizer_optimize", args), do: dispatch_optimizer_optimize(args)

  # --- Calibration Operations (SPEC-062) ---
  defp do_dispatch("calibration_log_claim", args), do: dispatch_calibration_log_claim(args)
  defp do_dispatch("calibration_log_outcome", args), do: dispatch_calibration_log_outcome(args)
  defp do_dispatch("calibration_brier_score", _args), do: dispatch_calibration_brier_score()
  defp do_dispatch("calibration_stats", _args), do: dispatch_calibration_stats()
  defp do_dispatch("calibration_overconfidence", _args), do: dispatch_calibration_overconfidence()
  defp do_dispatch("calibration_curve", _args), do: dispatch_calibration_curve()

  # --- Meta-Task Detection Operations (SPEC-062) ---
  defp do_dispatch("meta_task_detect", args), do: dispatch_meta_task_detect(args)
  defp do_dispatch("meta_task_enhance", args), do: dispatch_meta_task_enhance(args)

  # --- Injection Feedback Operations (SPEC-065) ---
  defp do_dispatch("injection_feedback", args), do: dispatch_injection_feedback(args)
  defp do_dispatch("injection_feedback_stats", _args), do: dispatch_injection_feedback_stats()

  # --- Misc Operations ---
  defp do_dispatch("adoption_metrics", _args), do: dispatch_adoption_metrics()
  defp do_dispatch("system_health", _args), do: dispatch_system_health()
  defp do_dispatch("memory_audit", args), do: dispatch_memory_audit(args)
  defp do_dispatch("file_interception_stats", _args), do: dispatch_file_interception_stats()

  # --- Procedure Generation Operations (Q1 2026 Phase 2) ---
  defp do_dispatch("auto_generate_procedure", args), do: dispatch_auto_generate_procedure(args)
  defp do_dispatch("procedure_candidates", args), do: dispatch_procedure_candidates(args)
  defp do_dispatch("procedure_suitability", args), do: dispatch_procedure_suitability(args)

  # --- Documentation Validation (Q1 2026 Phase 4) ---
  defp do_dispatch("docs_validate", args), do: dispatch_docs_validate(args)
  defp do_dispatch("docs_validate_file", args), do: dispatch_docs_validate_file(args)

  # --- Workflow Health (Q1 2026 Phase 4) ---
  defp do_dispatch("workflow_health", args), do: dispatch_workflow_health(args)

  # --- Fallback for Unknown Operations ---
  defp do_dispatch(op, _args) do
    {:error, "Unknown cognitive operation: #{op}. Available: #{Enum.join(@all_ops, ", ")}"}
  end

  @doc """
  Dispatch think tool operations.
  Uses multi-head function pattern matching.
  """
  def dispatch_think(args) do
    op = args["operation"] || "thought"
    do_dispatch_think(op, args)
  end

  defp do_dispatch_think("thought", args) do
    Mimo.Skills.Cognition.think(args["thought"] || "")
  end

  defp do_dispatch_think("plan", args) do
    Mimo.Skills.Cognition.plan(args["steps"] || [])
  end

  defp do_dispatch_think("sequential", args) do
    Mimo.Skills.Cognition.sequential_thinking(%{
      "thought" => args["thought"] || "",
      "thoughtNumber" => args["thoughtNumber"] || 1,
      "totalThoughts" => args["totalThoughts"] || 1,
      "nextThoughtNeeded" => args["nextThoughtNeeded"] || false
    })
  end

  defp do_dispatch_think("template", args) do
    scenario = String.to_atom(args["scenario"] || "debug")
    Mimo.Skills.Cognition.think_with_template(args["thought"] || "", scenario)
  end

  defp do_dispatch_think("templates", _args) do
    Mimo.Skills.Cognition.list_templates()
  end

  defp do_dispatch_think(op, _args) do
    {:error,
     "Unknown think operation: #{op}. Available: thought, plan, sequential, template, templates"}
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
  Uses multi-head function pattern matching.
  """
  def dispatch_reason(args) do
    op = args["operation"] || "guided"
    do_dispatch_reason(op, args)
  end

  defp do_dispatch_reason("guided", args), do: dispatch_reason_guided(args)
  defp do_dispatch_reason("decompose", args), do: dispatch_reason_decompose(args)
  defp do_dispatch_reason("step", args), do: dispatch_reason_step(args)
  defp do_dispatch_reason("verify", args), do: dispatch_reason_verify(args)
  defp do_dispatch_reason("reflect", args), do: dispatch_reason_reflect(args)
  defp do_dispatch_reason("branch", args), do: dispatch_reason_branch(args)
  defp do_dispatch_reason("backtrack", args), do: dispatch_reason_backtrack(args)
  defp do_dispatch_reason("conclude", args), do: dispatch_reason_conclude(args)
  defp do_dispatch_reason("enrich", args), do: dispatch_reason_enrich(args)
  defp do_dispatch_reason("steps", args), do: dispatch_reason_steps(args)

  defp do_dispatch_reason(op, _args) do
    {:error,
     "Unknown reason operation: #{op}. Available: guided, decompose, step, enrich, steps, verify, reflect, branch, backtrack, conclude"}
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
      # Optimizer.get_metrics() always returns {:ok, metrics}
      {:ok, metrics} = Optimizer.get_metrics()

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
      # Optimizer.get_recommendations() always returns {:ok, list}
      {:ok, recommendations} = Optimizer.get_recommendations()

      {:ok,
       %{
         type: "optimizer_recommendations",
         description: "Self-improvement recommendations based on prediction accuracy",
         recommendation_count: length(recommendations),
         recommendations: recommendations,
         action_needed: Enum.any?(recommendations, &(&1.priority == :high))
       }}
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

    with {:ok, hash, outcome_atom} <- validate_outcome_args(context_hash, outcome) do
      try do
        case Optimizer.record_outcome(hash, outcome_atom) do
          {:ok, count} ->
            {:ok,
             %{
               type: "optimizer_record_outcome",
               context_hash: hash,
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

  defp validate_outcome_args(nil, _),
    do:
      {:error,
       "Both context_hash and outcome are required. outcome should be 'success', 'partial', or 'failure'."}

  defp validate_outcome_args(_, nil),
    do:
      {:error,
       "Both context_hash and outcome are required. outcome should be 'success', 'partial', or 'failure'."}

  defp validate_outcome_args(hash, outcome), do: {:ok, hash, parse_outcome(outcome)}

  defp parse_outcome("success"), do: :success
  defp parse_outcome("partial"), do: :partial
  defp parse_outcome("failure"), do: :failure
  defp parse_outcome(_), do: :partial

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

    with {:ok, claim} <- validate_required_string(args["claim"], "claim"),
         {:ok, confidence} <- validate_confidence(args["confidence"]),
         {:ok, answer} <- validate_required_string(args["answer"], "answer") do
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

  # Validation helpers for calibration operations
  defp validate_required_string(nil, field),
    do: {:error, "#{field} is required for calibration_log_claim"}

  defp validate_required_string("", field),
    do: {:error, "#{field} is required for calibration_log_claim"}

  defp validate_required_string(value, _field) when is_binary(value), do: {:ok, value}

  defp validate_confidence(nil),
    do: {:error, "confidence (0.0-1.0) is required for calibration_log_claim"}

  defp validate_confidence(c) when is_number(c) and c >= 0.0 and c <= 1.0, do: {:ok, c}
  defp validate_confidence(_), do: {:error, "confidence must be a number between 0.0 and 1.0"}

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
          {:ok, result} ->
            {:ok,
             %{
               type: "calibration_outcome_logged",
               claim_id: result[:claim_id] || claim_id,
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
            score.brier_score < 0.1 -> "Excellent calibration"
            score.brier_score < 0.2 -> "Good calibration"
            score.brier_score < 0.3 -> "Moderate calibration"
            true -> "Poor calibration - consider adjusting confidence levels"
          end

        {:ok,
         %{
           type: "calibration_brier_score",
           brier_score: Float.round(score.brier_score, 4),
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
    end
  end

  defp dispatch_calibration_overconfidence do
    alias Mimo.Cognitive.Calibration

    {:ok, analysis} = Calibration.overconfidence_analysis()

    {:ok,
     %{
       type: "calibration_overconfidence",
       is_overconfident: analysis[:is_overconfident] || analysis[:detected] || false,
       overconfidence_ratio: analysis[:overconfidence_ratio],
       high_confidence_accuracy: analysis[:high_confidence_accuracy],
       recommendations: analysis[:recommendations] || [analysis[:recommendation]] || [],
       sample_size: analysis[:sample_size] || analysis[:pattern_count] || 0
     }}
  end

  defp dispatch_calibration_curve do
    alias Mimo.Cognitive.Calibration

    {:ok, curve} = Calibration.calibration_curve()

    {:ok,
     %{
       type: "calibration_curve",
       buckets: curve[:buckets] || curve,
       perfect_calibration_note: "When predicted confidence matches actual accuracy",
       usage: "Compare predicted vs actual in each bucket to assess calibration"
     }}
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
        {:meta_task, guidance} ->
          {:ok,
           %{
             type: "meta_task_detection",
             is_meta_task: true,
             meta_task_type: guidance.type,
             confidence: guidance.confidence,
             instruction: guidance.instruction,
             task: task,
             warning: "Meta-task detected. Self-generated content requires verification."
           }}

        {:standard, info} ->
          {:ok,
           %{
             type: "meta_task_detection",
             is_meta_task: false,
             meta_task_type: nil,
             confidence: 1.0,
             method: info[:method],
             task: task,
             warning: nil
           }}
      end
    end
  end

  defp dispatch_meta_task_enhance(args) do
    alias Mimo.Cognitive.MetaTaskDetector

    task = args["task"] || args["problem"] || ""

    if task == "" do
      {:error, "task or problem is required for meta_task_enhance"}
    else
      # enhance_if_meta_task returns a binary string (enhanced task or original)
      enhanced_task = MetaTaskDetector.enhance_if_meta_task(task)

      # Detect if it was a meta-task by checking if the result differs from original
      is_meta_task = enhanced_task != task

      {:ok,
       %{
         type: "meta_task_enhanced",
         original_task: task,
         enhanced_task: enhanced_task,
         is_meta_task: is_meta_task,
         meta_task_type: if(is_meta_task, do: :detected, else: nil),
         enhancements_applied: if(is_meta_task, do: ["meta_task_warning"], else: []),
         verification_guidance:
           if(is_meta_task, do: "Self-generated content requires verification", else: nil)
       }}
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

    with {:ok, id} <- validate_injection_id(injection_id) do
      feedback_atom = parse_feedback_type(feedback_type)

      case PreToolInjector.record_feedback(id, feedback_atom) do
        :ok ->
          {:ok,
           %{
             type: "injection_feedback_recorded",
             injection_id: id,
             feedback_type: feedback_atom,
             spec: "SPEC-065",
             description: "Feedback recorded. Positive feedback reinforces memory access patterns."
           }}

        {:error, :not_found} ->
          {:error, "Injection not found: #{id}. May have expired from tracking."}
      end
    end
  end

  defp validate_injection_id(nil), do: {:error, "injection_id is required for injection_feedback"}
  defp validate_injection_id(""), do: {:error, "injection_id is required for injection_feedback"}
  defp validate_injection_id(id) when is_binary(id), do: {:ok, id}

  defp parse_feedback_type(type) when is_atom(type), do: type
  defp parse_feedback_type("used"), do: :used
  defp parse_feedback_type("referenced"), do: :referenced
  defp parse_feedback_type("helpful"), do: :helpful
  defp parse_feedback_type("ignored"), do: :ignored
  defp parse_feedback_type(other), do: String.to_atom(other)

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
       healthy: (metrics.alerts || []) == [],
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

    {:ok, result} = Validator.validate_all()

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
