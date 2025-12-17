defmodule Mimo.ToolRegistryTest do
  @moduledoc """
  Tests for ToolRegistry - Thread-safe tool registry with distributed process coordination.
  Tests tool registration/unregistration, :DOWN cleanup mechanism,
  concurrent registration, and registry persistence across crashes.
  """
  use ExUnit.Case, async: false

  alias Mimo.ToolRegistry

  @moduletag :tool_registry

  setup do
    # Ensure registry is in clean state for each test
    on_exit(fn ->
      try do
        ToolRegistry.clear_all()
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  # ==========================================================================
  # Tool Registration Tests
  # ==========================================================================

  describe "register_skill_tools/3" do
    test "registers tools with prefixed names" do
      tools = [
        %{"name" => "search", "description" => "Search tool"},
        %{"name" => "query", "description" => "Query tool"}
      ]

      # Start a mock process to act as skill owner
      {:ok, pid} = Agent.start_link(fn -> :running end)

      {:ok, registered} = ToolRegistry.register_skill_tools("test_skill", tools, pid)

      assert "test_skill_search" in registered
      assert "test_skill_query" in registered
      assert length(registered) == 2

      Agent.stop(pid)
    end

    test "re-registration cleans up previous tools" do
      {:ok, pid1} = Agent.start_link(fn -> :running end)

      tools1 = [%{"name" => "tool1", "description" => "First"}]
      {:ok, _} = ToolRegistry.register_skill_tools("my_skill", tools1, pid1)

      # Re-register with different tools
      {:ok, pid2} = Agent.start_link(fn -> :running end)
      tools2 = [%{"name" => "tool2", "description" => "Second"}]
      {:ok, registered} = ToolRegistry.register_skill_tools("my_skill", tools2, pid2)

      assert "my_skill_tool2" in registered
      refute "my_skill_tool1" in registered

      Agent.stop(pid1)
      Agent.stop(pid2)
    end

    test "handles empty tool list" do
      {:ok, pid} = Agent.start_link(fn -> :running end)
      {:ok, registered} = ToolRegistry.register_skill_tools("empty_skill", [], pid)

      assert registered == []

      Agent.stop(pid)
    end
  end

  # ==========================================================================
  # Tool Lookup Tests
  # ==========================================================================

  describe "get_tool_owner/1" do
    test "returns internal tool marker for internal tools" do
      assert {:ok, {:internal, _}} = ToolRegistry.get_tool_owner("ask_mimo")
      assert {:ok, {:internal, _}} = ToolRegistry.get_tool_owner("memory")
      assert {:ok, {:internal, _}} = ToolRegistry.get_tool_owner("run_procedure")
    end

    test "returns internal tool marker for deprecated tools (backward compatibility)" do
      # Deprecated tools still route internally but aren't in @internal_tool_names
      assert {:ok, {:internal, _}} = ToolRegistry.get_tool_owner("search_vibes")
      assert {:ok, {:internal, _}} = ToolRegistry.get_tool_owner("store_fact")
    end

    test "returns not_found for unregistered external tools" do
      result = ToolRegistry.get_tool_owner("nonexistent_tool_xyz")
      # Could be :not_found or error depending on catalog state
      assert match?({:error, _}, result)
    end

    test "returns skill info for registered tools" do
      {:ok, pid} = Agent.start_link(fn -> :running end)
      tools = [%{"name" => "my_tool", "description" => "Test"}]
      {:ok, _} = ToolRegistry.register_skill_tools("lookup_test", tools, pid)

      {:ok, result} = ToolRegistry.get_tool_owner("lookup_test_my_tool")
      assert match?({:skill, "lookup_test", ^pid, _}, result)

      Agent.stop(pid)
    end
  end

  # ==========================================================================
  # Internal Tool Tests
  # ==========================================================================

  describe "internal_tool?/1" do
    test "returns true for internal tools" do
      assert ToolRegistry.internal_tool?("ask_mimo")
      assert ToolRegistry.internal_tool?("memory")
      assert ToolRegistry.internal_tool?("run_procedure")
      assert ToolRegistry.internal_tool?("list_procedures")
      assert ToolRegistry.internal_tool?("mimo_reload_skills")
      assert ToolRegistry.internal_tool?("ingest")
    end

    test "returns false for deprecated tools (not advertised as internal)" do
      # Deprecated tools work but aren't in @internal_tool_names
      refute ToolRegistry.internal_tool?("search_vibes")
      refute ToolRegistry.internal_tool?("store_fact")
    end

    test "returns false for external tools" do
      refute ToolRegistry.internal_tool?("external_tool")
      refute ToolRegistry.internal_tool?("exa_search")
    end
  end

  describe "internal_tool_names/0" do
    test "returns list of internal tool names" do
      names = ToolRegistry.internal_tool_names()

      assert is_list(names)
      assert "ask_mimo" in names
      assert "memory" in names
      assert "run_procedure" in names
      assert "list_procedures" in names
      assert "ingest" in names
      assert "mimo_reload_skills" in names
    end

    test "does not include deprecated tools" do
      names = ToolRegistry.internal_tool_names()

      refute "search_vibes" in names
      refute "store_fact" in names
      refute "procedure_status" in names
    end
  end

  # ==========================================================================
  # :DOWN Cleanup Tests
  # ==========================================================================

  describe "automatic cleanup on process death" do
    test "tools are unregistered when owner process dies" do
      {:ok, pid} = Agent.start_link(fn -> :running end)
      tools = [%{"name" => "ephemeral", "description" => "Will be cleaned"}]
      {:ok, _} = ToolRegistry.register_skill_tools("dying_skill", tools, pid)

      # Verify registration
      {:ok, _} = ToolRegistry.get_tool_owner("dying_skill_ephemeral")

      # Kill the process
      Agent.stop(pid)

      # Wait for :DOWN message to be processed
      Process.sleep(100)

      # Tool should be cleaned up
      result = ToolRegistry.get_tool_owner("dying_skill_ephemeral")
      assert match?({:error, _}, result)
    end

    test "monitor cleanup handles crash scenarios" do
      # Spawn a process that will crash
      pid =
        spawn(fn ->
          receive do
            :crash -> raise "intentional crash"
          end
        end)

      tools = [%{"name" => "crash_tool", "description" => "Owner will crash"}]
      {:ok, _} = ToolRegistry.register_skill_tools("crash_skill", tools, pid)

      # Crash the process
      send(pid, :crash)
      Process.sleep(200)

      # Tool should be cleaned up after crash
      result = ToolRegistry.get_tool_owner("crash_skill_crash_tool")
      assert match?({:error, _}, result)
    end
  end

  # ==========================================================================
  # Concurrent Registration Tests
  # ==========================================================================

  describe "concurrent operations" do
    test "handles concurrent registrations safely" do
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            {:ok, pid} = Agent.start_link(fn -> :running end)
            tools = [%{"name" => "tool_#{i}", "description" => "Concurrent tool"}]
            result = ToolRegistry.register_skill_tools("concurrent_#{i}", tools, pid)
            {result, pid}
          end)
        end

      results = Task.await_many(tasks, 5000)

      for {{:ok, registered}, pid} <- results do
        assert length(registered) == 1
        Agent.stop(pid)
      end
    end

    test "concurrent lookups don't block" do
      {:ok, pid} = Agent.start_link(fn -> :running end)
      tools = [%{"name" => "concurrent_lookup", "description" => "Test"}]
      {:ok, _} = ToolRegistry.register_skill_tools("lookup_skill", tools, pid)

      tasks =
        for _ <- 1..20 do
          Task.async(fn ->
            ToolRegistry.get_tool_owner("lookup_skill_concurrent_lookup")
          end)
        end

      results = Task.await_many(tasks, 5000)

      for result <- results do
        assert match?({:ok, {:skill, _, _, _}}, result)
      end

      Agent.stop(pid)
    end
  end

  # ==========================================================================
  # List Operations Tests
  # ==========================================================================

  describe "list_all_tools/0" do
    test "includes internal tools" do
      tools = ToolRegistry.list_all_tools()

      tool_names = Enum.map(tools, & &1["name"])
      assert "ask_mimo" in tool_names
    end

    test "includes registered skill tools" do
      {:ok, pid} = Agent.start_link(fn -> :running end)
      tools = [%{"name" => "listed_tool", "description" => "Should be listed"}]
      {:ok, _} = ToolRegistry.register_skill_tools("list_skill", tools, pid)

      all_tools = ToolRegistry.list_all_tools()
      tool_names = Enum.map(all_tools, & &1["name"])

      # Either the prefixed name or original should appear
      assert "list_skill_listed_tool" in tool_names or "listed_tool" in tool_names

      Agent.stop(pid)
    end
  end

  # ==========================================================================
  # Stats Tests
  # ==========================================================================

  describe "stats/0" do
    test "returns registry statistics" do
      stats = ToolRegistry.stats()

      assert is_map(stats)
      assert Map.has_key?(stats, :total_tools)
      assert Map.has_key?(stats, :total_skills)
      assert Map.has_key?(stats, :skills)
      assert Map.has_key?(stats, :draining)
    end

    test "stats reflect current registrations" do
      {:ok, pid} = Agent.start_link(fn -> :running end)

      tools = [
        %{"name" => "stat_tool1", "description" => "A"},
        %{"name" => "stat_tool2", "description" => "B"}
      ]

      {:ok, _} = ToolRegistry.register_skill_tools("stats_skill", tools, pid)

      stats = ToolRegistry.stats()

      assert stats.total_tools >= 2
      assert stats.total_skills >= 1
      assert Map.has_key?(stats.skills, "stats_skill")

      Agent.stop(pid)
    end
  end

  # ==========================================================================
  # Drain and Clear Tests
  # ==========================================================================

  describe "signal_drain/0" do
    test "marks registry as draining" do
      :ok = ToolRegistry.signal_drain()
      stats = ToolRegistry.stats()
      assert stats.draining == true

      # Clear to reset state
      ToolRegistry.clear_all()
    end
  end

  describe "clear_all/0" do
    test "removes all registrations" do
      {:ok, pid} = Agent.start_link(fn -> :running end)
      tools = [%{"name" => "clearable", "description" => "Test"}]
      {:ok, _} = ToolRegistry.register_skill_tools("clear_skill", tools, pid)

      :ok = ToolRegistry.clear_all()

      stats = ToolRegistry.stats()
      assert stats.total_skills == 0
      assert stats.draining == false

      Agent.stop(pid)
    end
  end

  # ==========================================================================
  # Unregister Tests
  # ==========================================================================

  describe "unregister_skill/1" do
    test "removes skill and its tools" do
      {:ok, pid} = Agent.start_link(fn -> :running end)
      tools = [%{"name" => "removable", "description" => "Test"}]
      {:ok, _} = ToolRegistry.register_skill_tools("unregister_skill", tools, pid)

      ToolRegistry.unregister_skill("unregister_skill")

      # Wait for async cast
      Process.sleep(50)

      result = ToolRegistry.get_tool_owner("unregister_skill_removable")
      assert match?({:error, _}, result)

      Agent.stop(pid)
    end

    test "handles unregistering nonexistent skill" do
      # Should not crash
      ToolRegistry.unregister_skill("nonexistent_skill")
      Process.sleep(50)
    end
  end
end
