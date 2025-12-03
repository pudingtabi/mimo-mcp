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
  """

  require Logger

  alias Mimo.Brain.Emergence
  alias Mimo.Brain.Emergence.Scheduler

  @doc """
  Dispatch emergence operation based on args.
  """
  def dispatch(args) do
    op = args["operation"] || "dashboard"

    case op do
      "detect" ->
        dispatch_detect(args)

      "dashboard" ->
        dispatch_dashboard()

      "alerts" ->
        dispatch_alerts()

      "amplify" ->
        dispatch_amplify()

      "promote" ->
        dispatch_promote(args)

      "cycle" ->
        dispatch_cycle(args)

      "list" ->
        dispatch_list(args)

      "search" ->
        dispatch_search(args)

      "suggest" ->
        dispatch_suggest(args)

      "status" ->
        dispatch_status()

      "pattern" ->
        dispatch_pattern(args)

      _ ->
        {:error,
         "Unknown emergence operation: #{op}. Available: detect, dashboard, alerts, amplify, promote, cycle, list, search, suggest, status, pattern"}
    end
  end

  # ============================================================================
  # Operation Dispatchers
  # ============================================================================

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
        {:error, "Detection failed: #{inspect(reason)}"}
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
    case Emergence.amplify() do
      {:ok, result} ->
        {:ok,
         %{
           operation: :amplify,
           strategies_run: Map.keys(result),
           results: result
         }}

      {:error, reason} ->
        {:error, "Amplification failed: #{inspect(reason)}"}
    end
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
    limit = args["limit"] || 100
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
      limit = args["limit"] || 10
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

  # ============================================================================
  # Helpers
  # ============================================================================

  defp parse_modes(nil), do: nil

  defp parse_modes(modes) when is_list(modes) do
    Enum.map(modes, fn mode ->
      if is_atom(mode), do: mode, else: String.to_atom(mode)
    end)
  end

  defp parse_modes(_), do: nil

  defp map_detection_results(detection) when is_map(detection) do
    Enum.map(detection, fn {mode, result} ->
      %{
        mode: mode,
        patterns_found: length(result[:patterns] || []),
        new_patterns: result[:new] || 0
      }
    end)
  end

  defp map_detection_results(_), do: []

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
