defmodule Mimo.Cognitive.MetacognitiveMonitorTest do
  @moduledoc """
  Tests for Level 4 Self-Understanding: Metacognitive Monitoring.
  """
  use Mimo.DataCase, async: false

  alias Mimo.Cognitive.MetacognitiveMonitor

  describe "record_strategy_decision/3" do
    test "records a strategy decision" do
      session_id = "test_session_#{:rand.uniform(10000)}"

      :ok =
        MetacognitiveMonitor.record_strategy_decision(session_id, :cot, %{
          problem_complexity: :simple,
          involves_tools: false,
          reason: "Chain of Thought for simple linear problem"
        })

      # Wait for async cast
      Process.sleep(50)

      {:ok, explanation} = MetacognitiveMonitor.explain_session(session_id)
      assert explanation.total_decisions >= 1
      assert explanation.strategy.selected == :cot
      assert explanation.strategy.reason =~ "Chain of Thought"
    end
  end

  describe "record_step_evaluation/3" do
    test "records step evaluations" do
      session_id = "test_session_#{:rand.uniform(10000)}"

      # First record a strategy decision
      :ok = MetacognitiveMonitor.record_strategy_decision(session_id, :tot, %{reason: "Complex"})

      # Record step evaluations
      :ok =
        MetacognitiveMonitor.record_step_evaluation(session_id, "step_1", %{
          evaluation: :good,
          confidence: 0.8,
          feedback: "Clear reasoning step"
        })

      :ok =
        MetacognitiveMonitor.record_step_evaluation(session_id, "step_2", %{
          evaluation: :maybe,
          confidence: 0.5,
          feedback: "Uncertain approach"
        })

      Process.sleep(50)

      {:ok, explanation} = MetacognitiveMonitor.explain_session(session_id)
      assert length(explanation.step_evaluations) == 2
    end
  end

  describe "record_branch_choice/3" do
    test "records branch creation decisions" do
      session_id = "test_session_#{:rand.uniform(10000)}"

      :ok = MetacognitiveMonitor.record_strategy_decision(session_id, :tot, %{reason: "Complex"})

      :ok =
        MetacognitiveMonitor.record_branch_choice(session_id, "branch_1", %{
          depth: 1,
          total_branches: 2,
          evaluation: :uncertain,
          reason: "Exploring alternative approach"
        })

      Process.sleep(50)

      {:ok, explanation} = MetacognitiveMonitor.explain_session(session_id)
      assert length(explanation.branch_choices) == 1
      assert hd(explanation.branch_choices).branch_id == "branch_1"
      assert hd(explanation.branch_choices).reason == "Exploring alternative approach"
    end
  end

  describe "record_backtrack/3" do
    test "records backtrack decisions" do
      session_id = "test_session_#{:rand.uniform(10000)}"

      :ok = MetacognitiveMonitor.record_strategy_decision(session_id, :tot, %{reason: "Exploring"})

      :ok =
        MetacognitiveMonitor.record_backtrack(session_id, "branch_1", %{
          confidence: 0.2,
          reason: "Branch led to dead end"
        })

      Process.sleep(50)

      {:ok, explanation} = MetacognitiveMonitor.explain_session(session_id)
      assert length(explanation.backtracks) == 1
      assert hd(explanation.backtracks).reason == "Branch led to dead end"
    end
  end

  describe "explain_session/1" do
    test "returns not_found for unknown session" do
      assert {:error, :not_found} = MetacognitiveMonitor.explain_session("nonexistent")
    end

    test "explains session with all decision types" do
      session_id = "test_session_#{:rand.uniform(10000)}"

      :ok =
        MetacognitiveMonitor.record_strategy_decision(session_id, :tot, %{
          problem_complexity: :complex,
          reason: "ToT for complex problem"
        })

      :ok =
        MetacognitiveMonitor.record_step_evaluation(session_id, "step_1", %{
          evaluation: :good,
          confidence: 0.9
        })

      :ok =
        MetacognitiveMonitor.record_branch_choice(session_id, "branch_2", %{
          depth: 1,
          total_branches: 2,
          reason: "Alternative approach"
        })

      :ok =
        MetacognitiveMonitor.record_backtrack(session_id, "branch_1", %{
          reason: "Dead end"
        })

      Process.sleep(50)

      {:ok, explanation} = MetacognitiveMonitor.explain_session(session_id)

      assert explanation.session_id == session_id
      assert explanation.total_decisions == 4
      assert explanation.strategy.selected == :tot
      assert length(explanation.step_evaluations) == 1
      assert length(explanation.branch_choices) == 1
      assert length(explanation.backtracks) == 1
      assert explanation.summary =~ "4 traced decisions"
    end
  end

  describe "cognitive_load/0" do
    test "returns cognitive load status" do
      {:ok, load} = MetacognitiveMonitor.cognitive_load()

      assert load.level in [:low, :normal, :high, :critical]
      assert is_integer(load.active_sessions)
      assert is_float(load.error_rate)
      assert is_list(load.indicators)
    end
  end

  describe "get_trace/1" do
    test "returns raw decision trace" do
      session_id = "test_session_#{:rand.uniform(10000)}"

      :ok =
        MetacognitiveMonitor.record_strategy_decision(session_id, :react, %{
          reason: "Tool use detected"
        })

      Process.sleep(50)

      {:ok, trace} = MetacognitiveMonitor.get_trace(session_id)
      assert length(trace) >= 1
      assert hd(trace).decision_type == :strategy_selection
    end

    test "returns not_found for unknown session" do
      assert {:error, :not_found} = MetacognitiveMonitor.get_trace("nonexistent")
    end
  end

  describe "stats/0" do
    test "returns statistics" do
      {:ok, stats} = MetacognitiveMonitor.stats()

      assert is_integer(stats.total_decisions)
      assert is_integer(stats.total_traces)
      assert is_integer(stats.tracked_sessions)
    end
  end
end
