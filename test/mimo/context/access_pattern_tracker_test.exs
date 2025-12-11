defmodule Mimo.Context.AccessPatternTrackerTest do
  use ExUnit.Case, async: true

  alias Mimo.Context.AccessPatternTracker

  describe "detect_task_type/1" do
    test "detects coding tasks" do
      assert AccessPatternTracker.detect_task_type("implement user authentication") == :coding
      assert AccessPatternTracker.detect_task_type("add a new feature") == :coding
      assert AccessPatternTracker.detect_task_type("create the login page") == :coding
    end

    test "detects debugging tasks" do
      assert AccessPatternTracker.detect_task_type("debug the login issue") == :debugging
      assert AccessPatternTracker.detect_task_type("fix this bug") == :debugging
      assert AccessPatternTracker.detect_task_type("error in production") == :debugging
    end

    test "detects architecture tasks" do
      assert AccessPatternTracker.detect_task_type("design the API structure") == :architecture
      assert AccessPatternTracker.detect_task_type("refactor the auth module") == :architecture
      assert AccessPatternTracker.detect_task_type("plan the migration") == :architecture
    end

    test "detects documentation tasks" do
      assert AccessPatternTracker.detect_task_type("document the API") == :documentation
      assert AccessPatternTracker.detect_task_type("explain how this works") == :documentation
      assert AccessPatternTracker.detect_task_type("update the readme") == :documentation
    end

    test "detects research tasks" do
      assert AccessPatternTracker.detect_task_type("research best practices") == :research
      assert AccessPatternTracker.detect_task_type("investigate the performance") == :research
      assert AccessPatternTracker.detect_task_type("analyze the codebase") == :research
    end

    test "detects testing tasks" do
      assert AccessPatternTracker.detect_task_type("test the new feature") == :testing
      assert AccessPatternTracker.detect_task_type("verify the fix works") == :testing
      assert AccessPatternTracker.detect_task_type("check the assertions") == :testing
    end

    test "returns :general for unknown tasks" do
      assert AccessPatternTracker.detect_task_type("hello world") == :general
      assert AccessPatternTracker.detect_task_type("") == :general
    end
  end

  describe "track_access/3 and predict/1 integration" do
    setup do
      # Start the GenServer for this test
      start_supervised!(AccessPatternTracker)
      :ok
    end

    test "tracks access and generates predictions" do
      # Track some accesses for coding tasks
      AccessPatternTracker.track_access(:memory, 1, task: "implement auth")
      AccessPatternTracker.track_access(:code_symbol, "login", task: "implement auth")
      AccessPatternTracker.track_access(:memory, 2, task: "implement auth")

      # Give GenServer time to process
      Process.sleep(10)

      # Get predictions for a similar task
      predictions = AccessPatternTracker.predict("implement user feature")

      assert predictions.task_type == :coding
      assert is_map(predictions.source_predictions)
      assert is_float(predictions.confidence)
    end

    test "returns default predictions without history" do
      predictions = AccessPatternTracker.predict("some random task")

      assert is_atom(predictions.task_type)
      assert is_map(predictions.source_predictions)
      assert predictions.based_on_samples >= 0
    end
  end

  describe "patterns/0" do
    setup do
      start_supervised!(AccessPatternTracker)
      :ok
    end

    test "returns pattern structure" do
      patterns = AccessPatternTracker.patterns()

      assert Map.has_key?(patterns, :task_types)
      assert Map.has_key?(patterns, :access_counts)
      assert Map.has_key?(patterns, :co_occurrences)
    end
  end

  describe "stats/0" do
    setup do
      start_supervised!(AccessPatternTracker)
      :ok
    end

    test "returns statistics" do
      stats = AccessPatternTracker.stats()

      assert Map.has_key?(stats, :total_tracked)
      assert Map.has_key?(stats, :task_types_seen)
      assert Map.has_key?(stats, :co_occurrence_pairs)
      assert Map.has_key?(stats, :uptime_seconds)
    end

    test "tracks total accesses" do
      AccessPatternTracker.track_access(:memory, 1, task: "test")
      AccessPatternTracker.track_access(:memory, 2, task: "test")
      AccessPatternTracker.track_access(:memory, 3, task: "test")
      Process.sleep(10)

      stats = AccessPatternTracker.stats()
      assert stats.total_tracked >= 3
    end
  end
end
