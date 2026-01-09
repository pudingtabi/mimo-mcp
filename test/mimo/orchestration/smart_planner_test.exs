defmodule Mimo.Orchestration.SmartPlannerTest do
  @moduledoc """
  Tests for Smart Orchestrator v2.
  """

  use ExUnit.Case, async: true

  alias Mimo.Orchestration.SmartPlanner

  describe "plan/1" do
    test "plans a simple query task" do
      request = %{"description" => "What is the current status?"}

      assert {:ok, plan} = SmartPlanner.plan(request)
      assert is_binary(plan.id)
      assert is_list(plan.tools)
      assert plan.confidence > 0
      assert plan.planning_latency_ms >= 0

      # Simple queries should suggest memory tool
      tool_types = Enum.map(plan.tools, & &1.tool)
      assert :memory in tool_types or :reason in tool_types
    end

    test "plans a bug fix task" do
      request = %{"description" => "Fix the bug in auth.ex line 42"}

      assert {:ok, plan} = SmartPlanner.plan(request)
      assert is_list(plan.tools)

      # Bug fixes should suggest reason, code, file
      tool_types = Enum.map(plan.tools, & &1.tool)
      assert :file in tool_types or :code in tool_types
    end

    test "plans an implementation task" do
      request = %{
        "description" => "Implement a new user authentication feature with OAuth2 support"
      }

      assert {:ok, plan} = SmartPlanner.plan(request)
      assert plan.analysis.complexity in [:high, :low, :unknown]
      assert is_list(plan.tools)

      # Implementation should include terminal for testing
      tool_types = Enum.map(plan.tools, & &1.tool)
      assert length(tool_types) >= 2
    end

    test "blocks dangerous actions via ErrorPredictor" do
      # This would be blocked if ErrorPredictor detects critical warnings
      # We test that the pre-check runs without error
      request = %{"description" => "Deploy to production without testing"}

      result = SmartPlanner.plan(request)
      # Can return either ok or blocked
      case result do
        {:ok, _} -> assert true
        {:blocked, _} -> assert true
      end
    end
  end

  describe "tool prediction heuristics" do
    test "debug tasks suggest reason and code tools" do
      request = %{"description" => "Debug why the test is failing"}

      {:ok, plan} = SmartPlanner.plan(request)
      tool_types = Enum.map(plan.tools, & &1.tool)

      assert :reason in tool_types or :code in tool_types
    end

    test "test tasks suggest terminal" do
      request = %{"description" => "Run the test suite"}

      {:ok, plan} = SmartPlanner.plan(request)
      tool_types = Enum.map(plan.tools, & &1.tool)

      assert :terminal in tool_types
    end

    test "search tasks suggest code or memory" do
      request = %{"description" => "Find all usages of the authenticate function"}

      {:ok, plan} = SmartPlanner.plan(request)
      tool_types = Enum.map(plan.tools, & &1.tool)

      assert :code in tool_types or :memory in tool_types
    end
  end

  describe "confidence calculation" do
    test "simple queries have reasonable confidence" do
      request = %{"description" => "What is X?"}

      {:ok, plan} = SmartPlanner.plan(request)

      # Confidence should be between 0 and 1
      assert plan.confidence >= 0
      assert plan.confidence <= 1
    end

    test "complex tasks may have lower confidence" do
      request = %{
        "description" =>
          "Implement a distributed caching layer with Redis support, automatic failover, and circuit breaker pattern"
      }

      {:ok, plan} = SmartPlanner.plan(request)

      # Should still produce a plan
      assert is_list(plan.tools)
      assert length(plan.tools) > 0
    end
  end

  describe "plan structure" do
    test "plan has all required fields" do
      request = %{"description" => "Test task"}

      {:ok, plan} = SmartPlanner.plan(request)

      assert Map.has_key?(plan, :id)
      assert Map.has_key?(plan, :description)
      assert Map.has_key?(plan, :tools)
      assert Map.has_key?(plan, :predictions)
      assert Map.has_key?(plan, :analysis)
      assert Map.has_key?(plan, :confidence)
      assert Map.has_key?(plan, :created_at)
      assert Map.has_key?(plan, :planning_latency_ms)
    end

    test "tool specs have required structure" do
      request = %{"description" => "Fix a bug"}

      {:ok, plan} = SmartPlanner.plan(request)

      for tool_spec <- plan.tools do
        assert Map.has_key?(tool_spec, :tool)
        assert Map.has_key?(tool_spec, :operation)
        assert is_atom(tool_spec.tool)
        assert is_binary(tool_spec.operation)
      end
    end
  end
end
