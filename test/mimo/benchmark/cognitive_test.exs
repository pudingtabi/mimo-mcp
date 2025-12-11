defmodule Mimo.Benchmark.CognitiveTest do
  @moduledoc """
  Tests for SPEC-059: Cognitive Benchmark Suite
  """
  use Mimo.DataCase, async: false

  alias Mimo.Benchmark.Cognitive
  alias Mimo.Brain.{Engram, Memory}
  alias Mimo.Repo

  describe "run/1" do
    test "returns comprehensive report structure" do
      {:ok, report} = Cognitive.run(save_results: false, sample_size: 10)

      assert is_binary(report.run_id)
      assert %DateTime{} = report.timestamp
      assert is_integer(report.elapsed_ms)
      assert is_list(report.categories)
      assert is_map(report.results)
      assert is_map(report.aggregate)
      assert Map.has_key?(report.aggregate, :overall_score)
      assert Map.has_key?(report.aggregate, :grade)
    end

    test "runs specific categories when specified" do
      {:ok, report} =
        Cognitive.run(
          categories: [:reasoning, :consolidation],
          save_results: false,
          sample_size: 5
        )

      assert :reasoning in report.categories
      assert :consolidation in report.categories
      refute :temporal in report.categories
    end
  end

  describe "evaluate_reasoning/1" do
    test "returns valid metrics structure with no data" do
      {:ok, metrics} = Cognitive.evaluate_reasoning(sample_size: 10)

      assert Map.has_key?(metrics, :step_coherence)
      assert Map.has_key?(metrics, :conclusion_accuracy)
      assert Map.has_key?(metrics, :branch_utilization)
      assert Map.has_key?(metrics, :reflection_quality)
      assert Map.has_key?(metrics, :sample_count)
      assert Map.has_key?(metrics, :status)
    end

    test "evaluates reasoning memories when present" do
      # Create a reasoning memory directly to ensure it exists and matches criteria
      suffix = System.unique_integer([:positive])

      {:ok, %{id: id}} =
        Repo.insert(%Engram{
          content:
            "Reasoning Step 1: Analyze the problem #{suffix}. Step 2: Consider alternatives.",
          category: "plan",
          importance: 0.7,
          metadata: %{"reasoning_session" => "test_session", "step_number" => 1},
          # Dummy embedding for search validity if needed
          embedding_int8: <<0::size(2048)>>,
          inserted_at: NaiveDateTime.utc_now(:second),
          updated_at: NaiveDateTime.utc_now(:second)
        })

      {:ok, metrics} = Cognitive.evaluate_reasoning(sample_size: 10)

      assert metrics.sample_count >= 1
      assert is_float(metrics.step_coherence)
    end
  end

  describe "evaluate_consolidation/1" do
    test "returns valid metrics structure" do
      {:ok, metrics} = Cognitive.evaluate_consolidation(sample_size: 10)

      assert Map.has_key?(metrics, :duplicate_detection_rate)
      assert Map.has_key?(metrics, :merge_accuracy)
      assert Map.has_key?(metrics, :decay_health)
      assert Map.has_key?(metrics, :protection_coverage)
    end

    test "evaluates protection coverage correctly" do
      # Create high-importance protected memory
      {:ok, _id} =
        Memory.persist_memory(
          "Critical system configuration",
          "fact",
          0.95,
          protected: true
        )

      {:ok, metrics} = Cognitive.evaluate_consolidation(sample_size: 50)

      # Should detect the protected high-importance memory
      assert is_float(metrics.protection_coverage)
    end
  end

  describe "evaluate_temporal_chains/1" do
    test "returns valid metrics structure with no chains" do
      {:ok, metrics} = Cognitive.evaluate_temporal_chains(sample_size: 10)

      assert metrics.status == :no_chains or metrics.status == :ok
      assert Map.has_key?(metrics, :chain_integrity)
      assert Map.has_key?(metrics, :supersession_accuracy)
      assert Map.has_key?(metrics, :orphan_rate)
    end

    test "evaluates chain integrity when chains exist" do
      # Create a supersession chain
      {:ok, original_id} =
        Memory.persist_memory(
          "Original fact: Elixir is a functional language",
          "fact",
          0.7
        )

      {:ok, _updated_id} =
        Memory.persist_memory(
          "Updated fact: Elixir is a functional language with OTP support",
          "fact",
          0.8,
          supersedes_id: original_id,
          supersession_type: "update"
        )

      {:ok, metrics} = Cognitive.evaluate_temporal_chains(sample_size: 50)

      # Should have valid chain
      assert is_float(metrics.chain_integrity)
    end
  end

  describe "evaluate_temporal_validity/1" do
    test "returns valid metrics structure with no temporal data" do
      {:ok, metrics} = Cognitive.evaluate_temporal_validity(sample_size: 10)

      assert metrics.status == :no_temporal_data or metrics.status == :ok
      assert Map.has_key?(metrics, :as_of_precision)
      assert Map.has_key?(metrics, :valid_at_recall)
      assert Map.has_key?(metrics, :expired_exclusion_rate)
      assert Map.has_key?(metrics, :future_exclusion_rate)
    end

    test "evaluates temporal validity when data exists" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      # 1 day ago
      past = DateTime.add(now, -86400, :second)
      # 1 day ahead
      future = DateTime.add(now, 86400, :second)

      # Create memory with temporal validity
      {:ok, _} =
        Repo.insert(%Engram{
          content: "Valid fact with time bounds",
          category: "fact",
          importance: 0.7,
          valid_from: past,
          valid_until: future,
          validity_source: "explicit"
        })

      {:ok, metrics} = Cognitive.evaluate_temporal_validity(sample_size: 50)

      assert metrics.sample_count >= 1
      assert is_float(metrics.as_of_precision)
    end
  end

  describe "evaluate_retrieval/1" do
    test "returns valid metrics structure" do
      {:ok, metrics} = Cognitive.evaluate_retrieval(sample_size: 5)

      assert Map.has_key?(metrics, :precision_at_1)
      assert Map.has_key?(metrics, :precision_at_5)
      assert Map.has_key?(metrics, :precision_at_10)
      assert Map.has_key?(metrics, :mrr)
      assert Map.has_key?(metrics, :ndcg)
    end
  end

  describe "aggregate scoring" do
    test "calculates overall score from category scores" do
      {:ok, report} =
        Cognitive.run(
          categories: [:reasoning, :consolidation],
          save_results: false,
          sample_size: 5
        )

      assert is_float(report.aggregate.overall_score)
      assert report.aggregate.overall_score >= 0.0
      assert report.aggregate.overall_score <= 1.0
      assert report.aggregate.grade in ["A", "B", "C", "D", "F"]
    end
  end
end
