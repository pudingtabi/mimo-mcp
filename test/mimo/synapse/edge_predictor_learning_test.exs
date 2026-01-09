defmodule Mimo.Synapse.EdgePredictorLearningTest do
  @moduledoc """
  Tests for EdgePredictor's Phase 3 L3 learning integration.

  Verifies that successfully used memory pairs are tracked
  and boost prediction scores.
  """
  use ExUnit.Case, async: false

  alias Mimo.Synapse.EdgePredictor

  describe "learning integration" do
    setup do
      # Initialize learning (creates ETS table and attaches telemetry)
      EdgePredictor.init_learning()
      :ok
    end

    test "init_learning creates ETS table" do
      # Should not crash when called multiple times
      assert :ok = EdgePredictor.init_learning()

      # ETS table should exist
      assert :ets.whereis(:mimo_edge_predictor_validated) != :undefined
    end

    test "record_validated_pair stores pair" do
      # Record a pair
      EdgePredictor.record_validated_pair(100, 200)

      # Should be able to retrieve count
      count = EdgePredictor.get_validation_count(100, 200)
      assert count >= 1
    end

    test "get_validation_count returns 0 for unknown pairs" do
      count = EdgePredictor.get_validation_count(999_999, 888_888)
      assert count == 0
    end

    test "validation counts increment" do
      # Record multiple times
      EdgePredictor.record_validated_pair(300, 400)
      EdgePredictor.record_validated_pair(300, 400)
      EdgePredictor.record_validated_pair(300, 400)

      count = EdgePredictor.get_validation_count(300, 400)
      assert count >= 3
    end

    test "pair order doesn't matter" do
      # Record with one order
      EdgePredictor.record_validated_pair(500, 600)

      # Count should work with either order
      count1 = EdgePredictor.get_validation_count(500, 600)
      count2 = EdgePredictor.get_validation_count(600, 500)

      assert count1 == count2
    end

    test "stats includes validated pairs count" do
      # Record some pairs
      EdgePredictor.record_validated_pair(700, 800)
      EdgePredictor.record_validated_pair(701, 802)

      stats = EdgePredictor.stats()

      assert is_map(stats)
      assert Map.has_key?(stats, :validated_pairs)
      assert is_integer(stats.validated_pairs)
      assert stats.validated_pairs >= 2
    end

    test "stats includes validation boost value" do
      stats = EdgePredictor.stats()

      assert Map.has_key?(stats, :validation_boost)
      assert is_float(stats.validation_boost)
      assert stats.validation_boost > 0
    end
  end

  describe "telemetry handler" do
    setup do
      EdgePredictor.init_learning()
      :ok
    end

    test "telemetry handler is attached" do
      handlers = :telemetry.list_handlers([:mimo, :learning, :outcome])

      handler_ids = Enum.map(handlers, & &1.id)

      # Should have our handler attached
      assert Enum.any?(handler_ids, fn id ->
               is_tuple(id) and elem(id, 0) == Mimo.Synapse.EdgePredictor
             end)
    end

    test "telemetry with success=true records pairs" do
      # Emit telemetry event
      :telemetry.execute(
        [:mimo, :learning, :outcome],
        %{duration: 100},
        %{
          success: true,
          memory_ids: [1001, 1002, 1003]
        }
      )

      # Give time for handler to process
      Process.sleep(50)

      # Should have recorded pairs
      count_12 = EdgePredictor.get_validation_count(1001, 1002)
      count_13 = EdgePredictor.get_validation_count(1001, 1003)
      count_23 = EdgePredictor.get_validation_count(1002, 1003)

      # At least some pairs should be recorded
      total = count_12 + count_13 + count_23
      assert total >= 3
    end

    test "telemetry with success=false does not record pairs" do
      # Record initial counts
      initial = EdgePredictor.get_validation_count(2001, 2002)

      # Emit failed telemetry event
      :telemetry.execute(
        [:mimo, :learning, :outcome],
        %{duration: 100},
        %{
          success: false,
          memory_ids: [2001, 2002, 2003]
        }
      )

      Process.sleep(50)

      # Count should not have increased
      after_count = EdgePredictor.get_validation_count(2001, 2002)
      assert after_count == initial
    end
  end
end
