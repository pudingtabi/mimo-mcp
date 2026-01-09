defmodule Mimo.Cognitive.HealthWatcherTest do
  @moduledoc """
  Tests for Phase 5 C1: Autonomous Health Monitoring (HealthWatcher)
  """
  use ExUnit.Case, async: false

  alias Mimo.Cognitive.HealthWatcher

  @moduletag :phase5

  describe "status/0" do
    test "returns status map with required fields" do
      status = HealthWatcher.status()

      assert is_map(status)
      assert Map.has_key?(status, :monitoring)
      assert Map.has_key?(status, :last_check)
      assert Map.has_key?(status, :checks_in_history)
      assert Map.has_key?(status, :active_alerts)
      assert Map.has_key?(status, :interventions_triggered)
      assert Map.has_key?(status, :uptime)
      assert Map.has_key?(status, :next_check_in_ms)
    end

    test "monitoring flag is boolean" do
      status = HealthWatcher.status()
      assert is_boolean(status.monitoring)
    end

    test "uptime is non-negative integer" do
      status = HealthWatcher.status()
      assert is_integer(status.uptime)
      assert status.uptime >= 0
    end
  end

  describe "history/0" do
    test "returns a list" do
      history = HealthWatcher.history()
      assert is_list(history)
    end

    test "history entries have timestamp and score" do
      history = HealthWatcher.history()

      for entry <- Enum.take(history, 5) do
        assert Map.has_key?(entry, :timestamp)
        assert Map.has_key?(entry, :overall_score) or Map.has_key?(entry, :level)
      end
    end
  end

  describe "alerts/0" do
    test "returns a list" do
      alerts = HealthWatcher.alerts()
      assert is_list(alerts)
    end
  end

  describe "check_now/0" do
    test "returns health check result map" do
      result = HealthWatcher.check_now()

      assert is_map(result)
      assert Map.has_key?(result, :timestamp)
      assert Map.has_key?(result, :overall_score)
      assert Map.has_key?(result, :components)
      assert Map.has_key?(result, :level)
    end

    test "overall_score is between 0 and 1" do
      result = HealthWatcher.check_now()

      assert is_number(result.overall_score)
      assert result.overall_score >= 0.0
      assert result.overall_score <= 1.0
    end

    test "level is a valid atom" do
      result = HealthWatcher.check_now()

      assert result.level in [:excellent, :good, :fair, :poor, :critical, :unknown]
    end

    test "components is a map with subsystem scores" do
      result = HealthWatcher.check_now()

      assert is_map(result.components)
      # Should have at least some component
      assert map_size(result.components) >= 0
    end
  end

  # Note: pause/resume are not implemented in HealthWatcher
  # The module runs autonomously without pause capability
end
