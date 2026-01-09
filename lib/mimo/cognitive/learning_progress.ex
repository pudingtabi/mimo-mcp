defmodule Mimo.Cognitive.LearningProgress do
  @moduledoc """
  Phase 6 S3: Learning Progress Tracker

  Monitors progress toward learning objectives and adjusts strategies
  based on what's working.

  ## Philosophy

  Learning is not just about taking actions—it's about measuring results
  and adapting. This module:
  - Tracks objective completion rates
  - Measures learning effectiveness
  - Identifies stuck objectives
  - Suggests strategy changes

  ## Metrics Tracked

  - Objective completion rate (addressed / total)
  - Time to address (how long objectives take)
  - Recurrence rate (do similar objectives keep appearing?)
  - Strategy effectiveness (which action types work best?)

  ## Integration

  Works with:
  - LearningObjectives: Gets objective data
  - LearningExecutor: Gets execution results
  - EvolutionDashboard: Correlates with overall evolution
  - FeedbackLoop: Records learning outcomes

  ## Usage

      # Get overall learning progress
      LearningProgress.summary()

      # Get detailed progress metrics
      LearningProgress.detailed_metrics()

      # Get stuck objectives needing attention
      LearningProgress.stuck_objectives()

      # Get strategy recommendations
      LearningProgress.strategy_recommendations()
  """

  require Logger

  alias Mimo.Cognitive.{LearningObjectives, LearningExecutor, EvolutionDashboard, FeedbackLoop}

  @doc """
  Returns a summary of learning progress.
  """
  @spec summary() :: map()
  def summary do
    objectives = safe_call(fn -> LearningObjectives.stats() end, %{})
    executor = safe_call(fn -> LearningExecutor.status() end, %{})
    evolution = safe_call(fn -> EvolutionDashboard.evolution_score() end, %{})

    total = Map.get(objectives, :total, 0)
    active = Map.get(objectives, :active, 0)
    addressed = Map.get(objectives, :addressed, 0)

    completion_rate = if total > 0, do: addressed / total, else: 0.0

    %{
      objectives: %{
        total: total,
        active: active,
        addressed: addressed,
        completion_rate: completion_rate
      },
      execution: %{
        actions_executed: Map.get(executor, :actions_executed, 0),
        executor_active: Map.get(executor, :active, false),
        last_execution: Map.get(executor, :last_execution)
      },
      evolution: %{
        overall_score: Map.get(evolution, :overall_score, 0.0),
        level: Map.get(evolution, :level, :unknown)
      },
      health: learning_health_status(completion_rate, active)
    }
  end

  @doc """
  Returns detailed metrics about learning effectiveness.
  """
  @spec detailed_metrics() :: map()
  def detailed_metrics do
    objectives = safe_call(fn -> LearningObjectives.stats() end, %{})
    executor_history = safe_call(fn -> LearningExecutor.history() end, [])

    # Analyze executor history
    {total_executed, success_count, failure_count} =
      Enum.reduce(executor_history, {0, 0, 0}, fn record, {total, success, fail} ->
        {
          total + Map.get(record, :objectives_addressed, 0),
          success + Map.get(record, :successes, 0),
          fail + Map.get(record, :failures, 0)
        }
      end)

    success_rate = if total_executed > 0, do: success_count / total_executed, else: 0.0

    # Analyze by objective type
    type_distribution = Map.get(objectives, :by_type, %{})
    urgency_distribution = Map.get(objectives, :by_urgency, %{})

    %{
      execution_metrics: %{
        total_actions: total_executed,
        successes: success_count,
        failures: failure_count,
        success_rate: success_rate
      },
      objective_distribution: %{
        by_type: type_distribution,
        by_urgency: urgency_distribution
      },
      history_size: length(executor_history),
      generation_count: Map.get(objectives, :generation_count, 0)
    }
  end

  @doc """
  Identifies stuck objectives that have been active for too long.
  """
  @spec stuck_objectives() :: [map()]
  def stuck_objectives do
    objectives = safe_call(fn -> LearningObjectives.prioritized() end, [])

    now = DateTime.utc_now()

    # Consider an objective "stuck" if it's been active for more than 1 hour
    stuck_threshold_seconds = 3600

    Enum.filter(objectives, fn obj ->
      case Map.get(obj, :created_at) do
        nil ->
          false

        created_at when is_struct(created_at, DateTime) ->
          DateTime.diff(now, created_at, :second) > stuck_threshold_seconds

        _ ->
          false
      end
    end)
    |> Enum.map(fn obj ->
      age_seconds = DateTime.diff(now, obj.created_at, :second)

      Map.merge(obj, %{
        age_minutes: div(age_seconds, 60),
        status: :stuck
      })
    end)
  end

  @doc """
  Provides strategy recommendations based on learning patterns.
  """
  @spec strategy_recommendations() :: [map()]
  def strategy_recommendations do
    metrics = detailed_metrics()
    stuck = stuck_objectives()

    recommendations = []

    # Check success rate
    success_rate = get_in(metrics, [:execution_metrics, :success_rate]) || 0.0

    recommendations =
      if success_rate < 0.5 do
        [
          %{
            type: :low_success_rate,
            severity: :warning,
            message: "Learning action success rate is low (#{round(success_rate * 100)}%)",
            suggestion: "Consider simplifying objectives or adjusting action strategies"
          }
          | recommendations
        ]
      else
        recommendations
      end

    # Check for stuck objectives
    recommendations =
      if length(stuck) > 3 do
        [
          %{
            type: :stuck_objectives,
            severity: :warning,
            message: "#{length(stuck)} objectives have been stuck for over an hour",
            suggestion: "Consider breaking down complex objectives or marking them as deferred"
          }
          | recommendations
        ]
      else
        recommendations
      end

    # Check type distribution for patterns
    type_dist = get_in(metrics, [:objective_distribution, :by_type]) || %{}

    dominant_type =
      type_dist
      |> Enum.max_by(fn {_type, count} -> count end, fn -> {:none, 0} end)

    recommendations =
      if elem(dominant_type, 1) > 5 do
        [
          %{
            type: :type_concentration,
            severity: :info,
            message: "High concentration of #{elem(dominant_type, 0)} objectives",
            suggestion: "May indicate a systemic gap in #{elem(dominant_type, 0)} capabilities"
          }
          | recommendations
        ]
      else
        recommendations
      end

    # Check calibration via FeedbackLoop
    calibration_warnings = safe_call(fn -> FeedbackLoop.calibration_warnings() end, [])

    recommendations =
      if length(calibration_warnings) > 0 do
        [
          %{
            type: :calibration_needed,
            severity: :info,
            message: "#{length(calibration_warnings)} categories need confidence calibration",
            suggestion: "Record more outcomes to improve calibration accuracy"
          }
          | recommendations
        ]
      else
        recommendations
      end

    recommendations
  end

  @doc """
  Calculates a learning velocity score (rate of learning over time).
  """
  @spec learning_velocity() :: map()
  def learning_velocity do
    executor_history = safe_call(fn -> LearningExecutor.history() end, [])

    # Group by hour
    now = DateTime.utc_now()

    hourly_stats =
      executor_history
      |> Enum.group_by(fn record ->
        case Map.get(record, :timestamp) do
          %DateTime{} = ts -> DateTime.diff(now, ts, :hour)
          _ -> 0
        end
      end)
      |> Enum.map(fn {hours_ago, records} ->
        total_actions = Enum.sum(Enum.map(records, &Map.get(&1, :objectives_addressed, 0)))
        successes = Enum.sum(Enum.map(records, &Map.get(&1, :successes, 0)))
        {hours_ago, %{actions: total_actions, successes: successes}}
      end)
      |> Enum.sort_by(fn {hours_ago, _} -> hours_ago end)

    recent_velocity =
      hourly_stats
      # Last 3 hours
      |> Enum.take(3)
      |> Enum.map(fn {_, stats} -> stats.actions end)
      |> average()

    %{
      hourly_breakdown: hourly_stats,
      recent_velocity: recent_velocity,
      trend: velocity_trend(hourly_stats)
    }
  end

  # ─────────────────────────────────────────────────────────────────
  # Private Helpers
  # ─────────────────────────────────────────────────────────────────

  defp learning_health_status(completion_rate, active_count) do
    cond do
      completion_rate > 0.8 and active_count < 5 ->
        %{status: :excellent, message: "Learning on track, few active objectives"}

      completion_rate > 0.6 ->
        %{status: :good, message: "Healthy learning progress"}

      completion_rate > 0.3 ->
        %{status: :moderate, message: "Learning making progress"}

      active_count > 10 ->
        %{status: :overwhelmed, message: "Too many active objectives"}

      true ->
        %{status: :slow, message: "Learning progress is slow"}
    end
  end

  defp velocity_trend(hourly_stats) when length(hourly_stats) < 2, do: :insufficient_data

  defp velocity_trend(hourly_stats) do
    # Compare recent vs older activity
    recent = hourly_stats |> Enum.take(3) |> Enum.map(fn {_, s} -> s.actions end) |> average()

    older =
      hourly_stats
      |> Enum.drop(3)
      |> Enum.take(3)
      |> Enum.map(fn {_, s} -> s.actions end)
      |> average()

    cond do
      recent > older * 1.2 -> :accelerating
      recent < older * 0.8 -> :slowing
      true -> :steady
    end
  end

  defp average([]), do: 0.0
  defp average(list), do: Enum.sum(list) / length(list)

  defp safe_call(fun, default) do
    try do
      fun.()
    rescue
      _ -> default
    catch
      :exit, _ -> default
    end
  end
end
