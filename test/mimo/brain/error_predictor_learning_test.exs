defmodule Mimo.Brain.ErrorPredictorLearningTest do
  @moduledoc """
  Tests for ErrorPredictor's Phase 3 Learning Loop integration.

  Verifies that failures from tool executions are recorded as
  learned patterns that can influence future predictions.
  """
  use ExUnit.Case, async: false

  alias Mimo.Brain.ErrorPredictor

  describe "failure learning" do
    setup do
      # Initialize the learning system (creates ETS tables)
      ErrorPredictor.init_learning()
      :ok
    end

    test "init_learning creates ETS table" do
      # Should not crash when called multiple times
      assert :ok = ErrorPredictor.init_learning()

      # Stats should be available
      stats = ErrorPredictor.stats()
      assert is_map(stats)
    end

    test "stats returns learned pattern count" do
      stats = ErrorPredictor.stats()

      assert is_map(stats)
      # The stats map uses :total_learned_patterns key
      assert Map.has_key?(stats, :total_learned_patterns)
      assert is_integer(stats.total_learned_patterns)
      assert stats.total_learned_patterns >= 0
    end

    test "record_failure stores failure pattern" do
      initial_stats = ErrorPredictor.stats()
      initial_count = initial_stats.total_learned_patterns

      # Record a failure (third arg is error message string, not a map)
      ErrorPredictor.record_failure(
        "file_edit",
        %{path: "/test/file.ex"},
        "permission denied"
      )

      # Give ETS time to update
      Process.sleep(10)

      updated_stats = ErrorPredictor.stats()

      # Should have one more pattern
      assert updated_stats.total_learned_patterns == initial_count + 1
    end

    test "record_failure handles nil context gracefully" do
      # Should not crash with nil
      assert :ok = ErrorPredictor.record_failure("test_action", %{}, nil)
    end

    test "get_learned_patterns returns patterns for action_type" do
      # Record some failures (third arg is error message string)
      ErrorPredictor.record_failure("terminal_execute", %{command: "ls"}, "timeout error")
      ErrorPredictor.record_failure("terminal_execute", %{command: "cat"}, "permission denied")
      ErrorPredictor.record_failure("file_read", %{path: "/test.txt"}, "not found")

      Process.sleep(10)

      # Get patterns for terminal_execute
      terminal_patterns = ErrorPredictor.get_learned_patterns("terminal_execute")

      assert is_list(terminal_patterns)
      assert length(terminal_patterns) >= 2
    end

    test "get_learned_patterns returns empty list for unknown action" do
      patterns = ErrorPredictor.get_learned_patterns("unknown_action_type_xyz")
      assert patterns == []
    end
  end

  describe "telemetry integration" do
    setup do
      ErrorPredictor.init_learning()
      :ok
    end

    test "telemetry handler is attached" do
      # The handler should be attached at init_learning
      handlers = :telemetry.list_handlers([:mimo, :learning, :outcome])

      handler_ids = Enum.map(handlers, & &1.id)

      # Handler is attached with string ID "error-predictor-learning"
      assert Enum.member?(handler_ids, "error-predictor-learning")
    end
  end
end
