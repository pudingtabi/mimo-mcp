defmodule Mimo.Cognitive.BehavioralSelfKnowledgeTest do
  @moduledoc """
  Tests for Level 2: Behavioral Self-Knowledge (SPEC-SELF-UNDERSTANDING)
  """
  use ExUnit.Case, async: false

  alias Mimo.Cognitive.FeedbackLoop

  @moduletag :behavioral_self_knowledge

  # FeedbackLoop is started by the application supervisor

  describe "daily_activity_summary/1" do
    test "returns structured summary with required fields" do
      # Record some test outcomes
      FeedbackLoop.record_outcome(
        :tool_execution,
        %{tool: "memory", operation: "search"},
        %{success: true, latency_ms: 45}
      )

      FeedbackLoop.record_outcome(
        :tool_execution,
        %{tool: "file", operation: "read"},
        %{success: true, latency_ms: 120}
      )

      FeedbackLoop.record_outcome(
        :tool_execution,
        %{tool: "code", operation: "symbols"},
        %{success: false, error: "timeout"}
      )

      # Give async cast time to process
      :timer.sleep(100)

      summary = FeedbackLoop.daily_activity_summary()

      # Check required fields
      assert is_map(summary)
      assert Map.has_key?(summary, :period)
      assert Map.has_key?(summary, :total_actions)
      assert Map.has_key?(summary, :success_rate)
      assert Map.has_key?(summary, :by_category)
      assert Map.has_key?(summary, :by_tool)
      assert Map.has_key?(summary, :notable_events)
      assert Map.has_key?(summary, :learning_progress)
    end

    test "success_rate is between 0 and 1" do
      FeedbackLoop.record_outcome(
        :tool_execution,
        %{tool: "test", operation: "run"},
        %{success: true}
      )

      :timer.sleep(50)

      summary = FeedbackLoop.daily_activity_summary()

      assert summary.success_rate >= 0.0
      assert summary.success_rate <= 1.0
    end
  end

  describe "get_activity_timeline/1" do
    test "returns list of timeline entries" do
      FeedbackLoop.record_outcome(
        :tool_execution,
        %{tool: "memory", operation: "search"},
        %{success: true, latency_ms: 45}
      )

      :timer.sleep(50)

      timeline = FeedbackLoop.get_activity_timeline(limit: 10)

      assert is_list(timeline)
    end

    test "respects limit option" do
      # Record more than limit
      for i <- 1..5 do
        FeedbackLoop.record_outcome(
          :tool_execution,
          %{tool: "test", operation: "op_#{i}"},
          %{success: true}
        )
      end

      :timer.sleep(50)

      timeline = FeedbackLoop.get_activity_timeline(limit: 3)

      assert length(timeline) <= 3
    end
  end

  describe "behavioral_metrics/0" do
    test "returns structured metrics" do
      FeedbackLoop.record_outcome(
        :tool_execution,
        %{tool: "memory", operation: "search"},
        %{success: true}
      )

      :timer.sleep(50)

      metrics = FeedbackLoop.behavioral_metrics()

      assert is_map(metrics)
      assert Map.has_key?(metrics, :session_activity)
      assert Map.has_key?(metrics, :recent_success_rate)
      assert Map.has_key?(metrics, :top_operations)
      assert Map.has_key?(metrics, :error_patterns)
      assert Map.has_key?(metrics, :behavioral_consistency)
    end

    test "recent_success_rate is between 0 and 1" do
      FeedbackLoop.record_outcome(
        :tool_execution,
        %{tool: "test", operation: "run"},
        %{success: false, error: "test"}
      )

      :timer.sleep(50)

      metrics = FeedbackLoop.behavioral_metrics()

      assert metrics.recent_success_rate >= 0.0
      assert metrics.recent_success_rate <= 1.0
    end
  end
end
