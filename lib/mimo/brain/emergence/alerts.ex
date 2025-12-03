defmodule Mimo.Brain.Emergence.Alerts do
  @moduledoc """
  SPEC-044: Emergence alerting system.

  Monitors the emergence framework and generates alerts for:

  - **Novel Patterns**: New patterns detected in the last 24 hours
  - **Promotion Ready**: Patterns that meet promotion thresholds
  - **Pattern Evolution**: Significant changes in pattern strength
  - **Capability Milestones**: New capabilities emerged
  - **System Health**: Detection rate, quality metrics

  ## Alert Levels

  - `:info` - Informational, no action needed
  - `:notice` - Notable event, may want to review
  - `:warning` - Potential issue, should investigate
  - `:alert` - Action needed

  ## Usage

  ```elixir
  # Check all alerts
  Alerts.check_alerts()

  # Get alerts of specific type
  Alerts.check(:novel_pattern)
  Alerts.check(:promotion_ready)
  ```
  """

  require Logger

  alias Mimo.Brain.Emergence.{Pattern, Metrics, Catalog}

  @alert_types [
    :novel_pattern,
    :promotion_ready,
    :pattern_evolution,
    :capability_milestone,
    :system_health
  ]

  @type alert :: %{
          type: atom(),
          level: :info | :notice | :warning | :alert,
          message: String.t(),
          details: map(),
          timestamp: DateTime.t()
        }

  # ─────────────────────────────────────────────────────────────────
  # Public API
  # ─────────────────────────────────────────────────────────────────

  @doc """
  Checks all alert conditions and returns active alerts.
  """
  @spec check_alerts() :: [alert()]
  def check_alerts do
    @alert_types
    |> Enum.map(&check/1)
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn alert -> alert_level_priority(alert.level) end)
  end

  @doc """
  Checks a specific alert condition.
  """
  @spec check(atom()) :: alert() | [alert()] | nil
  def check(:novel_pattern), do: check_novel_pattern()
  def check(:promotion_ready), do: check_promotion_ready()
  def check(:pattern_evolution), do: check_pattern_evolution()
  def check(:capability_milestone), do: check_capability_milestone()
  def check(:system_health), do: check_system_health()
  def check(_), do: nil

  @doc """
  Gets summary of current alert status.
  """
  @spec status() :: map()
  def status do
    alerts = check_alerts()

    %{
      total_alerts: length(alerts),
      by_level:
        alerts
        |> Enum.group_by(& &1.level)
        |> Enum.map(fn {k, v} -> {k, length(v)} end)
        |> Map.new(),
      by_type:
        alerts |> Enum.group_by(& &1.type) |> Enum.map(fn {k, v} -> {k, length(v)} end) |> Map.new(),
      most_recent: List.first(alerts),
      checked_at: DateTime.utc_now()
    }
  end

  @doc """
  Dismisses an alert (marks as acknowledged).
  For now, this is a no-op as we don't persist alert state.
  """
  @spec dismiss(alert()) :: :ok
  def dismiss(_alert) do
    # Would persist dismissal to prevent re-alerting
    :ok
  end

  # ─────────────────────────────────────────────────────────────────
  # Alert Checks
  # ─────────────────────────────────────────────────────────────────

  defp check_novel_pattern do
    # Check for patterns detected in the last 24 hours
    recent_count = Pattern.count_recent(days: 1)

    cond do
      recent_count >= 10 ->
        create_alert(
          :novel_pattern,
          :notice,
          "#{recent_count} new patterns detected in the last 24 hours",
          %{count: recent_count, threshold: "high_activity"}
        )

      recent_count >= 5 ->
        create_alert(:novel_pattern, :info, "#{recent_count} new patterns detected today", %{
          count: recent_count
        })

      recent_count >= 1 ->
        create_alert(:novel_pattern, :info, "New pattern detected", %{count: recent_count})

      true ->
        nil
    end
  end

  defp check_promotion_ready do
    # Check for patterns ready for promotion
    candidates = Pattern.promotion_candidates()

    if length(candidates) > 0 do
      candidate_summaries =
        candidates
        |> Enum.take(5)
        |> Enum.map(fn p ->
          %{
            id: p.id,
            type: p.type,
            description: String.slice(p.description, 0, 40),
            strength: p.strength
          }
        end)

      level = if length(candidates) >= 5, do: :notice, else: :info

      create_alert(
        :promotion_ready,
        level,
        "#{length(candidates)} pattern(s) ready for promotion",
        %{count: length(candidates), candidates: candidate_summaries}
      )
    end
  end

  defp check_pattern_evolution do
    # Check for significant pattern changes
    improving = Pattern.improving(limit: 10)
    declining = Pattern.declining(limit: 10)

    alerts = []

    # Alert on rapidly improving patterns
    alerts =
      if length(improving) >= 3 do
        alerts ++
          [
            create_alert(
              :pattern_evolution,
              :info,
              "#{length(improving)} patterns strengthening",
              %{improving_count: length(improving), patterns: summarize_patterns(improving)}
            )
          ]
      else
        alerts
      end

    # Warn on declining patterns
    alerts =
      if length(declining) >= 3 do
        alerts ++
          [
            create_alert(
              :pattern_evolution,
              :warning,
              "#{length(declining)} patterns weakening - consider intervention",
              %{declining_count: length(declining), patterns: summarize_patterns(declining)}
            )
          ]
      else
        alerts
      end

    if alerts == [], do: nil, else: alerts
  end

  defp check_capability_milestone do
    # Check for milestone achievements
    total = Catalog.count()
    promoted = Pattern.count_promoted()

    milestones = [10, 25, 50, 100, 250, 500, 1000]

    alerts = []

    # Check total capability milestones
    alerts =
      Enum.reduce(milestones, alerts, fn milestone, acc ->
        if total >= milestone and total < milestone + 5 do
          acc ++
            [
              create_alert(
                :capability_milestone,
                :notice,
                "Milestone: #{milestone} total patterns emerged!",
                %{milestone: milestone, current: total, type: :total_patterns}
              )
            ]
        else
          acc
        end
      end)

    # Check promotion milestones
    alerts =
      Enum.reduce(milestones, alerts, fn milestone, acc ->
        if promoted >= milestone and promoted < milestone + 3 do
          acc ++
            [
              create_alert(
                :capability_milestone,
                :notice,
                "Milestone: #{milestone} patterns promoted to capabilities!",
                %{milestone: milestone, current: promoted, type: :promotions}
              )
            ]
        else
          acc
        end
      end)

    if alerts == [], do: nil, else: alerts
  end

  defp check_system_health do
    # Check overall emergence system health
    dashboard = Metrics.dashboard()

    alerts = []

    # Check detection rate
    alerts =
      if dashboard.velocity.new_patterns_weekly == 0 do
        alerts ++
          [
            create_alert(
              :system_health,
              :warning,
              "No new patterns detected this week - emergence may be stalled",
              %{metric: :detection_rate, value: 0}
            )
          ]
      else
        alerts
      end

    # Check average success rate
    alerts =
      if dashboard.quality.average_success_rate < 0.5 do
        alerts ++
          [
            create_alert(
              :system_health,
              :warning,
              "Low average pattern success rate: #{Float.round(dashboard.quality.average_success_rate * 100, 1)}%",
              %{metric: :success_rate, value: dashboard.quality.average_success_rate}
            )
          ]
      else
        alerts
      end

    # Check for too many declining patterns
    if dashboard.evolution.patterns_weakening > dashboard.evolution.patterns_strengthening * 2 do
      alerts ++
        [
          create_alert(
            :system_health,
            :warning,
            "More patterns declining than improving - review amplification strategies",
            %{
              strengthening: dashboard.evolution.patterns_strengthening,
              weakening: dashboard.evolution.patterns_weakening
            }
          )
        ]
    else
      if alerts == [], do: nil, else: alerts
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Helpers
  # ─────────────────────────────────────────────────────────────────

  defp create_alert(type, level, message, details) do
    %{
      type: type,
      level: level,
      message: message,
      details: details,
      timestamp: DateTime.utc_now()
    }
  end

  defp alert_level_priority(:alert), do: 0
  defp alert_level_priority(:warning), do: 1
  defp alert_level_priority(:notice), do: 2
  defp alert_level_priority(:info), do: 3

  defp summarize_patterns(patterns) do
    patterns
    |> Enum.take(5)
    |> Enum.map(fn p ->
      %{
        id: p.id,
        type: p.type,
        description: String.slice(p.description, 0, 30),
        strength: p.strength
      }
    end)
  end
end
