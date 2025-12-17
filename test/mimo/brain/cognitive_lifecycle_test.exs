defmodule Mimo.Brain.CognitiveLifecycleTest do
  use ExUnit.Case, async: false
  # async: false because we're using a globally named GenServer

  alias Mimo.Brain.CognitiveLifecycle

  describe "classify_tool/2" do
    test "classifies context phase tools" do
      assert CognitiveLifecycle.classify_tool("ask_mimo", nil) == :context
      assert CognitiveLifecycle.classify_tool("memory", "search") == :context
      assert CognitiveLifecycle.classify_tool("memory", "list") == :context
      assert CognitiveLifecycle.classify_tool("knowledge", "query") == :context
      assert CognitiveLifecycle.classify_tool("prepare_context", nil) == :context
      assert CognitiveLifecycle.classify_tool("onboard", nil) == :context
    end

    test "classifies deliberate phase tools" do
      assert CognitiveLifecycle.classify_tool("reason", "guided") == :deliberate
      assert CognitiveLifecycle.classify_tool("think", "plan") == :deliberate
      assert CognitiveLifecycle.classify_tool("cognitive", "assess") == :deliberate
      assert CognitiveLifecycle.classify_tool("code", "definition") == :deliberate
      assert CognitiveLifecycle.classify_tool("code", "diagnose") == :deliberate
      assert CognitiveLifecycle.classify_tool("reflector", "reflect") == :deliberate
    end

    test "classifies action phase tools" do
      assert CognitiveLifecycle.classify_tool("file", "read") == :action
      assert CognitiveLifecycle.classify_tool("file", "edit") == :action
      assert CognitiveLifecycle.classify_tool("terminal", "execute") == :action
      assert CognitiveLifecycle.classify_tool("web", "fetch") == :action
    end

    test "classifies learn phase tools" do
      assert CognitiveLifecycle.classify_tool("memory", "store") == :learn
      assert CognitiveLifecycle.classify_tool("knowledge", "teach") == :learn
      assert CognitiveLifecycle.classify_tool("ingest", nil) == :learn
      assert CognitiveLifecycle.classify_tool("emergence", "promote") == :learn
    end

    test "returns unknown for unrecognized tools" do
      assert CognitiveLifecycle.classify_tool("unknown_tool", nil) == :unknown
    end
  end

  describe "track_transition/3" do
    setup do
      # Use unique thread IDs to avoid state pollution
      thread_id = "test_thread_#{System.unique_integer([:positive])}"
      {:ok, thread_id: thread_id}
    end

    test "tracks phase transitions", %{thread_id: thread_id} do
      {:ok, result} = CognitiveLifecycle.track_transition(thread_id, "memory", "search")
      assert result.phase == :context
      assert result.warnings == []
    end

    test "detects action without context anti-pattern", %{thread_id: thread_id} do
      # Jump directly to action without context
      {:ok, result} = CognitiveLifecycle.track_transition(thread_id, "file", "edit")
      assert result.phase == :action
      assert length(result.warnings) > 0
      assert Enum.any?(result.warnings, &(&1.type == :action_without_context))
    end

    test "no warning when context gathered first", %{thread_id: thread_id} do
      # First gather context
      {:ok, _} = CognitiveLifecycle.track_transition(thread_id, "memory", "search")

      # Then action
      {:ok, result} = CognitiveLifecycle.track_transition(thread_id, "file", "edit")
      assert result.phase == :action
      assert result.warnings == []
    end

    test "clears thread state", %{thread_id: thread_id} do
      # Track some transitions
      {:ok, _} = CognitiveLifecycle.track_transition(thread_id, "memory", "search")

      # Verify state exists
      state = CognitiveLifecycle.get_thread_state(thread_id)
      assert state != nil

      # Clear state
      :ok = CognitiveLifecycle.clear_thread(thread_id)

      # Allow async cast to process
      Process.sleep(10)

      # State should be nil now
      assert CognitiveLifecycle.get_thread_state(thread_id) == nil
    end
  end

  describe "get_phase_distribution/1" do
    setup do
      thread_id = "dist_test_#{System.unique_integer([:positive])}"
      {:ok, thread_id: thread_id}
    end

    test "returns distribution for new thread", %{thread_id: thread_id} do
      distribution = CognitiveLifecycle.get_phase_distribution(thread_id)

      assert distribution.total == 0
      assert distribution.counts.context == 0
      assert distribution.counts.action == 0
      assert distribution.health == :insufficient_data
    end

    test "calculates percentages correctly", %{thread_id: thread_id} do
      # Add some interactions
      CognitiveLifecycle.track_transition(thread_id, "memory", "search")
      CognitiveLifecycle.track_transition(thread_id, "memory", "search")
      CognitiveLifecycle.track_transition(thread_id, "reason", "guided")
      CognitiveLifecycle.track_transition(thread_id, "file", "read")
      CognitiveLifecycle.track_transition(thread_id, "file", "edit")
      CognitiveLifecycle.track_transition(thread_id, "file", "write")
      CognitiveLifecycle.track_transition(thread_id, "file", "edit")
      CognitiveLifecycle.track_transition(thread_id, "file", "read")
      CognitiveLifecycle.track_transition(thread_id, "memory", "store")
      CognitiveLifecycle.track_transition(thread_id, "knowledge", "teach")

      distribution = CognitiveLifecycle.get_phase_distribution(thread_id)

      assert distribution.total == 10
      assert distribution.counts.context == 2
      assert distribution.counts.deliberate == 1
      assert distribution.counts.action == 5
      assert distribution.counts.learn == 2

      # Check percentages
      assert distribution.percentages.context == 20.0
      assert distribution.percentages.deliberate == 10.0
      assert distribution.percentages.action == 50.0
      assert distribution.percentages.learn == 20.0
    end
  end

  describe "stats/0" do
    test "returns aggregate statistics" do
      stats = CognitiveLifecycle.stats()

      assert Map.has_key?(stats, :total_threads)
      assert Map.has_key?(stats, :active_threads)
      assert Map.has_key?(stats, :total_interactions)
      assert Map.has_key?(stats, :phase_distribution)
      assert Map.has_key?(stats, :warning_summary)
      assert Map.has_key?(stats, :health)
    end
  end

  describe "target_ranges/0" do
    test "returns target ranges for phases" do
      ranges = CognitiveLifecycle.target_ranges()

      assert ranges.context == {0.15, 0.20}
      assert ranges.deliberate == {0.15, 0.20}
      assert ranges.action == {0.45, 0.55}
      assert ranges.learn == {0.10, 0.15}
    end
  end
end
