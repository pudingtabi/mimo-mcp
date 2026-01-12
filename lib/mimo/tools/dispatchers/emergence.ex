defmodule Mimo.Tools.Dispatchers.Emergence do
  @moduledoc """
  SPEC-044: Emergence tool dispatcher.

  Exposes the Emergent Capabilities Framework via MCP tool interface.

  Operations:
  - detect: Run pattern detection
  - dashboard: Get emergence metrics dashboard
  - alerts: Check emergence alerts
  - amplify: Run amplification strategies
  - promote: Promote eligible patterns
  - cycle: Run full emergence cycle
  - list: List emerged patterns/capabilities
  - search: Search capabilities
  - suggest: Get capability suggestions for context
  - status: Get scheduler status
  - pattern: Get specific pattern details
  - impact: Get usage impact metrics for promoted patterns
  - track_usage: Track pattern usage in a session
  - usage_stats: Get overall usage statistics
  - ab_stats: Get A/B testing statistics (test vs control groups)
  """

  require Logger

  alias Mimo.Brain.Emergence
  alias Mimo.Brain.Emergence.Scheduler
  alias Mimo.Utils.InputValidation

  @doc """
  Dispatch emergence operation based on args.
  """
  def dispatch(args) do
    op = args["operation"] || "dashboard"
    do_dispatch(op, args)
  end

  defp do_dispatch("detect", args), do: dispatch_detect(args)
  defp do_dispatch("dashboard", _args), do: dispatch_dashboard()
  defp do_dispatch("alerts", _args), do: dispatch_alerts()
  defp do_dispatch("amplify", _args), do: dispatch_amplify()
  defp do_dispatch("promote", args), do: dispatch_promote(args)
  defp do_dispatch("cycle", args), do: dispatch_cycle(args)
  defp do_dispatch("list", args), do: dispatch_list(args)
  defp do_dispatch("search", args), do: dispatch_search(args)
  defp do_dispatch("suggest", args), do: dispatch_suggest(args)
  defp do_dispatch("status", _args), do: dispatch_status()
  defp do_dispatch("pattern", args), do: dispatch_pattern(args)
  defp do_dispatch("impact", args), do: dispatch_impact(args)
  defp do_dispatch("track_usage", args), do: dispatch_track_usage(args)
  defp do_dispatch("usage_stats", _args), do: dispatch_usage_stats()
  defp do_dispatch("ab_stats", _args), do: dispatch_ab_stats()
  # Phase 4.2: Prediction Layer (SPEC-044 v1.4)
  defp do_dispatch("predict", args), do: dispatch_predict(args)
  # Phase 4.3: Explanation Layer (SPEC-044 v1.5)
  defp do_dispatch("explain", args), do: dispatch_explain(args)
  defp do_dispatch("hypothesize", args), do: dispatch_hypothesize(args)
  # Phase 4.4: Active Probing (SPEC-044 v1.6)
  defp do_dispatch("probe", args), do: dispatch_probe(args)
  defp do_dispatch("probe_candidates", args), do: dispatch_probe_candidates(args)
  defp do_dispatch("capability_summary", _args), do: dispatch_capability_summary()

  defp do_dispatch(op, _args) do
    {:error,
     "Unknown emergence operation: #{op}. Available: detect, dashboard, alerts, amplify, promote, cycle, list, search, suggest, status, pattern, impact, track_usage, usage_stats, ab_stats, predict, explain, hypothesize, probe, probe_candidates, capability_summary"}
  end

  defp dispatch_detect(args) do
    days = args["days"] || 7
    modes = parse_modes(args["modes"])

    opts = [days: days]
    opts = if modes, do: Keyword.put(opts, :modes, modes), else: opts

    case Emergence.detect_patterns(opts) do
      {:ok, result} ->
        {:ok,
         %{
           operation: :detect,
           days_analyzed: days,
           detection_modes: map_detection_results(result)
         }}

      {:error, reason} ->
        {:error, "Pattern detection failed: #{inspect(reason)}"}
    end
  end

  defp dispatch_dashboard do
    dashboard = Emergence.dashboard()

    {:ok,
     %{
       operation: :dashboard,
       quantity: dashboard.quantity,
       quality: dashboard.quality,
       velocity: dashboard.velocity,
       coverage: dashboard.coverage,
       evolution: dashboard.evolution
     }}
  end

  defp dispatch_alerts do
    alerts = Emergence.check_alerts()
    status = Emergence.alert_status()

    {:ok,
     %{
       operation: :alerts,
       count: length(alerts),
       alerts: Enum.map(alerts, &format_alert/1),
       summary: status
     }}
  end

  defp dispatch_amplify do
    # amplify always returns {:ok, result}
    {:ok, result} = Emergence.amplify()

    {:ok,
     %{
       operation: :amplify,
       strategies_run: Map.keys(result),
       results: result
     }}
  end

  defp dispatch_promote(args) do
    opts = []

    opts =
      if args["min_occurrences"],
        do: Keyword.put(opts, :min_occurrences, args["min_occurrences"]),
        else: opts

    opts =
      if args["min_success_rate"],
        do: Keyword.put(opts, :min_success_rate, args["min_success_rate"]),
        else: opts

    opts =
      if args["min_strength"],
        do: Keyword.put(opts, :min_strength, args["min_strength"]),
        else: opts

    case Emergence.promote_eligible(opts) do
      {:ok, result} ->
        {:ok,
         %{
           operation: :promote,
           evaluated: result.evaluated,
           promoted: result.promoted,
           details: result.details
         }}
    end
  end

  defp dispatch_cycle(args) do
    days = args["days"] || 7
    opts = [days: days]

    case Emergence.run_cycle(opts) do
      {:ok, result} ->
        {:ok,
         %{
           operation: :cycle,
           detection: map_detection_results(result.detection),
           amplification: result.amplification,
           promotions: result.promotions,
           alerts_count: length(result.alerts),
           completed_at: result.completed_at
         }}
    end
  end

  defp dispatch_list(args) do
    # Validate limit
    limit = InputValidation.validate_limit(args["limit"], default: 100, max: 500)
    include_pending = args["include_pending"] || false
    type_filter = args["type"]
    status_filter = args["status"]

    opts = [limit: limit, include_pending: include_pending]

    # Get capabilities or patterns based on request
    if include_pending do
      # List patterns
      pattern_opts = [limit: limit]

      pattern_opts =
        if type_filter,
          do: Keyword.put(pattern_opts, :type, String.to_atom(type_filter)),
          else: pattern_opts

      pattern_opts =
        if status_filter,
          do: Keyword.put(pattern_opts, :status, String.to_atom(status_filter)),
          else: pattern_opts

      patterns = Emergence.list_patterns(pattern_opts)

      {:ok,
       %{
         operation: :list,
         type: :patterns,
         count: length(patterns),
         patterns: Enum.map(patterns, &format_pattern/1)
       }}
    else
      # List promoted capabilities only
      capabilities = Emergence.list_capabilities(opts)

      {:ok,
       %{
         operation: :list,
         type: :capabilities,
         count: length(capabilities),
         capabilities: capabilities
       }}
    end
  end

  defp dispatch_search(args) do
    query = args["query"] || ""

    if query == "" do
      {:error, "Query is required for search operation"}
    else
      limit = InputValidation.validate_limit(args["limit"], default: 10, max: 100)
      results = Emergence.search_capabilities(query, limit: limit)

      {:ok,
       %{
         operation: :search,
         query: query,
         count: length(results),
         results: results
       }}
    end
  end

  defp dispatch_suggest(args) do
    context = args["context"] || %{}

    suggestions = Emergence.suggest_capabilities(context)

    {:ok,
     %{
       operation: :suggest,
       count: length(suggestions),
       suggestions: suggestions
     }}
  end

  defp dispatch_status do
    status = Scheduler.status()

    {:ok,
     %{
       operation: :status,
       scheduler: status
     }}
  end

  defp dispatch_pattern(args) do
    pattern_id = args["id"]

    if pattern_id == nil do
      {:error, "Pattern ID is required"}
    else
      case Emergence.get_pattern(pattern_id) do
        nil ->
          {:error, "Pattern not found: #{pattern_id}"}

        pattern ->
          {:ok,
           %{
             operation: :pattern,
             pattern: format_pattern(pattern)
           }}
      end
    end
  end

  defp dispatch_impact(args) do
    alias Mimo.Brain.Emergence.UsageTracker

    pattern_id = args["pattern_id"]

    if pattern_id do
      # Get impact for specific pattern
      case UsageTracker.get_impact(pattern_id) do
        {:ok, impact} ->
          {:ok,
           %{
             operation: :impact,
             pattern_id: pattern_id,
             impact: format_impact(impact)
           }}

        {:error, reason} ->
          {:error, "Failed to get pattern impact: #{reason}"}
      end
    else
      # Get all pattern impacts - returns map directly, not tuple
      impacts = UsageTracker.get_all_impacts()

      {:ok,
       %{
         operation: :impact,
         all_patterns: true,
         impacts:
           Enum.map(impacts, fn {pid, impact} ->
             %{pattern_id: pid, impact: format_impact(impact)}
           end)
       }}
    end
  end

  defp dispatch_track_usage(args) do
    alias Mimo.Brain.Emergence.UsageTracker

    with {:ok, pattern_id} <- validate_required(args, "pattern_id"),
         {:ok, context} <- validate_required(args, "context") do
      session_id = args["session_id"] || generate_session_id()
      context_with_session = Map.put(context, :session_id, session_id)

      :ok = UsageTracker.track_usage(pattern_id, :unknown, context_with_session)

      {:ok,
       %{
         operation: :track_usage,
         pattern_id: pattern_id,
         session_id: session_id,
         status: :tracked
       }}
    end
  end

  defp dispatch_usage_stats do
    alias Mimo.Brain.Emergence.UsageTracker

    # UsageTracker.stats() returns a map directly, not {:ok, stats}
    stats = UsageTracker.stats()

    {:ok,
     %{
       operation: :usage_stats,
       total_patterns_tracked: Map.get(stats, :total_patterns, 0),
       total_usages: Map.get(stats, :total_usages, 0),
       patterns_with_outcomes: Map.get(stats, :patterns_with_outcomes, 0),
       average_success_rate: Map.get(stats, :average_success_rate, 0.0)
     }}
  end

  defp dispatch_ab_stats do
    alias Mimo.Brain.Emergence.ABTesting

    stats = ABTesting.stats()

    {:ok,
     %{
       operation: :ab_stats,
       test_group: %{
         sessions: stats.test_sessions,
         successes: stats.test_successes,
         failures: stats.test_failures,
         success_rate: stats.test_success_rate
       },
       control_group: %{
         sessions: stats.control_sessions,
         successes: stats.control_successes,
         failures: stats.control_failures,
         success_rate: stats.control_success_rate
       },
       lift_percentage: stats.lift,
       interpretation: interpret_ab_results(stats)
     }}
  end

  # Phase 4.2: Prediction Layer (SPEC-044 v1.4)
  #
  # Predicts which patterns are likely to emerge as capabilities.
  # Analyzes active patterns using velocity, strength trajectory, and
  # historical promotion data to predict emergence likelihood.
  #
  # Options:
  #   - limit: Maximum predictions to return (default: 10)
  #   - min_confidence: Minimum confidence threshold (default: 0.3)
  #   - pattern_id: Get prediction for a specific pattern
  defp dispatch_predict(args) do
    alias Mimo.Brain.Emergence.Metrics

    pattern_id = args["pattern_id"]

    if pattern_id do
      # Get prediction for a specific pattern
      dispatch_predict_single(pattern_id)
    else
      # Get predictions for all active patterns
      limit = InputValidation.validate_limit(args["limit"], default: 10, max: 50)
      min_confidence = args["min_confidence"] || 0.3

      result = Metrics.predict_emergence(limit: limit, min_confidence: min_confidence)

      {:ok,
       %{
         operation: :predict,
         spec: "SPEC-044 v1.4 Phase 4.2",
         model_accuracy: result.model_accuracy,
         total_active_patterns: result.total_active_patterns,
         prediction_count: result.prediction_count,
         predictions: format_predictions(result.predictions),
         interpretation: interpret_predictions(result),
         timestamp: DateTime.to_iso8601(result.timestamp)
       }}
    end
  end

  defp dispatch_predict_single(pattern_id) do
    alias Mimo.Brain.Emergence.Metrics
    alias Mimo.Brain.Emergence.Pattern

    case Mimo.Repo.get(Pattern, pattern_id) do
      nil ->
        {:error, "Pattern not found: #{pattern_id}"}

      pattern ->
        {:ok, eta_result} = Metrics.calculate_eta(pattern)
        confidence = Metrics.calculate_prediction_confidence(pattern)

        {:ok,
         %{
           operation: :predict,
           spec: "SPEC-044 v1.4 Phase 4.2",
           pattern_id: pattern.id,
           type: pattern.type,
           description: pattern.description,
           current_state: %{
             occurrences: pattern.occurrences,
             success_rate: pattern.success_rate,
             strength: pattern.strength,
             status: pattern.status
           },
           prediction: %{
             eta_days: eta_result.days,
             confidence: confidence,
             limiting_factor: eta_result.limiting_factor,
             reason: eta_result[:reason]
           },
           promotion_ready:
             pattern.occurrences >= 10 and
               pattern.success_rate >= 0.8 and
               pattern.strength >= 0.75,
           recommendation: generate_recommendation(pattern, eta_result)
         }}
    end
  end

  defp format_predictions(predictions) do
    Enum.map(predictions, fn p ->
      %{
        pattern_id: p.pattern_id,
        type: p.type,
        description: p.description,
        current_strength: p.current_strength,
        eta_days: p.eta_days,
        confidence: p.confidence,
        trajectory: p.trajectory,
        limiting_factor: p.limiting_factor,
        promotion_ready: p.promotion_ready
      }
    end)
  end

  defp interpret_predictions(result) do
    cond do
      result.prediction_count == 0 ->
        "No patterns meet the confidence threshold. Consider lowering min_confidence or running more detection cycles."

      Enum.any?(result.predictions, & &1.promotion_ready) ->
        ready_count = Enum.count(result.predictions, & &1.promotion_ready)
        "#{ready_count} pattern(s) ready for promotion. Use emergence_promote to promote them."

      true ->
        fastest = Enum.min_by(result.predictions, & &1.eta_days, fn -> nil end)

        if fastest && fastest.eta_days do
          "Nearest emergence: #{fastest.description} in ~#{fastest.eta_days} days (confidence: #{Float.round(fastest.confidence * 100, 0)}%)"
        else
          "Patterns detected but ETA cannot be estimated. More usage data needed."
        end
    end
  end

  defp generate_recommendation(pattern, eta_result) do
    cond do
      pattern.status == :promoted ->
        "Pattern already promoted."

      pattern.occurrences >= 10 and pattern.success_rate >= 0.8 and pattern.strength >= 0.75 ->
        "Ready for promotion. Run emergence_promote to promote this pattern."

      eta_result.limiting_factor == :occurrences ->
        "Pattern needs more usage. Current: #{pattern.occurrences}/10 occurrences."

      eta_result.limiting_factor == :success_rate ->
        rate_pct = Float.round(pattern.success_rate * 100, 1)
        "Pattern needs higher success rate. Current: #{rate_pct}% (target: 80%)."

      eta_result.limiting_factor == :strength ->
        "Pattern strength building. Current: #{Float.round(pattern.strength, 3)} (target: 0.75)."

      true ->
        "Continue monitoring. ETA: #{eta_result.days || "unknown"} days."
    end
  end

  defp interpret_ab_results(stats) do
    cond do
      stats.test_sessions < 10 or stats.control_sessions < 10 ->
        "Insufficient data - need more sessions for statistical significance"

      stats.lift > 10 ->
        "Positive lift: Pattern suggestions improve outcomes by #{stats.lift}%"

      stats.lift < -10 ->
        "Negative lift: Pattern suggestions may be hurting outcomes by #{abs(stats.lift)}%"

      true ->
        "No significant difference between test and control groups"
    end
  end

  defp format_impact(impact) do
    %{
      usage_count: impact.usage_count,
      success_rate: impact.success_rate,
      outcome_count: impact.outcome_count,
      recent_trend: impact.recent_trend,
      confidence: impact.confidence
    }
  end

  defp validate_required(args, key) do
    case args[key] do
      nil -> {:error, "#{key} is required"}
      value -> {:ok, value}
    end
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp parse_modes(nil), do: nil

  # ─────────────────────────────────────────────────────────────────
  # Phase 4.3: Explanation Layer (SPEC-044 v1.5)
  # ─────────────────────────────────────────────────────────────────

  defp dispatch_explain(args) do
    alias Mimo.Brain.Emergence.Explainer

    pattern_id = args["pattern_id"]
    use_llm = args["use_llm"] != false
    include_evolution = args["include_evolution"] == true
    include_prediction = args["include_prediction"] != false

    opts = [
      use_llm: use_llm,
      include_evolution: include_evolution,
      include_prediction: include_prediction
    ]

    cond do
      pattern_id ->
        # Explain specific pattern
        case Explainer.explain(pattern_id, opts) do
          {:ok, explanation} ->
            {:ok,
             %{
               operation: :explain,
               pattern_id: pattern_id,
               explanation: explanation,
               interpretation: interpret_explanation(explanation)
             }}

          {:error, :not_found} ->
            {:error, "Pattern not found: #{pattern_id}"}

          {:error, reason} ->
            {:error, "Explanation failed: #{inspect(reason)}"}
        end

      true ->
        # Explain all active patterns (batch mode)
        # Pattern.list returns a list directly, not {:ok, list}
        case Mimo.Brain.Emergence.Pattern.list(status: :active, limit: 10) do
          patterns when is_list(patterns) and patterns != [] ->
            case Explainer.explain_batch(patterns, opts) do
              {:ok, result} ->
                {:ok,
                 %{
                   operation: :explain_batch,
                   patterns_explained: result.summary.explained_count,
                   summary: result.summary,
                   explanations: Enum.take(result.explanations, 5)
                 }}
            end

          [] ->
            {:ok,
             %{
               operation: :explain,
               message: "No active patterns to explain",
               suggestion: "Run emergence_detect to find patterns first"
             }}
        end
    end
  end

  defp dispatch_hypothesize(args) do
    alias Mimo.Brain.Emergence.Explainer

    pattern_id = args["pattern_id"]

    unless pattern_id do
      {:error, "pattern_id is required for hypothesize operation"}
    else
      case Explainer.hypothesize(pattern_id) do
        {:ok, hypotheses} ->
          {:ok,
           %{
             operation: :hypothesize,
             pattern_id: pattern_id,
             hypothesis_count: length(hypotheses),
             hypotheses: hypotheses,
             interpretation: interpret_hypotheses(hypotheses)
           }}

        {:error, :not_found} ->
          {:error, "Pattern not found: #{pattern_id}"}

        {:error, reason} ->
          {:error, "Hypothesis generation failed: #{inspect(reason)}"}
      end
    end
  end

  defp interpret_explanation(%{significance: %{level: :high}} = explanation) do
    "This is a high-significance #{explanation.type} pattern. " <>
      "#{explanation.recommendation}"
  end

  defp interpret_explanation(%{significance: %{level: :medium}} = explanation) do
    "This #{explanation.type} pattern is developing. " <>
      "#{explanation.recommendation}"
  end

  defp interpret_explanation(explanation) do
    "This pattern is still emerging. #{explanation[:recommendation] || "Continue monitoring."}"
  end

  defp interpret_hypotheses(hypotheses) when hypotheses != [] do
    top = List.first(hypotheses)
    plausibility = top["plausibility"] || 0.5

    cond do
      plausibility >= 0.8 ->
        "High confidence hypothesis: #{top["hypothesis"]}"

      plausibility >= 0.5 ->
        "Moderate confidence hypothesis: #{top["hypothesis"]}"

      true ->
        "Low confidence - #{length(hypotheses)} hypotheses generated, more data needed"
    end
  end

  defp interpret_hypotheses(_),
    do: "Unable to generate hypotheses - pattern may lack sufficient context"

  # ─────────────────────────────────────────────────────────────────
  # Helper Functions
  # ─────────────────────────────────────────────────────────────────

  # map_detection_results only accepts maps
  defp map_detection_results(detection) when is_map(detection) do
    Enum.map(detection, fn {mode, result} ->
      %{
        mode: mode,
        patterns_found: length(result[:patterns] || []),
        new_patterns: result[:new] || 0
      }
    end)
  end

  defp format_alert(alert) do
    %{
      type: alert.type,
      priority: alert.priority,
      message: alert.message,
      data: alert.data
    }
  end

  defp format_pattern(pattern) do
    %{
      id: pattern.id,
      type: pattern.type,
      description: pattern.description,
      status: pattern.status,
      occurrences: pattern.occurrences,
      success_rate: pattern.success_rate,
      strength: pattern.strength,
      first_seen: pattern.first_seen,
      last_seen: pattern.last_seen
    }
  end

  # ─────────────────────────────────────────────────────────────────
  # Phase 4.4: Active Probing Functions (SPEC-044 v1.6)
  # ─────────────────────────────────────────────────────────────────

  defp dispatch_probe(args) do
    alias Mimo.Brain.Emergence.Prober

    pattern_id = args["pattern_id"]
    probe_type = String.to_existing_atom(args["type"] || "validation")

    unless pattern_id do
      {:error, "pattern_id is required for probe operation"}
    else
      # First get the pattern
      case Emergence.get_pattern(pattern_id) do
        nil ->
          {:error, "Pattern not found: #{pattern_id}"}

        pattern ->
          # Generate and execute probe task
          task = Prober.generate_probe_task(pattern, type: probe_type)
          result = Prober.probe_pattern(pattern, task)

          {:ok,
           %{
             operation: :probe,
             pattern_id: pattern_id,
             probe_type: probe_type,
             domain: Prober.classify_pattern_domain(pattern),
             task_description: task.description,
             result: %{
               success: result.success,
               confidence: result.confidence,
               probed_at: result.probed_at
             },
             interpretation: interpret_probe_result(result, probe_type)
           }}
      end
    end
  rescue
    ArgumentError ->
      alias Mimo.Brain.Emergence.Prober
      valid_types = Prober.probe_types() |> Enum.join(", ")
      {:error, "Invalid probe type. Valid types: #{valid_types}"}
  end

  defp dispatch_probe_candidates(args) do
    alias Mimo.Brain.Emergence.Prober

    limit = args["limit"] || 10
    candidates = Prober.probe_candidates(limit: limit)

    {:ok,
     %{
       operation: :probe_candidates,
       candidate_count: length(candidates),
       candidates: candidates,
       interpretation:
         if candidates != [] do
           "Found #{length(candidates)} patterns ready for probing"
         else
           "No patterns currently ready for probing"
         end
     }}
  end

  defp dispatch_capability_summary do
    alias Mimo.Brain.Emergence.Prober

    summary = Prober.capability_summary()

    {:ok,
     %{
       operation: :capability_summary,
       total_patterns: summary.total_patterns,
       domain_count: summary.domain_count,
       domains: summary.domains,
       strongest_domains: summary.strongest_domains,
       weakest_domains: summary.weakest_domains,
       updated_at: summary.updated_at
     }}
  end

  defp interpret_probe_result(%{success: true, confidence: confidence}, _type)
       when confidence >= 0.8 do
    "✅ High-confidence success - pattern capability confirmed"
  end

  defp interpret_probe_result(%{success: true, confidence: confidence}, _type)
       when confidence >= 0.5 do
    "✓ Moderate-confidence success - pattern likely effective"
  end

  defp interpret_probe_result(%{success: true}, _type) do
    "? Success with low confidence - more data needed"
  end

  defp interpret_probe_result(%{success: false, confidence: confidence}, type)
       when confidence >= 0.8 do
    "⚠️ High-confidence failure at #{type} probe - pattern may have limitations"
  end

  defp interpret_probe_result(%{success: false}, type) do
    "Failed #{type} probe - investigating boundaries"
  end
end
