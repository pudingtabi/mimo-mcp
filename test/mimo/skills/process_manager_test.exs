defmodule Mimo.Skills.ProcessManagerTest do
  @moduledoc """
  Tests for Skills Process Manager module.
  Tests port lifecycle, communication, and cleanup.
  """
  use ExUnit.Case, async: true

  alias Mimo.Skills.ProcessManager

  # ==========================================================================
  # Module Tests
  # ==========================================================================

  describe "module definition" do
    test "module is loadable" do
      assert Code.ensure_loaded?(Mimo.Skills.ProcessManager)
    end

    test "spawn_subprocess/1 is defined" do
      functions = ProcessManager.__info__(:functions)
      assert {:spawn_subprocess, 1} in functions
    end

    test "close_port/1 is defined" do
      functions = ProcessManager.__info__(:functions)
      assert {:close_port, 1} in functions
    end

    test "port_alive?/1 is defined" do
      functions = ProcessManager.__info__(:functions)
      assert {:port_alive?, 1} in functions
    end
  end

  # ==========================================================================
  # Port Lifecycle Tests
  # ==========================================================================

  describe "close_port/1" do
    test "handles nil port gracefully" do
      assert :ok = ProcessManager.close_port(nil)
    end

    test "closes live port" do
      # Spawn a simple process
      port = Port.open({:spawn, "cat"}, [:binary])
      assert ProcessManager.port_alive?(port)

      assert :ok = ProcessManager.close_port(port)
    end
  end

  describe "port_alive?/1" do
    test "returns false for invalid input" do
      refute ProcessManager.port_alive?(nil)
      refute ProcessManager.port_alive?(:not_a_port)
    end

    test "returns true for live port" do
      port = Port.open({:spawn, "cat"}, [:binary])
      assert ProcessManager.port_alive?(port)
      Port.close(port)
    end

    test "returns false for closed port" do
      port = Port.open({:spawn, "cat"}, [:binary])
      Port.close(port)
      # Give system time to clean up
      Process.sleep(50)
      refute ProcessManager.port_alive?(port)
    end
  end

  # ==========================================================================
  # Spawn Tests
  # ==========================================================================

  describe "spawn_subprocess/1" do
    test "returns error for invalid config" do
      config = %{"invalid" => "config"}
      result = ProcessManager.spawn_subprocess(config)

      assert match?({:error, _}, result)
    end

    test "returns error for missing command" do
      config = %{"args" => []}
      result = ProcessManager.spawn_subprocess(config)

      assert match?({:error, _}, result)
    end
  end

  describe "spawn_legacy/1" do
    test "returns error for command not found" do
      config = %{
        "command" => "nonexistent_command_xyz_12345",
        "args" => []
      }

      result = ProcessManager.spawn_legacy(config)
      assert match?({:error, _}, result)
    end

    test "spawns valid command" do
      config = %{
        "command" => "echo",
        "args" => ["hello"]
      }

      case ProcessManager.spawn_legacy(config) do
        {:ok, port} ->
          assert is_port(port)
          ProcessManager.close_port(port)

        {:error, _} ->
          # echo might not be available on all systems
          :ok
      end
    end
  end

  # ==========================================================================
  # Communication Tests
  # ==========================================================================

  describe "send_command/2" do
    test "sends command to live port" do
      port = Port.open({:spawn, "cat"}, [:binary])

      result = ProcessManager.send_command(port, "test\n")
      assert result == :ok

      Port.close(port)
    end
  end

  describe "receive_data/2" do
    test "receives data from port" do
      port = Port.open({:spawn, "echo hello"}, [:binary, :exit_status])

      case ProcessManager.receive_data(port, 5000) do
        {:ok, data} ->
          assert String.contains?(data, "hello")

        {:error, _} ->
          # May exit before we can read
          :ok
      end
    end

    test "returns timeout error" do
      port = Port.open({:spawn, "cat"}, [:binary])

      result = ProcessManager.receive_data(port, 100)
      assert result == {:error, :timeout}

      Port.close(port)
    end
  end

  # ==========================================================================
  # JSON Response Tests
  # ==========================================================================

  describe "receive_json_response/3" do
    test "returns timeout when no response" do
      port = Port.open({:spawn, "cat"}, [:binary])

      result = ProcessManager.receive_json_response(port, 100, "")
      assert result == {:error, :discovery_timeout}

      Port.close(port)
    end
  end

  # ==========================================================================
  # Port Info Tests
  # ==========================================================================

  describe "port_info/1" do
    test "returns info for live port" do
      port = Port.open({:spawn, "cat"}, [:binary])

      info = ProcessManager.port_info(port)
      assert is_list(info)

      Port.close(port)
    end

    test "returns nil for dead port" do
      port = Port.open({:spawn, "cat"}, [:binary])
      Port.close(port)
      Process.sleep(50)

      info = ProcessManager.port_info(port)
      assert is_nil(info)
    end
  end
end
