defmodule Mimo.Cognitive.CapabilityBoundaryTest do
  @moduledoc """
  Tests for Level 3 Capability Boundary Detection.

  The CapabilityBoundary GenServer is already started by the application
  supervisor, so we just use it directly.
  """
  use ExUnit.Case, async: false

  alias Mimo.Cognitive.CapabilityBoundary

  describe "can_handle?/1" do
    test "returns ok for unknown queries (no boundaries)" do
      # Use unique query to avoid interference from other tests
      unique_query = "unique_query_#{System.unique_integer()}"
      context = %{query: unique_query, tool: "unique_tool"}

      assert {:ok, confidence} = CapabilityBoundary.can_handle?(context)

      assert is_float(confidence)
      assert confidence > 0.5
    end

    test "can_handle returns valid response type" do
      context = %{query: "Test query", tool: "terminal"}

      result = CapabilityBoundary.can_handle?(context)

      # Should return one of the valid response types
      case result do
        {:ok, confidence} -> assert is_float(confidence)
        {:uncertain, reason} -> assert is_binary(reason)
        {:no, explanation} -> assert is_binary(explanation)
      end
    end
  end

  describe "record_boundary/2" do
    test "records a boundary from failure" do
      context = %{tool: "file", operation: "write", query: "write to protected"}

      # Should not raise
      assert :ok = CapabilityBoundary.record_boundary(context, "Permission denied")
    end

    test "handles repeated failures gracefully" do
      context = %{tool: "test_repeat", operation: "execute", query: "repeat test"}

      # Record same failure multiple times
      for _ <- 1..3 do
        :ok = CapabilityBoundary.record_boundary(context, "Timeout error")
      end

      # Should still be able to get stats
      {:ok, stats} = CapabilityBoundary.stats()
      assert is_integer(stats.total_boundaries)
    end
  end

  describe "limitations/1" do
    test "returns list of limitations" do
      assert {:ok, limitations} = CapabilityBoundary.limitations()

      assert is_list(limitations)
    end

    test "limitations respects limit option" do
      assert {:ok, limitations} = CapabilityBoundary.limitations(limit: 5)

      assert length(limitations) <= 5
    end
  end

  describe "stats/0" do
    test "returns statistics" do
      {:ok, stats} = CapabilityBoundary.stats()

      assert is_integer(stats.total_boundaries)
      assert is_integer(stats.total_checks)
      assert is_integer(stats.total_blocked)
      assert is_integer(stats.total_uncertain)
      assert is_float(stats.block_rate)
      assert is_map(stats.by_category)
      assert is_float(stats.uptime_hours)
    end

    test "updates check count after can_handle" do
      {:ok, initial} = CapabilityBoundary.stats()

      # Perform a check
      CapabilityBoundary.can_handle?(%{query: "test query #{System.unique_integer()}"})

      {:ok, after_check} = CapabilityBoundary.stats()

      assert after_check.total_checks == initial.total_checks + 1
    end
  end
end
