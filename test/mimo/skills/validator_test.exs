defmodule Mimo.Skills.ValidatorTest do
  use ExUnit.Case, async: true

  alias Mimo.Skills.Validator

  @moduletag :validation

  describe "validate_config/1" do
    test "accepts valid npx config" do
      config = %{
        "command" => "npx",
        "args" => ["-y", "@anthropic-ai/mcp-server"],
        "env" => %{"API_KEY" => "test"}
      }

      assert {:ok, validated} = Validator.validate_config(config)
      assert validated["command"] == "npx"
    end

    test "accepts config with atom keys" do
      config = %{
        command: "node",
        args: ["server.js"]
      }

      assert {:ok, validated} = Validator.validate_config(config)
      assert validated["command"] == "node"
    end

    test "rejects nil config" do
      assert {:error, {:invalid_config, _}} = Validator.validate_config(nil)
    end

    test "rejects non-map config" do
      assert {:error, {:invalid_config, _}} = Validator.validate_config("invalid")
      assert {:error, {:invalid_config, _}} = Validator.validate_config([])
    end
  end

  describe "validate_config/1 - command validation" do
    test "rejects missing command" do
      config = %{"args" => ["-y"]}

      assert {:error, {:missing_field, "command"}} = Validator.validate_config(config)
    end

    test "rejects empty command" do
      config = %{"command" => "", "args" => []}

      assert {:error, {:empty_field, "command"}} = Validator.validate_config(config)
    end

    test "rejects non-string command" do
      config = %{"command" => 123, "args" => []}

      assert {:error, {:invalid_type, "command", "string"}} = Validator.validate_config(config)
    end

    test "rejects non-whitelisted command" do
      config = %{"command" => "bash", "args" => []}

      assert {:error, {:command_not_allowed, "bash", _}} = Validator.validate_config(config)
    end

    test "rejects command with path separators" do
      config = %{"command" => "/usr/bin/npx", "args" => []}

      assert {:error, {:invalid_command, _}} = Validator.validate_config(config)
    end

    test "rejects path traversal in command" do
      config = %{"command" => "../../../bin/bash", "args" => []}

      assert {:error, {:invalid_command, _}} = Validator.validate_config(config)
    end
  end

  describe "validate_config/1 - args validation" do
    test "accepts valid args" do
      config = %{
        "command" => "npx",
        "args" => ["-y", "@test/package", "--config=value"]
      }

      assert {:ok, _} = Validator.validate_config(config)
    end

    test "accepts empty args" do
      config = %{"command" => "node"}

      assert {:ok, _} = Validator.validate_config(config)
    end

    test "rejects non-list args" do
      config = %{"command" => "npx", "args" => "not-a-list"}

      assert {:error, {:invalid_type, "args", "array"}} = Validator.validate_config(config)
    end

    test "rejects too many args" do
      config = %{
        "command" => "npx",
        "args" => List.duplicate("arg", 35)
      }

      assert {:error, {:too_many_args, 35, 30}} = Validator.validate_config(config)
    end

    test "rejects dangerous shell metacharacters" do
      dangerous_args = [
        "test; rm -rf /",
        "test && echo pwned",
        "test | cat /etc/passwd",
        "test `whoami`",
        "$(id)",
        "test > /tmp/out"
      ]

      for arg <- dangerous_args do
        config = %{"command" => "npx", "args" => ["-y", arg]}
        assert {:error, {:dangerous_args, _}} = Validator.validate_config(config)
      end
    end

    test "rejects path traversal in args" do
      config = %{
        "command" => "node",
        "args" => ["../../../etc/passwd"]
      }

      assert {:error, {:dangerous_args, _}} = Validator.validate_config(config)
    end

    test "rejects /etc/ access in args" do
      config = %{
        "command" => "node",
        "args" => ["/etc/shadow"]
      }

      assert {:error, {:dangerous_args, _}} = Validator.validate_config(config)
    end

    test "rejects args that are too long" do
      long_arg = String.duplicate("a", 2000)

      config = %{
        "command" => "npx",
        "args" => ["-y", long_arg]
      }

      assert {:error, {:arg_too_long, 1024}} = Validator.validate_config(config)
    end
  end

  describe "validate_config/1 - env validation" do
    test "accepts valid env vars" do
      config = %{
        "command" => "npx",
        "args" => ["-y"],
        "env" => %{
          "API_KEY" => "test",
          "NODE_ENV" => "production"
        }
      }

      assert {:ok, _} = Validator.validate_config(config)
    end

    test "accepts empty env" do
      config = %{"command" => "npx", "args" => [], "env" => %{}}

      assert {:ok, _} = Validator.validate_config(config)
    end

    test "rejects non-map env" do
      config = %{
        "command" => "npx",
        "args" => [],
        "env" => [{"KEY", "value"}]
      }

      assert {:error, {:invalid_type, "env", "object"}} = Validator.validate_config(config)
    end

    test "rejects too many env vars" do
      env = for i <- 1..35, into: %{}, do: {"VAR_#{i}", "value"}

      config = %{
        "command" => "npx",
        "args" => [],
        "env" => env
      }

      assert {:error, {:too_many_env_vars, 35, 30}} = Validator.validate_config(config)
    end

    test "rejects invalid env var names" do
      config = %{
        "command" => "npx",
        "args" => [],
        "env" => %{"invalid-name" => "value"}
      }

      assert {:error, {:invalid_env_var_names, ["invalid-name"]}} =
               Validator.validate_config(config)
    end

    test "rejects env var values that are too long" do
      long_value = String.duplicate("a", 2000)

      config = %{
        "command" => "npx",
        "args" => [],
        "env" => %{"KEY" => long_value}
      }

      assert {:error, {:env_value_too_long, "KEY", 1024}} = Validator.validate_config(config)
    end

    test "rejects non-allowed interpolation variables" do
      config = %{
        "command" => "npx",
        "args" => [],
        # Not in allowed list
        "env" => %{"KEY" => "${SECRET_PASSWORD}"}
      }

      assert {:error, {:invalid_interpolation, "KEY", ["SECRET_PASSWORD"], _}} =
               Validator.validate_config(config)
    end

    test "accepts allowed interpolation variables" do
      config = %{
        "command" => "npx",
        "args" => [],
        # In allowed list
        "env" => %{"KEY" => "${EXA_API_KEY}"}
      }

      assert {:ok, _} = Validator.validate_config(config)
    end
  end

  describe "validate_config/1 - extra fields" do
    test "rejects extra fields" do
      config = %{
        "command" => "npx",
        "args" => [],
        "env" => %{},
        "extra_field" => "not allowed"
      }

      assert {:error, {:extra_fields, ["extra_field"], _}} = Validator.validate_config(config)
    end
  end

  describe "validate_configs/1" do
    test "validates multiple configs" do
      configs = [
        %{"command" => "npx", "args" => ["-y", "@test/a"]},
        %{"command" => "node", "args" => ["server.js"]}
      ]

      assert {:ok, validated} = Validator.validate_configs(configs)
      assert length(validated) == 2
    end

    test "returns errors for invalid configs" do
      configs = [
        %{"command" => "npx", "args" => ["-y"]},
        # Invalid
        %{"command" => "bash", "args" => []},
        %{"command" => "node", "args" => []}
      ]

      assert {:error, errors} = Validator.validate_configs(configs)
      assert length(errors) == 1
      assert {1, {:command_not_allowed, "bash", _}} = hd(errors)
    end
  end

  describe "safe_arg?/1" do
    test "returns true for safe args" do
      assert Validator.safe_arg?("-y")
      assert Validator.safe_arg?("@anthropic/mcp-server")
      assert Validator.safe_arg?("--config=value")
      assert Validator.safe_arg?("simple-arg")
    end

    test "returns false for dangerous args" do
      refute Validator.safe_arg?("; rm -rf /")
      refute Validator.safe_arg?("| cat /etc/passwd")
      refute Validator.safe_arg?("$(whoami)")
      refute Validator.safe_arg?("../../../etc/passwd")
    end

    test "returns false for non-strings" do
      refute Validator.safe_arg?(123)
      refute Validator.safe_arg?(nil)
    end
  end

  describe "valid_env_var_name?/1" do
    test "returns true for valid names" do
      assert Validator.valid_env_var_name?("API_KEY")
      assert Validator.valid_env_var_name?("NODE_ENV")
      assert Validator.valid_env_var_name?("MY_VAR_123")
      assert Validator.valid_env_var_name?("_PRIVATE")
    end

    test "returns false for invalid names" do
      # Hyphen not allowed
      refute Validator.valid_env_var_name?("my-var")
      # Can't start with number
      refute Validator.valid_env_var_name?("123_VAR")
      # Must be uppercase
      refute Validator.valid_env_var_name?("var")
      refute Validator.valid_env_var_name?("")
    end
  end

  describe "allowed_interpolation?/1" do
    test "returns true for allowed variables" do
      assert Validator.allowed_interpolation?("EXA_API_KEY")
      assert Validator.allowed_interpolation?("GITHUB_TOKEN")
      assert Validator.allowed_interpolation?("ANTHROPIC_API_KEY")
      assert Validator.allowed_interpolation?("HOME")
      assert Validator.allowed_interpolation?("PATH")
    end

    test "returns false for non-allowed variables" do
      refute Validator.allowed_interpolation?("SECRET_PASSWORD")
      refute Validator.allowed_interpolation?("DATABASE_URL")
      refute Validator.allowed_interpolation?("AWS_SECRET_KEY")
    end
  end
end
