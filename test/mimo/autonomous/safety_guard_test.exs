defmodule Mimo.Autonomous.SafetyGuardTest do
  use ExUnit.Case, async: true

  alias Mimo.Autonomous.SafetyGuard

  describe "check_allowed/1" do
    test "allows safe commands" do
      assert :ok == SafetyGuard.check_allowed(%{command: "echo hello"})
      assert :ok == SafetyGuard.check_allowed(%{command: "ls -la"})
      assert :ok == SafetyGuard.check_allowed(%{command: "npm test"})
      assert :ok == SafetyGuard.check_allowed(%{command: "mix test"})
      assert :ok == SafetyGuard.check_allowed(%{command: "git status"})
    end

    test "blocks rm -rf and variants" do
      assert {:error, :blocked_dangerous_command} ==
               SafetyGuard.check_allowed(%{command: "rm -rf /"})

      assert {:error, :blocked_dangerous_command} ==
               SafetyGuard.check_allowed(%{command: "rm -Rf /tmp"})

      assert {:error, :blocked_dangerous_command} ==
               SafetyGuard.check_allowed(%{command: "rm -r /home"})

      assert {:error, :blocked_dangerous_command} ==
               SafetyGuard.check_allowed(%{command: "rm --recursive /var"})
    end

    test "blocks system control commands" do
      assert {:error, :blocked_dangerous_command} ==
               SafetyGuard.check_allowed(%{command: "shutdown now"})

      assert {:error, :blocked_dangerous_command} ==
               SafetyGuard.check_allowed(%{command: "reboot"})

      assert {:error, :blocked_dangerous_command} ==
               SafetyGuard.check_allowed(%{command: "halt"})

      assert {:error, :blocked_dangerous_command} ==
               SafetyGuard.check_allowed(%{command: "poweroff"})

      assert {:error, :blocked_dangerous_command} ==
               SafetyGuard.check_allowed(%{command: "systemctl reboot"})
    end

    test "blocks dangerous Elixir/Erlang calls" do
      assert {:error, :blocked_dangerous_command} ==
               SafetyGuard.check_allowed(%{command: "System.halt()"})

      assert {:error, :blocked_dangerous_command} ==
               SafetyGuard.check_allowed(%{command: ":erlang.halt(0)"})

      assert {:error, :blocked_dangerous_command} ==
               SafetyGuard.check_allowed(%{command: ":init.stop()"})
    end

    test "blocks protected paths" do
      assert {:error, :blocked_protected_path} ==
               SafetyGuard.check_allowed(%{path: "/etc/passwd"})

      assert {:error, :blocked_protected_path} ==
               SafetyGuard.check_allowed(%{path: "/boot/grub"})

      assert {:error, :blocked_protected_path} ==
               SafetyGuard.check_allowed(%{path: "/"})
    end

    test "allows safe paths" do
      assert :ok == SafetyGuard.check_allowed(%{path: "/workspace/project/file.ex"})
      assert :ok == SafetyGuard.check_allowed(%{path: "/home/user/project/src"})
      assert :ok == SafetyGuard.check_allowed(%{path: "/tmp/test"})
    end

    test "handles string keys" do
      assert :ok == SafetyGuard.check_allowed(%{"command" => "echo hello"})

      assert {:error, :blocked_dangerous_command} ==
               SafetyGuard.check_allowed(%{"command" => "rm -rf /"})
    end

    test "allows tasks with no command or path" do
      assert :ok == SafetyGuard.check_allowed(%{type: "test", description: "Run tests"})
    end

    test "returns error for invalid task spec" do
      assert {:error, :invalid_task_spec} == SafetyGuard.check_allowed("not a map")
      assert {:error, :invalid_task_spec} == SafetyGuard.check_allowed(123)
    end
  end

  describe "validate_command/1" do
    test "returns :ok for safe commands" do
      assert :ok == SafetyGuard.validate_command("npm test")
      assert :ok == SafetyGuard.validate_command("mix compile")
    end

    test "returns error for dangerous commands" do
      assert {:error, :blocked_dangerous_command} == SafetyGuard.validate_command("rm -rf /")
      assert {:error, :blocked_dangerous_command} == SafetyGuard.validate_command("shutdown")
    end

    test "returns error for non-string input" do
      assert {:error, :invalid_command} == SafetyGuard.validate_command(123)
      assert {:error, :invalid_command} == SafetyGuard.validate_command(nil)
    end
  end

  describe "validate_path/1" do
    test "returns :ok for safe paths" do
      assert :ok == SafetyGuard.validate_path("/workspace/project/file.ex")
    end

    test "returns error for protected paths" do
      assert {:error, :blocked_protected_path} == SafetyGuard.validate_path("/etc/passwd")
    end

    test "returns error for non-string input" do
      assert {:error, :invalid_path} == SafetyGuard.validate_path(123)
    end
  end

  describe "explain_block/1" do
    test "returns human-readable explanations" do
      assert is_binary(SafetyGuard.explain_block(:blocked_dangerous_command))
      assert is_binary(SafetyGuard.explain_block(:blocked_protected_path))
      assert is_binary(SafetyGuard.explain_block(:invalid_task_spec))
      assert is_binary(SafetyGuard.explain_block(:unknown_reason))
    end
  end
end
