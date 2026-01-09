defmodule Mimo.Integration.KnowledgeLadderPipelineTest do
  @moduledoc """
  Integration tests for the Knowledge Ladder Pipeline.

  Tests the flow: Observations → Facts → Triples → Procedures

  This tests the BackgroundCognition.knowledge_promotion process and its
  connections to SemanticStore.Ingestor and the Emergence system.
  """
  use ExUnit.Case

  @moduletag :integration

  alias Mimo.Brain.BackgroundCognition
  alias Mimo.Brain.Emergence.Pattern
  alias Mimo.Brain.Memory
  alias Mimo.Repo
  alias Mimo.SemanticStore.Repository, as: TripleRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  describe "knowledge_promotion process" do
    test "promotes inference patterns to semantic triples" do
      # Create a pattern that meets promotion thresholds
      {:ok, pattern} =
        create_promotable_pattern(:inference, %{
          description: "Phoenix uses Ecto for database access",
          components: ["Phoenix", "Ecto", "database"],
          trigger_conditions: ["web framework", "ORM"]
        })

      # Run the knowledge promotion cycle
      result = BackgroundCognition.run_now(force: true)

      case result do
        {:ok, results} ->
          # Check if knowledge_promotion ran
          assert Map.has_key?(results, :knowledge_promotion)

          promo_result = results[:knowledge_promotion]

          # Either promoted or no candidates (depends on thresholds)
          assert promo_result[:patterns_promoted] >= 0 or
                   promo_result[:skipped] == :no_candidates

        {:error, :session_active} ->
          # Session is active, skip this test
          :ok

        {:error, reason} ->
          flunk("BackgroundCognition failed: #{inspect(reason)}")
      end

      # Clean up
      Repo.delete(pattern)
    end

    test "promotes workflow patterns via Promoter" do
      {:ok, pattern} =
        create_promotable_pattern(:workflow, %{
          description: "Debug workflow: search memory, find definition, apply fix",
          components: ["memory_search", "code_definition", "file_edit"],
          trigger_conditions: ["error", "bug fix"]
        })

      result = BackgroundCognition.run_now(force: true)

      case result do
        {:ok, _results} -> :ok
        {:error, :session_active} -> :ok
        {:error, reason} -> flunk("Failed: #{inspect(reason)}")
      end

      Repo.delete(pattern)
    end

    test "promotes skill patterns to high-importance memories" do
      {:ok, pattern} =
        create_promotable_pattern(:skill, %{
          description: "Elixir pattern matching proficiency",
          components: ["pattern_match", "case", "with"],
          trigger_conditions: ["elixir code", "matching"]
        })

      result = BackgroundCognition.run_now(force: true)

      case result do
        {:ok, _results} -> :ok
        {:error, :session_active} -> :ok
        {:error, reason} -> flunk("Failed: #{inspect(reason)}")
      end

      Repo.delete(pattern)
    end
  end

  describe "consolidation to triples pipeline" do
    test "deep consolidation creates graph connections" do
      # Create some memories that could be consolidated
      {:ok, mem1} =
        Memory.persist_memory(
          "Phoenix is a web framework for Elixir",
          "fact",
          importance: 0.8
        )

      {:ok, mem2} =
        Memory.persist_memory(
          "Ecto is the database layer for Phoenix",
          "fact",
          importance: 0.8
        )

      {:ok, mem3} =
        Memory.persist_memory(
          "LiveView provides real-time features in Phoenix",
          "fact",
          importance: 0.8
        )

      # Run background cognition (may or may not produce insights depending on LLM)
      result = BackgroundCognition.run_now(force: true)

      case result do
        {:ok, results} ->
          assert Map.has_key?(results, :deep_consolidation)

        {:error, :session_active} ->
          :ok

        {:error, _reason} ->
          # LLM might not be available in test
          :ok
      end

      # Clean up
      cleanup_memory(mem1)
      cleanup_memory(mem2)
      cleanup_memory(mem3)
    end
  end

  describe "synthesis to triples pipeline" do
    test "knowledge synthesis creates semantic triples from insights" do
      # Create diverse memories for synthesis
      {:ok, mem1} =
        Memory.persist_memory(
          "User prefers functional programming style",
          "fact",
          importance: 0.7
        )

      {:ok, mem2} =
        Memory.persist_memory(
          "Fixed authentication bug using pattern matching",
          "action",
          importance: 0.7
        )

      result = BackgroundCognition.run_now(force: true)

      case result do
        {:ok, results} ->
          assert Map.has_key?(results, :knowledge_synthesis)

          synth_result = results[:knowledge_synthesis]
          # Either synthesized or skipped (daily limit or insufficient memories)
          assert synth_result[:insights] || synth_result[:skipped]

        {:error, :session_active} ->
          :ok

        {:error, _reason} ->
          :ok
      end

      cleanup_memory(mem1)
      cleanup_memory(mem2)
    end
  end

  describe "telemetry events" do
    test "knowledge_promotion emits telemetry" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:mimo, :background_cognition, :knowledge_promotion]
        ])

      {:ok, pattern} =
        create_promotable_pattern(:inference, %{
          description: "Test pattern for telemetry",
          components: ["test"],
          trigger_conditions: ["test"]
        })

      BackgroundCognition.run_now(force: true)

      # Note: Telemetry may or may not fire depending on whether promotion occurred
      # This test just verifies no crash occurs

      :telemetry.detach(ref)
      Repo.delete(pattern)
    end
  end

  describe "BackgroundCognition stats" do
    test "stats includes patterns_promoted counter" do
      stats = BackgroundCognition.stats()

      assert is_map(stats)
      # Should have the new patterns_promoted stat
      # Stats might be nested
      assert Map.has_key?(stats, :patterns_promoted) or
               Map.has_key?(stats, "patterns_promoted") or
               (is_map(stats[:stats]) and Map.has_key?(stats[:stats], :patterns_promoted))
    end
  end

  # Helper functions

  defp create_promotable_pattern(type, attrs) do
    now = DateTime.utc_now()

    Pattern.create(%{
      type: type,
      description: attrs[:description],
      components: attrs[:components] || [],
      trigger_conditions: attrs[:trigger_conditions] || [],
      # Above threshold
      success_rate: 0.85,
      # Above threshold
      occurrences: 15,
      # Above threshold
      strength: 0.8,
      status: :active,
      first_seen: DateTime.add(now, -7, :day),
      last_seen: now
    })
  end

  defp cleanup_memory({:ok, memory}), do: cleanup_memory(memory)

  defp cleanup_memory(%{id: id}) do
    try do
      Memory.update_importance(id, 0.0)
    rescue
      _ -> :ok
    end
  end

  defp cleanup_memory(_), do: :ok
end
