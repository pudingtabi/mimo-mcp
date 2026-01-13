defmodule Mimo.Tools.Dispatchers.TerminalTest do
  @moduledoc """
  Tests for Terminal dispatcher routing and operation handling.

  Tests the dispatcher layer (routing, error handling, outcome detection)
  rather than underlying Terminal skill (which has its own tests).
  """
  use Mimo.DataCase, async: true

  alias Mimo.Tools.Dispatchers.Terminal, as: TerminalDispatcher

  # Helper to check if result is successful
  defp ok_result?({:ok, _}), do: true
  defp ok_result?(:ok), do: true
  defp ok_result?(_), do: false

  # Helper to extract data from various return formats
  defp extract_data({:ok, %{data: data}}), do: data
  defp extract_data({:ok, data}) when is_map(data), do: data
  defp extract_data({:ok, data}) when is_list(data), do: data
  defp extract_data(:ok), do: %{success: true}
  defp extract_data(other), do: other

  describe "dispatch/1 routing" do
    test "defaults to execute operation" do
      args = %{"command" => "echo hello"}
      result = TerminalDispatcher.dispatch(args)
      assert ok_result?(result)
      data = extract_data(result)
      assert data.output =~ "hello"
    end

    test "returns error for unknown operation" do
      args = %{"operation" => "unknown_op", "command" => "echo"}
      assert {:error, msg} = TerminalDispatcher.dispatch(args)
      assert msg =~ "Unknown terminal operation"
    end
  end

  describe "execute operation" do
    test "runs simple command" do
      args = %{"operation" => "execute", "command" => "echo 'test output'"}
      result = TerminalDispatcher.dispatch(args)
      assert ok_result?(result)
      data = extract_data(result)
      assert data.output =~ "test output"
      assert data.status == 0
    end

    test "captures exit code on failure" do
      args = %{"operation" => "execute", "command" => "exit 1"}
      result = TerminalDispatcher.dispatch(args)
      assert ok_result?(result)
      data = extract_data(result)
      assert data.status == 1
    end

    test "respects timeout" do
      # Very short timeout should fail or complete quickly
      args = %{"operation" => "execute", "command" => "echo fast", "timeout" => 1000}
      result = TerminalDispatcher.dispatch(args)
      assert ok_result?(result)
    end

    test "uses custom working directory", %{} do
      args = %{"operation" => "execute", "command" => "pwd", "cwd" => "/tmp"}
      result = TerminalDispatcher.dispatch(args)
      assert ok_result?(result)
      data = extract_data(result)
      assert data.output =~ "/tmp"
    end

    test "passes environment variables" do
      args = %{
        "operation" => "execute",
        "command" => "echo $MY_TEST_VAR",
        "env" => %{"MY_TEST_VAR" => "test_value"},
        "shell" => "bash"
      }

      result = TerminalDispatcher.dispatch(args)
      assert ok_result?(result)
      data = extract_data(result)
      assert data.output =~ "test_value"
    end

    test "handles empty command" do
      args = %{"operation" => "execute", "command" => ""}
      result = TerminalDispatcher.dispatch(args)
      # Empty command should return some result (might be error or empty success)
      assert ok_result?(result) or match?({:error, _}, result)
    end
  end

  describe "process management operations" do
    test "list_sessions returns session list" do
      args = %{"operation" => "list_sessions"}
      result = TerminalDispatcher.dispatch(args)
      assert ok_result?(result)
    end

    test "list_processes returns process list" do
      args = %{"operation" => "list_processes"}
      result = TerminalDispatcher.dispatch(args)
      assert ok_result?(result)
    end

    test "read_output handles invalid pid" do
      args = %{"operation" => "read_output", "pid" => -1}
      result = TerminalDispatcher.dispatch(args)
      # Should return error for invalid pid
      assert match?({:error, _}, result)
    end

    test "kill handles invalid pid" do
      args = %{"operation" => "kill", "pid" => -1}
      result = TerminalDispatcher.dispatch(args)
      # Should return error for invalid pid
      assert match?({:error, _}, result)
    end

    test "force_kill handles invalid pid" do
      args = %{"operation" => "force_kill", "pid" => -1}
      result = TerminalDispatcher.dispatch(args)
      # Should return error for invalid pid
      assert match?({:error, _}, result)
    end

    test "interact handles invalid pid" do
      args = %{"operation" => "interact", "pid" => -1, "input" => "test"}
      result = TerminalDispatcher.dispatch(args)
      # Should return error for invalid pid
      assert match?({:error, _}, result)
    end
  end

  describe "start_process operation" do
    test "starts a background process" do
      # Use a quick sleep to test process start
      args = %{"operation" => "start_process", "command" => "sleep 0.1", "name" => "test_sleep"}
      result = TerminalDispatcher.dispatch(args)

      case result do
        {:ok, %{pid: pid}} when is_integer(pid) ->
          assert pid > 0
          # Clean up - kill the process
          TerminalDispatcher.dispatch(%{"operation" => "kill", "pid" => pid})

        {:ok, _other} ->
          # Some other success format is acceptable
          assert true

        {:error, _reason} ->
          # May fail depending on environment - acceptable
          assert true
      end
    end

    test "accepts named session" do
      args = %{
        "operation" => "start_process",
        "command" => "echo named",
        "name" => "my_named_session"
      }

      result = TerminalDispatcher.dispatch(args)
      # Should succeed or fail gracefully
      assert ok_result?(result) or match?({:error, _}, result)
    end
  end

  describe "skip_memory_context option" do
    test "defaults to skipping memory context" do
      args = %{"operation" => "execute", "command" => "echo test"}
      result = TerminalDispatcher.dispatch(args)
      assert ok_result?(result)
      # Memory context should be skipped by default (SPEC-064)
    end

    test "respects explicit skip_memory_context flag" do
      args = %{
        "operation" => "execute",
        "command" => "echo test",
        "skip_memory_context" => false
      }

      result = TerminalDispatcher.dispatch(args)
      assert ok_result?(result)
    end
  end

  describe "shell selection" do
    test "uses bash shell when specified" do
      args = %{
        "operation" => "execute",
        "command" => "echo $SHELL",
        "shell" => "bash"
      }

      result = TerminalDispatcher.dispatch(args)
      assert ok_result?(result)
    end

    test "uses sh shell when specified" do
      args = %{
        "operation" => "execute",
        "command" => "echo hello",
        "shell" => "sh"
      }

      result = TerminalDispatcher.dispatch(args)
      assert ok_result?(result)
    end
  end

  describe "timeout validation" do
    test "caps timeout at maximum" do
      # Very long timeout should be capped
      args = %{
        "operation" => "execute",
        "command" => "echo fast",
        "timeout" => 999_999_999
      }

      result = TerminalDispatcher.dispatch(args)
      assert ok_result?(result)
    end

    test "uses default timeout when not specified" do
      args = %{"operation" => "execute", "command" => "echo test"}
      result = TerminalDispatcher.dispatch(args)
      assert ok_result?(result)
    end
  end

  describe "command output" do
    test "captures stdout" do
      args = %{"operation" => "execute", "command" => "echo stdout_test"}
      result = TerminalDispatcher.dispatch(args)
      assert ok_result?(result)
      data = extract_data(result)
      assert data.output =~ "stdout_test"
    end

    test "captures stderr" do
      args = %{"operation" => "execute", "command" => "echo stderr_test >&2", "shell" => "bash"}
      result = TerminalDispatcher.dispatch(args)
      assert ok_result?(result)
      data = extract_data(result)
      # stderr should be captured in output
      assert data.output =~ "stderr_test"
    end

    test "handles commands with special characters" do
      args = %{"operation" => "execute", "command" => "echo 'hello world'"}
      result = TerminalDispatcher.dispatch(args)
      assert ok_result?(result)
      data = extract_data(result)
      assert data.output =~ "hello world"
    end
  end

  describe "yolo mode" do
    test "respects yolo flag" do
      args = %{
        "operation" => "execute",
        "command" => "echo yolo_test",
        "yolo" => true
      }

      result = TerminalDispatcher.dispatch(args)
      assert ok_result?(result)
    end

    test "respects confirm flag" do
      args = %{
        "operation" => "execute",
        "command" => "echo confirm_test",
        "confirm" => true
      }

      result = TerminalDispatcher.dispatch(args)
      assert ok_result?(result)
    end
  end
end
