defmodule Mimo.Cognitive.UncertaintyTrackerTest do
  use ExUnit.Case, async: false
  alias Mimo.Cognitive.{Uncertainty, UncertaintyTracker}

  setup do
    # Start the tracker if not started
    case UncertaintyTracker.start_link([]) do
      {:ok, pid} ->
        on_exit(fn ->
          if Process.alive?(pid), do: GenServer.stop(pid)
        end)

        :ok

      {:error, {:already_started, _pid}} ->
        UncertaintyTracker.clear()
        :ok
    end
  end

  describe "record/3" do
    test "records uncertainty assessment" do
      uncertainty = %Uncertainty{
        topic: "test",
        confidence: :low,
        score: 0.3,
        evidence_count: 1,
        sources: [],
        staleness: 0.0,
        gap_indicators: []
      }

      assert :ok = UncertaintyTracker.record("test query", uncertainty)
    end

    test "records with outcome" do
      uncertainty = %Uncertainty{
        topic: "test",
        confidence: :medium,
        score: 0.5,
        evidence_count: 2,
        sources: [],
        staleness: 0.0,
        gap_indicators: []
      }

      assert :ok = UncertaintyTracker.record("test query", uncertainty, :answered)
    end
  end

  describe "stats/0" do
    test "returns statistics map" do
      stats = UncertaintyTracker.stats()

      assert is_map(stats)
      assert Map.has_key?(stats, :total_queries)
      assert Map.has_key?(stats, :confidence_distribution)
      assert Map.has_key?(stats, :gaps_detected)
      assert Map.has_key?(stats, :unique_topics)
    end

    test "tracks queries correctly" do
      UncertaintyTracker.clear()

      uncertainty = %Uncertainty{
        topic: "test",
        confidence: :high,
        score: 0.8,
        evidence_count: 5,
        sources: [],
        staleness: 0.0,
        gap_indicators: []
      }

      UncertaintyTracker.record("query 1", uncertainty)
      # Give GenServer time to process
      Process.sleep(50)

      stats = UncertaintyTracker.stats()
      assert stats.total_queries >= 1
    end
  end

  describe "confidence_distribution/0" do
    test "returns distribution map" do
      dist = UncertaintyTracker.confidence_distribution()

      assert is_map(dist)
      assert Map.has_key?(dist, :high)
      assert Map.has_key?(dist, :medium)
      assert Map.has_key?(dist, :low)
      assert Map.has_key?(dist, :unknown)
      assert Map.has_key?(dist, :total)
    end
  end

  describe "get_knowledge_gaps/1" do
    test "returns list of gaps" do
      gaps = UncertaintyTracker.get_knowledge_gaps()

      assert is_list(gaps)
    end

    test "respects limit option" do
      gaps = UncertaintyTracker.get_knowledge_gaps(limit: 5)

      assert length(gaps) <= 5
    end

    test "gap entries have required fields" do
      # Add some test data
      low_u = %Uncertainty{
        topic: "gap_test",
        confidence: :low,
        score: 0.2,
        evidence_count: 0,
        sources: [],
        staleness: 0.0,
        gap_indicators: ["test gap"]
      }

      UncertaintyTracker.record("gap test query", low_u)
      UncertaintyTracker.record("gap test query 2", low_u)
      Process.sleep(50)

      gaps = UncertaintyTracker.get_knowledge_gaps(min_occurrences: 1)

      Enum.each(gaps, fn gap ->
        assert Map.has_key?(gap, :topic)
        assert Map.has_key?(gap, :total_queries)
        assert Map.has_key?(gap, :low_confidence_count)
        assert Map.has_key?(gap, :low_confidence_rate)
      end)
    end
  end

  describe "suggest_learning_targets/1" do
    test "returns list of suggestions" do
      targets = UncertaintyTracker.suggest_learning_targets()

      assert is_list(targets)
    end

    test "respects limit option" do
      targets = UncertaintyTracker.suggest_learning_targets(limit: 3)

      assert length(targets) <= 3
    end

    test "suggestion entries have required fields" do
      # Add test data
      low_u = %Uncertainty{
        topic: "learning_test",
        confidence: :low,
        score: 0.2,
        evidence_count: 0,
        sources: [],
        staleness: 0.0,
        gap_indicators: []
      }

      UncertaintyTracker.record("learning test", low_u)
      UncertaintyTracker.record("learning test 2", low_u)
      Process.sleep(50)

      targets = UncertaintyTracker.suggest_learning_targets()

      Enum.each(targets, fn target ->
        assert Map.has_key?(target, :topic)
        assert Map.has_key?(target, :priority)
        assert Map.has_key?(target, :reason)
        assert Map.has_key?(target, :suggested_actions)
      end)
    end
  end

  describe "clear/0" do
    test "clears all tracking data" do
      uncertainty = %Uncertainty{
        topic: "clear_test",
        confidence: :medium,
        score: 0.5,
        evidence_count: 2,
        sources: [],
        staleness: 0.0,
        gap_indicators: []
      }

      UncertaintyTracker.record("clear test", uncertainty)
      Process.sleep(50)

      :ok = UncertaintyTracker.clear()

      stats = UncertaintyTracker.stats()
      assert stats.total_queries == 0
    end
  end
end
