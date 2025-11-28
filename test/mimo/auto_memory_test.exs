defmodule Mimo.AutoMemoryTest do
  @moduledoc """
  Tests for Mimo.AutoMemory module.
  Tests automatic memory storage for tool interactions.
  """
  use ExUnit.Case, async: true

  alias Mimo.AutoMemory

  describe "wrap_tool_call/3" do
    test "returns original result unchanged for success" do
      result = {:ok, "test result"}

      wrapped = AutoMemory.wrap_tool_call("test_tool", %{}, result)

      assert wrapped == result
    end

    test "returns original result unchanged for error" do
      result = {:error, "test error"}

      wrapped = AutoMemory.wrap_tool_call("test_tool", %{}, result)

      assert wrapped == result
    end

    test "returns original result unchanged for complex success" do
      result = {:ok, %{status: "success", data: %{items: [1, 2, 3]}}}

      wrapped = AutoMemory.wrap_tool_call("test_tool", %{"query" => "test"}, result)

      assert wrapped == result
    end

    test "handles map results" do
      result = {:ok, %{"key" => "value"}}

      wrapped = AutoMemory.wrap_tool_call("test_tool", %{}, result)

      assert wrapped == result
    end

    test "handles string results" do
      result = {:ok, "plain string result"}

      wrapped = AutoMemory.wrap_tool_call("test_tool", %{}, result)

      assert wrapped == result
    end
  end

  describe "enabled?/0" do
    test "returns boolean" do
      result = AutoMemory.enabled?()

      assert is_boolean(result)
    end

    test "defaults to true" do
      # Clean up any test config
      original = Application.get_env(:mimo_mcp, :auto_memory_enabled)

      try do
        Application.delete_env(:mimo_mcp, :auto_memory_enabled)
        assert AutoMemory.enabled?() == true
      after
        if original do
          Application.put_env(:mimo_mcp, :auto_memory_enabled, original)
        end
      end
    end

    test "respects configuration" do
      original = Application.get_env(:mimo_mcp, :auto_memory_enabled)

      try do
        Application.put_env(:mimo_mcp, :auto_memory_enabled, false)
        assert AutoMemory.enabled?() == false

        Application.put_env(:mimo_mcp, :auto_memory_enabled, true)
        assert AutoMemory.enabled?() == true
      after
        if original do
          Application.put_env(:mimo_mcp, :auto_memory_enabled, original)
        else
          Application.delete_env(:mimo_mcp, :auto_memory_enabled)
        end
      end
    end
  end

  describe "wrap_tool_call/3 with disabled auto-memory" do
    test "still returns original result when disabled" do
      original = Application.get_env(:mimo_mcp, :auto_memory_enabled)

      try do
        Application.put_env(:mimo_mcp, :auto_memory_enabled, false)

        result = {:ok, "test"}
        wrapped = AutoMemory.wrap_tool_call("test_tool", %{}, result)

        assert wrapped == result
      after
        if original do
          Application.put_env(:mimo_mcp, :auto_memory_enabled, original)
        else
          Application.delete_env(:mimo_mcp, :auto_memory_enabled)
        end
      end
    end
  end

  describe "tool categorization" do
    test "file operations are categorized correctly" do
      # Test that file tools trigger memory storage (via Task.start)
      result = {:ok, %{"content" => "file content"}}

      # This should not raise and should return result
      wrapped = AutoMemory.wrap_tool_call("read_file", %{"path" => "/test/file.txt"}, result)

      assert wrapped == result
    end

    test "search operations are categorized correctly" do
      result = {:ok, [%{match: "result"}]}

      wrapped = AutoMemory.wrap_tool_call("search_vibes", %{"query" => "test"}, result)

      assert wrapped == result
    end

    test "internal memory tools are skipped to avoid recursion" do
      result = {:ok, %{stored: true}}

      # These should be skipped
      assert AutoMemory.wrap_tool_call("store_fact", %{}, result) == result
      assert AutoMemory.wrap_tool_call("ask_mimo", %{}, result) == result
      assert AutoMemory.wrap_tool_call("mimo_reload_skills", %{}, result) == result
    end
  end
end
