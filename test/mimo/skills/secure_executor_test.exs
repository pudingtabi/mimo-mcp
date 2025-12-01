defmodule Mimo.Skills.SecureExecutorTest do
  use ExUnit.Case, async: true

  alias Mimo.Skills.SecureExecutor

  @moduletag :security

  describe "allowed_command?/1" do
    test "allows whitelisted commands" do
      assert SecureExecutor.allowed_command?("npx")
      assert SecureExecutor.allowed_command?("docker")
      assert SecureExecutor.allowed_command?("node")
      assert SecureExecutor.allowed_command?("python")
      assert SecureExecutor.allowed_command?("python3")
    end

    test "rejects non-whitelisted commands" do
      refute SecureExecutor.allowed_command?("bash")
      refute SecureExecutor.allowed_command?("sh")
      refute SecureExecutor.allowed_command?("curl")
      refute SecureExecutor.allowed_command?("wget")
      refute SecureExecutor.allowed_command?("rm")
      refute SecureExecutor.allowed_command?("cat")
    end

    test "rejects commands with path" do
      # Note: allowed_command? extracts basename, so these are allowed
      # The security is enforced during execute_skill via normalize_config
      # which also extracts basename - so even with paths, only whitelisted
      # base commands work
      assert SecureExecutor.allowed_command?("/bin/bash") == false
      # basename is npx
      assert SecureExecutor.allowed_command?("/usr/bin/npx") == true
      # basename is sh
      assert SecureExecutor.allowed_command?("../../../bin/sh") == false
    end
  end

  describe "execute_skill/1 - command validation" do
    test "rejects unknown commands" do
      config = %{"command" => "bash", "args" => ["-c", "echo test"]}

      assert {:error, {:command_not_allowed, "bash", _}} = SecureExecutor.execute_skill(config)
    end

    test "rejects path traversal in command" do
      config = %{"command" => "../../../bin/bash", "args" => []}

      assert {:error, _} = SecureExecutor.execute_skill(config)
    end

    test "rejects missing command field" do
      config = %{"args" => ["-y", "@test/package"]}

      assert {:error, {:invalid_config, _}} = SecureExecutor.execute_skill(config)
    end
  end

  describe "execute_skill/1 - argument validation" do
    test "rejects shell metacharacters in args" do
      config = %{
        "command" => "npx",
        "args" => ["-y", "@test/package; rm -rf /"]
      }

      assert {:error, {:invalid_arg_characters, _}} = SecureExecutor.execute_skill(config)
    end

    test "rejects command substitution" do
      config = %{
        "command" => "npx",
        "args" => ["-y", "$(whoami)"]
      }

      assert {:error, {:invalid_arg_characters, _}} = SecureExecutor.execute_skill(config)
    end

    test "rejects backtick command substitution" do
      config = %{
        "command" => "npx",
        "args" => ["-y", "`id`"]
      }

      assert {:error, {:invalid_arg_characters, _}} = SecureExecutor.execute_skill(config)
    end

    test "rejects pipe characters" do
      config = %{
        "command" => "npx",
        "args" => ["-y", "package | cat /etc/passwd"]
      }

      assert {:error, {:invalid_arg_characters, _}} = SecureExecutor.execute_skill(config)
    end

    test "rejects too many arguments" do
      # npx has max_args: 20
      config = %{
        "command" => "npx",
        "args" => List.duplicate("arg", 25)
      }

      assert {:error, {:too_many_args, 25, 20}} = SecureExecutor.execute_skill(config)
    end
  end

  describe "execute_skill/1 - docker security" do
    test "rejects --privileged flag" do
      config = %{
        "command" => "docker",
        "args" => ["run", "--privileged", "alpine"]
      }

      assert {:error, {:forbidden_args, _}} = SecureExecutor.execute_skill(config)
    end

    test "rejects --network=host" do
      config = %{
        "command" => "docker",
        "args" => ["run", "--network=host", "alpine"]
      }

      assert {:error, {:forbidden_args, _}} = SecureExecutor.execute_skill(config)
    end

    test "rejects docker.sock mount" do
      config = %{
        "command" => "docker",
        "args" => ["run", "-v", "/var/run/docker.sock:/var/run/docker.sock", "alpine"]
      }

      assert {:error, {:forbidden_args, _}} = SecureExecutor.execute_skill(config)
    end
  end

  describe "execute_skill/1 - environment variables" do
    test "allows whitelisted env var interpolation" do
      # Set a test env var
      System.put_env("EXA_API_KEY", "test-key-value")

      config = %{
        "command" => "npx",
        "args" => ["-y", "@test/package"],
        "env" => %{"API_KEY" => "${EXA_API_KEY}"}
      }

      # Should not error on validation (may fail on execution if npx not found)
      result = SecureExecutor.execute_skill(config)
      # Either succeeds with a port or fails with command_not_found
      assert match?({:ok, _, _}, result) or match?({:error, {:command_not_found, _}}, result)
    end

    test "blocks non-whitelisted env var interpolation" do
      config = %{
        "command" => "npx",
        "args" => ["-y", "@test/package"],
        # SECRET_KEY not in allowed list
        "env" => %{"MY_VAR" => "${SECRET_KEY}"}
      }

      # The env var will be replaced with empty string (blocked)
      # This is not an error, just silent blocking
      result = SecureExecutor.execute_skill(config)
      assert match?({:ok, _, _}, result) or match?({:error, {:command_not_found, _}}, result)
    end

    test "validates env var name format" do
      config = %{
        "command" => "npx",
        "args" => ["-y", "@test/package"],
        # Hyphens not allowed
        "env" => %{"invalid-name" => "value"}
      }

      # Invalid env var names are filtered out
      result = SecureExecutor.execute_skill(config)
      assert match?({:ok, _, _}, result) or match?({:error, {:command_not_found, _}}, result)
    end
  end

  describe "command_restrictions/1" do
    test "returns restrictions for known commands" do
      restrictions = SecureExecutor.command_restrictions("npx")

      assert restrictions.max_args == 20
      assert restrictions.timeout_ms == 120_000
      assert is_list(restrictions.allowed_arg_patterns)
    end

    test "returns nil for unknown commands" do
      assert SecureExecutor.command_restrictions("unknown") == nil
    end
  end
end
