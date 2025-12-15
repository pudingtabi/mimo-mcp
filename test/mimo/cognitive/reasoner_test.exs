defmodule Mimo.Cognitive.ReasonerTest do
  @moduledoc """
  Tests for the Unified Reasoning Engine.

  Note: These tests require a database for the full DataCase support.
  For quick validation, run individual assertions in IEx:

      iex> Mimo.Cognitive.Reasoner.guided("What is 2 + 2?")
      iex> Mimo.Cognitive.ReasoningSession.stats()
  """

  use ExUnit.Case, async: true

  alias Mimo.Cognitive.{Reasoner, ReasoningSession}

  # Initialize ETS table before tests
  # The GenServer may not be started in test env, so we create the table directly
  setup_all do
    # Ensure the ETS table exists (create if not exists)
    unless :ets.whereis(:reasoning_sessions) != :undefined do
      :ets.new(:reasoning_sessions, [:named_table, :set, :public, read_concurrency: true])
    end

    :ok
  end

  describe "guided/2" do
    test "creates session with auto strategy selection" do
      {:ok, result} = Reasoner.guided("How do I calculate the factorial of 5?")

      assert result.session_id != nil
      assert String.starts_with?(result.session_id, "reason_")
      assert result.strategy in [:cot, :tot, :react, :reflexion]
      assert is_binary(result.strategy_reason)
      assert is_map(result.problem_analysis)
      assert is_map(result.confidence)
      assert is_binary(result.guidance)
    end

    test "accepts explicit strategy selection" do
      {:ok, result} = Reasoner.guided("Fix the authentication bug", strategy: :react)

      assert result.strategy == :react
    end

    test "returns error for empty problem" do
      assert {:error, _} = Reasoner.guided("")
      assert {:error, _} = Reasoner.guided(nil)
    end

    test "provides decomposition for complex problems" do
      {:ok, result} = Reasoner.guided("Build a REST API with authentication and rate limiting")

      assert is_list(result.decomposition)
    end
  end

  describe "decompose/2" do
    test "breaks problem into sub-problems" do
      {:ok, result} = Reasoner.decompose("Implement user authentication with OAuth2")

      assert result.original =~ "authentication"
      assert is_list(result.sub_problems)
      assert is_atom(result.complexity)
    end

    test "generates approaches for ToT strategy" do
      {:ok, result} = Reasoner.decompose("Design a caching strategy", strategy: :tot)

      assert result.strategy == :tot
      assert is_list(result.approaches)
    end
  end

  describe "step/3" do
    setup do
      {:ok, guided_result} = Reasoner.guided("What is 2 + 2?", strategy: :cot)
      {:ok, session_id: guided_result.session_id}
    end

    test "records reasoning step with evaluation", %{session_id: session_id} do
      {:ok, result} =
        Reasoner.step(
          session_id,
          "First, I need to understand that 2 + 2 means adding two numbers together."
        )

      assert result.session_id == session_id
      assert result.step_number == 1
      assert is_map(result.evaluation)
      assert result.evaluation.quality in [:good, :maybe, :bad]
      assert is_map(result.confidence)
    end

    test "calculates progress", %{session_id: session_id} do
      {:ok, step1} = Reasoner.step(session_id, "Step 1: Understand the problem")
      {:ok, step2} = Reasoner.step(session_id, "Step 2: The answer is 4")

      assert step2.progress >= step1.progress
    end

    test "returns error for missing session_id" do
      assert {:error, :not_found} = Reasoner.step("nonexistent_session", "thought")
    end
  end

  describe "verify/2" do
    test "verifies reasoning chain from list of thoughts" do
      thoughts = [
        "First, let's understand the problem: we need to add 2 + 2",
        "Addition means combining quantities",
        "Therefore, 2 + 2 = 4"
      ]

      {:ok, result} = Reasoner.verify(thoughts)

      assert is_boolean(result.valid)
      assert is_list(result.issues)
      assert result.hallucination_risk in [:low, :medium, :high]
      assert result.completeness in [:complete, :possibly_incomplete, :incomplete]
    end

    test "verifies reasoning from session" do
      {:ok, guided} = Reasoner.guided("Simple math problem")
      {:ok, _} = Reasoner.step(guided.session_id, "Let me think about this carefully")
      {:ok, _} = Reasoner.step(guided.session_id, "The solution involves basic arithmetic")

      {:ok, result} = Reasoner.verify(guided.session_id)

      assert is_boolean(result.valid)
      assert is_list(result.suggestions)
    end
  end

  describe "reflect/3" do
    setup do
      {:ok, guided} = Reasoner.guided("Debug the failing test", strategy: :reflexion)
      {:ok, _} = Reasoner.step(guided.session_id, "I'll check the test assertions first")
      {:ok, _} = Reasoner.step(guided.session_id, "Found the issue: wrong expected value")
      {:ok, session_id: guided.session_id}
    end

    test "reflects on successful outcome", %{session_id: session_id} do
      {:ok, result} =
        Reasoner.reflect(session_id, %{
          success: true,
          result: "Test now passes"
        })

      assert result.session_id == session_id
      assert result.success == true
      assert is_list(result.lessons_learned)
      assert is_binary(result.verbal_feedback)
    end

    test "reflects on failed outcome", %{session_id: session_id} do
      {:ok, result} =
        Reasoner.reflect(session_id, %{
          success: false,
          error: "Still failing with timeout"
        })

      assert result.success == false
      assert is_map(result.critique)
      assert is_list(result.critique.what_went_wrong)
    end
  end

  describe "branch/3 (ToT)" do
    setup do
      {:ok, guided} = Reasoner.guided("Design a scalable system", strategy: :tot)
      {:ok, session_id: guided.session_id}
    end

    test "creates new branch", %{session_id: session_id} do
      {:ok, result} = Reasoner.branch(session_id, "Approach A: Use microservices")

      assert result.session_id == session_id
      assert is_binary(result.branch_id)
      # root + new branch
      assert result.total_branches >= 2
    end

    test "rejects branch for non-ToT strategy" do
      {:ok, cot_session} = Reasoner.guided("Simple problem", strategy: :cot)

      assert {:error, message} = Reasoner.branch(cot_session.session_id, "A thought")
      assert message =~ "Tree-of-Thoughts"
    end
  end

  describe "backtrack/2 (ToT)" do
    setup do
      {:ok, guided} = Reasoner.guided("Explore options", strategy: :tot)
      {:ok, branch1} = Reasoner.branch(guided.session_id, "Try option A")
      {:ok, _} = Reasoner.step(guided.session_id, "Option A seems promising")
      {:ok, branch2} = Reasoner.branch(guided.session_id, "Try option B")

      {:ok,
       session_id: guided.session_id, branch1_id: branch1.branch_id, branch2_id: branch2.branch_id}
    end

    test "backtracks to previous branch", %{session_id: session_id} do
      {:ok, result} = Reasoner.backtrack(session_id)

      # Should either find an unexplored branch or report all explored
      assert result.session_id == session_id
      assert Map.has_key?(result, :now_on_branch) or Map.has_key?(result, :no_more_branches)
    end

    test "backtracks to specific branch", %{session_id: session_id, branch1_id: branch1_id} do
      {:ok, result} = Reasoner.backtrack(session_id, to_branch: branch1_id)

      if Map.has_key?(result, :now_on_branch) do
        assert result.now_on_branch == branch1_id
      end
    end
  end

  describe "conclude/2" do
    setup do
      {:ok, guided} = Reasoner.guided("What is the capital of France?")
      {:ok, _} = Reasoner.step(guided.session_id, "France is a country in Western Europe")
      {:ok, _} = Reasoner.step(guided.session_id, "The capital of France is Paris")
      {:ok, _} = Reasoner.step(guided.session_id, "Therefore, the answer is Paris")
      {:ok, session_id: guided.session_id}
    end

    test "concludes reasoning with synthesis", %{session_id: session_id} do
      {:ok, result} = Reasoner.conclude(session_id)

      assert result.session_id == session_id
      assert is_binary(result.conclusion)
      assert is_map(result.confidence)
      assert result.confidence.level in [:high, :medium, :low]
      assert is_binary(result.reasoning_summary)
      assert result.total_steps == 3
    end

    test "marks session as completed", %{session_id: session_id} do
      {:ok, _} = Reasoner.conclude(session_id)
      {:ok, session} = ReasoningSession.get(session_id)

      assert session.status == :completed
    end

    test "returns error for empty reasoning" do
      {:ok, guided} = Reasoner.guided("New problem")

      assert {:error, _} = Reasoner.conclude(guided.session_id)
    end
  end

  describe "integration - full reasoning workflow" do
    test "complete CoT workflow" do
      # Start
      {:ok, start} = Reasoner.guided("Calculate 15% tip on $80", strategy: :cot)
      assert start.strategy == :cot

      # Step through
      {:ok, s1} =
        Reasoner.step(start.session_id, "To calculate 15% of $80, I need to multiply 80 by 0.15")

      assert s1.should_continue

      {:ok, s2} = Reasoner.step(start.session_id, "80 * 0.15 = 12")
      assert s2.step_number == 2

      {:ok, _s3} = Reasoner.step(start.session_id, "Therefore, a 15% tip on $80 is $12")

      # Verify
      {:ok, verify} = Reasoner.verify(start.session_id)
      assert is_boolean(verify.valid)

      # Conclude
      {:ok, conclusion} = Reasoner.conclude(start.session_id)
      assert conclusion.total_steps == 3
    end

    test "complete ToT workflow with branching" do
      # Start
      {:ok, start} = Reasoner.guided("Find the best sorting algorithm", strategy: :tot)
      assert start.strategy == :tot

      # Create branches
      {:ok, b1} = Reasoner.branch(start.session_id, "Consider QuickSort: O(n log n) average")
      {:ok, _} = Reasoner.step(start.session_id, "QuickSort uses divide and conquer")

      {:ok, _b2} = Reasoner.branch(start.session_id, "Consider MergeSort: O(n log n) guaranteed")

      {:ok, _} =
        Reasoner.step(start.session_id, "MergeSort has stable O(n log n) but uses more memory")

      # Backtrack if needed
      {:ok, _} = Reasoner.backtrack(start.session_id, to_branch: b1.branch_id)

      # Conclude
      {:ok, conclusion} = Reasoner.conclude(start.session_id)
      assert conclusion.total_steps >= 2
    end
  end
end
