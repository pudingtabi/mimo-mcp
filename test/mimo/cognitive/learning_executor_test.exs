defmodule Mimo.Cognitive.LearningExecutorTest do
  @moduledoc """
  Tests for Phase 6 S2: Autonomous Learning Actions
  """
  use ExUnit.Case, async: false

  alias Mimo.Cognitive.LearningExecutor

  @moduletag :phase6

  describe "status/0" do
    test "returns status map with required fields" do
      status = LearningExecutor.status()

      assert is_map(status)
      assert Map.has_key?(status, :active)
      assert Map.has_key?(status, :last_execution)
      assert Map.has_key?(status, :actions_executed)
      assert Map.has_key?(status, :history_size)
      assert Map.has_key?(status, :uptime_seconds)
    end

    test "active is a boolean" do
      status = LearningExecutor.status()
      assert is_boolean(status.active)
    end

    test "actions_executed is non-negative" do
      status = LearningExecutor.status()
      assert is_integer(status.actions_executed)
      assert status.actions_executed >= 0
    end

    test "uptime_seconds is non-negative" do
      status = LearningExecutor.status()
      assert is_integer(status.uptime_seconds)
      assert status.uptime_seconds >= 0
    end
  end

  describe "execute_now/0" do
    test "returns ok with execution result" do
      result = LearningExecutor.execute_now()

      assert {:ok, execution} = result
      assert is_map(execution)
      assert Map.has_key?(execution, :objectives_addressed)
      assert Map.has_key?(execution, :successes)
      assert Map.has_key?(execution, :failures)
    end

    test "execution result has valid counts" do
      {:ok, execution} = LearningExecutor.execute_now()

      assert is_integer(execution.objectives_addressed)
      assert is_integer(execution.successes)
      assert is_integer(execution.failures)
      assert execution.successes + execution.failures <= execution.objectives_addressed
    end
  end

  describe "pause/0 and resume/0" do
    test "pause deactivates executor" do
      LearningExecutor.pause()
      status = LearningExecutor.status()
      assert status.active == false

      # Resume for other tests
      LearningExecutor.resume()
    end

    test "resume reactivates executor" do
      LearningExecutor.pause()
      LearningExecutor.resume()
      status = LearningExecutor.status()
      assert status.active == true
    end
  end

  describe "history/0" do
    test "returns a list" do
      history = LearningExecutor.history()
      assert is_list(history)
    end

    test "history entries have timestamp" do
      # Execute at least once to have history
      LearningExecutor.execute_now()
      history = LearningExecutor.history()

      if length(history) > 0 do
        entry = hd(history)
        assert Map.has_key?(entry, :timestamp)
        assert Map.has_key?(entry, :objectives_addressed)
      end
    end
  end
end
