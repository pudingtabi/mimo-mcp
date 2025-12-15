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

  # ==========================================================================
  # Multi-Head Dispatch by Operation
  # ==========================================================================
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

  defp do_dispatch(op, _args) do
    {:error,
     "Unknown emergence operation: #{op}. Available: detect, dashboard, alerts, amplify, promote, cycle, list, search, suggest, status, pattern, impact, track_usage, usage_stats, ab_stats"}
  end

  # ============================================================================
  # Operation Dispatchers
  # ============================================================================

  defp dispatch_detect(args) do
    days = args["days"] || 7
    modes = parse_modes(args["modes"])

    opts = [days: days]
    opts = if modes, do: Keyword.put(opts, :modes, modes), else: opts

    # detect_patterns always returns {:ok, result}
    {:ok, result} = Emergence.detect_patterns(opts)

    {:ok,
     %{
       operation: :detect,
       days_analyzed: days,
       detection_modes: map_detection_results(result)
     }}
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

  # ============================================================================
  # Helpers
  # ============================================================================

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

  defp parse_modes(modes) when is_list(modes) do
    Enum.map(modes, fn mode ->
      if is_atom(mode), do: mode, else: String.to_atom(mode)
    end)
  end

  defp parse_modes(_), do: nil

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
end
