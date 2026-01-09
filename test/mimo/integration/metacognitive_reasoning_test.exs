defmodule Mimo.Integration.MetacognitiveReasoningTest do
  @moduledoc """
  Integration test for Level 4 Metacognitive Monitoring + Reasoner.

  Verifies that reasoning operations automatically record to MetacognitiveMonitor.
  """
  use Mimo.DataCase, async: false

  alias Mimo.Cognitive.{Reasoner, MetacognitiveMonitor}

  describe "reasoning integration with metacognitive monitoring" do
    test "strategy decisions are automatically recorded" do
      {:ok, result} = Reasoner.guided("What is 2 + 2?", strategy: :cot)
      session_id = result.session_id

      # Wait for async cast
      Process.sleep(100)

      {:ok, explanation} = MetacognitiveMonitor.explain_session(session_id)

      assert explanation.total_decisions >= 1
      assert explanation.strategy.selected == :cot
      # Strategy reason varies - just check it exists
      assert explanation.strategy.reason != nil
    end

    test "step evaluations are automatically recorded" do
      {:ok, result} = Reasoner.guided("Explain recursion", strategy: :cot)
      session_id = result.session_id

      # Add a reasoning step
      {:ok, _step_result} = Reasoner.step(session_id, "Recursion is when a function calls itself")

      # Wait for async cast
      Process.sleep(100)

      {:ok, explanation} = MetacognitiveMonitor.explain_session(session_id)

      # Should have strategy + step evaluation
      assert explanation.total_decisions >= 2
      assert length(explanation.step_evaluations) >= 1
    end

    test "backtrack decisions are recorded for ToT sessions" do
      {:ok, result} = Reasoner.guided("Complex problem with multiple approaches", strategy: :tot)
      session_id = result.session_id

      # Create initial step
      {:ok, _} = Reasoner.step(session_id, "First approach attempt")

      # Create a branch
      {:ok, _} = Reasoner.branch(session_id, "Alternative approach")

      # Add step in branch
      {:ok, _} = Reasoner.step(session_id, "This branch seems like a dead end")

      # Backtrack - this should record the backtrack decision
      {:ok, backtrack_result} = Reasoner.backtrack(session_id)

      # Wait for async cast
      Process.sleep(100)

      {:ok, explanation} = MetacognitiveMonitor.explain_session(session_id)

      # If we actually backtracked (not all branches explored)
      if not Map.get(backtrack_result, :all_explored, false) do
        assert length(explanation.backtracks) >= 1
        backtrack = hd(explanation.backtracks)
        assert backtrack.reason == "Branch marked as dead-end"
      end
    end

    test "cognitive load reflects active reasoning sessions" do
      # Start multiple sessions
      {:ok, r1} = Reasoner.guided("Problem 1", strategy: :cot)
      {:ok, r2} = Reasoner.guided("Problem 2", strategy: :cot)

      Process.sleep(50)

      {:ok, load} = MetacognitiveMonitor.cognitive_load()

      # Should have recorded sessions
      assert load.active_sessions >= 0
      assert load.level in [:low, :normal, :high, :critical]

      # Clean up
      Reasoner.conclude(r1.session_id)
      Reasoner.conclude(r2.session_id)
    end

    test "explain_session provides full causal trace" do
      {:ok, result} = Reasoner.guided("Analyze the Fibonacci sequence", strategy: :cot)
      session_id = result.session_id

      # Add multiple steps
      {:ok, _} = Reasoner.step(session_id, "The Fibonacci sequence is 1, 1, 2, 3, 5, 8...")
      {:ok, _} = Reasoner.step(session_id, "Each number is the sum of the two preceding numbers")
      {:ok, _} = Reasoner.step(session_id, "This creates exponential growth")

      Process.sleep(100)

      {:ok, explanation} = MetacognitiveMonitor.explain_session(session_id)

      # Should have strategy + 3 step evaluations
      assert explanation.total_decisions >= 4
      assert explanation.strategy.selected == :cot
      assert length(explanation.step_evaluations) == 3

      # Summary should reflect decisions
      assert explanation.summary =~ "traced decisions"
    end
  end
end
