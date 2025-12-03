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

      _ ->
        {:error,
         "Unknown cognitive operation: #{op}. Available: assess, gaps, query, can_answer, suggest, stats, verification_*, verify_*, emergence_*, reflector_*"}
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
end
