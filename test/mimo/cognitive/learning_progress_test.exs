defmodule Mimo.Cognitive.LearningProgressTest do
  @moduledoc """
  Tests for Phase 6 S3: Learning Progress Tracker
  """
  use ExUnit.Case, async: true

  alias Mimo.Cognitive.LearningProgress

  @moduletag :phase6

  describe "summary/0" do
    test "returns summary map with required sections" do
      summary = LearningProgress.summary()

      assert is_map(summary)
      assert Map.has_key?(summary, :objectives)
      assert Map.has_key?(summary, :execution)
      assert Map.has_key?(summary, :evolution)
      assert Map.has_key?(summary, :health)
    end

    test "objectives section has counts" do
      summary = LearningProgress.summary()

      assert Map.has_key?(summary.objectives, :total)
      assert Map.has_key?(summary.objectives, :active)
      assert Map.has_key?(summary.objectives, :addressed)
      assert Map.has_key?(summary.objectives, :completion_rate)
    end

    test "completion_rate is between 0 and 1" do
      summary = LearningProgress.summary()

      assert is_number(summary.objectives.completion_rate)
      assert summary.objectives.completion_rate >= 0.0
      assert summary.objectives.completion_rate <= 1.0
    end

    test "execution section has action count" do
      summary = LearningProgress.summary()

      assert Map.has_key?(summary.execution, :actions_executed)
      assert is_integer(summary.execution.actions_executed)
    end

    test "health is a map with status and message" do
      summary = LearningProgress.summary()

      assert is_map(summary.health)
      assert Map.has_key?(summary.health, :status)
      assert Map.has_key?(summary.health, :message)
      assert summary.health.status in [:excellent, :good, :moderate, :overwhelmed, :slow]
    end
  end

  describe "detailed_metrics/0" do
    test "returns metrics map" do
      metrics = LearningProgress.detailed_metrics()

      assert is_map(metrics)
    end

    test "metrics include execution_metrics section" do
      metrics = LearningProgress.detailed_metrics()

      assert Map.has_key?(metrics, :execution_metrics)
      assert Map.has_key?(metrics.execution_metrics, :successes)
      assert Map.has_key?(metrics.execution_metrics, :failures)
      assert Map.has_key?(metrics.execution_metrics, :success_rate)
    end

    test "success_rate is valid" do
      metrics = LearningProgress.detailed_metrics()

      rate = metrics.execution_metrics.success_rate
      assert is_number(rate)
      assert rate >= 0.0
      assert rate <= 1.0
    end
  end

  describe "stuck_objectives/0" do
    test "returns a list" do
      stuck = LearningProgress.stuck_objectives()
      assert is_list(stuck)
    end
  end

  describe "strategy_recommendations/0" do
    test "returns a list" do
      recommendations = LearningProgress.strategy_recommendations()
      assert is_list(recommendations)
    end

    test "recommendations have required fields if present" do
      recommendations = LearningProgress.strategy_recommendations()

      for rec <- recommendations do
        assert Map.has_key?(rec, :type)
        assert Map.has_key?(rec, :severity)
        assert Map.has_key?(rec, :message)
        assert Map.has_key?(rec, :suggestion)
      end
    end
  end

  describe "learning_velocity/0" do
    test "returns velocity map with required fields" do
      velocity = LearningProgress.learning_velocity()

      assert is_map(velocity)
      assert Map.has_key?(velocity, :trend)
      assert Map.has_key?(velocity, :recent_velocity)
      assert Map.has_key?(velocity, :hourly_breakdown)
    end

    test "trend is a valid direction or insufficient_data" do
      velocity = LearningProgress.learning_velocity()

      assert velocity.trend in [:accelerating, :stable, :decelerating, :stalled, :insufficient_data]
    end

    test "recent_velocity is a number" do
      velocity = LearningProgress.learning_velocity()

      assert is_number(velocity.recent_velocity)
      assert velocity.recent_velocity >= 0.0
    end
  end
end
