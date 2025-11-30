defmodule Mimo.Skills.TerminalTest do
  @moduledoc """
  Tests for Terminal skill enhancements from SPEC-026.
  Tests cwd, env, shell selection, and output truncation.
  """
  use ExUnit.Case, async: true

  alias Mimo.Skills.Terminal

  # Use workspace-relative path for tests
  @test_dir Path.expand("../../../_test_terminal_#{:rand.uniform(100_000)}", __DIR__)

  setup do
    File.mkdir_p!(@test_dir)

    on_exit(fn ->
      File.rm_rf!(@test_dir)
    end)

    {:ok, test_dir: @test_dir}
  end

  describe "execute/2 with cwd option" do
    test "executes command in specified directory", %{test_dir: test_dir} do
      result = Terminal.execute("pwd", cwd: test_dir, shell: "bash")

      assert result.status == 0
      assert String.trim(result.output) == test_dir
    end

    test "returns error for non-existent directory" do
      result = Terminal.execute("pwd", cwd: "/nonexistent/path/12345", shell: "bash")

      # Should fail with non-zero status
      assert result.status != 0
    end

    test "uses current directory when cwd not specified" do
      result = Terminal.execute("pwd", shell: "bash")

      assert result.status == 0
      assert String.contains?(result.output, "/")
    end
  end

  describe "execute/2 with env option" do
    test "sets environment variables for command" do
      result =
        Terminal.execute("printenv MY_TEST_VAR",
          env: %{"MY_TEST_VAR" => "hello_world"},
          shell: "bash"
        )

      assert result.status == 0
      assert String.trim(result.output) == "hello_world"
    end

    test "sets multiple environment variables" do
      result =
        Terminal.execute("printenv VAR1 && printenv VAR2",
          env: %{"VAR1" => "first", "VAR2" => "second"},
          shell: "bash"
        )

      assert result.status == 0
      assert String.contains?(result.output, "first")
      assert String.contains?(result.output, "second")
    end

    test "handles empty env map" do
      result = Terminal.execute("echo test", env: %{}, shell: "bash")

      assert result.status == 0
      assert String.trim(result.output) == "test"
    end
  end

  describe "execute/2 with shell option" do
    test "executes command with bash shell" do
      result = Terminal.execute("echo hello from bash", shell: "bash")

      assert result.status == 0
      assert String.trim(result.output) == "hello from bash"
    end

    test "executes command with sh shell" do
      result = Terminal.execute("echo hello", shell: "sh")

      assert result.status == 0
      assert String.trim(result.output) == "hello"
    end

    test "direct execution without shell (default)" do
      result = Terminal.execute("echo hello")

      assert result.status == 0
      assert String.trim(result.output) == "hello"
    end
  end

  describe "execute/2 with combined options" do
    test "combines cwd, env, and shell options", %{test_dir: test_dir} do
      result =
        Terminal.execute("pwd && printenv MY_VAR",
          cwd: test_dir,
          env: %{"MY_VAR" => "combined_test"},
          shell: "bash"
        )

      assert result.status == 0
      assert String.contains?(result.output, test_dir)
      assert String.contains?(result.output, "combined_test")
    end
  end

  describe "output truncation" do
    test "does not truncate small output" do
      result = Terminal.execute("echo 'small output'", shell: "bash")

      assert result.status == 0
      refute String.contains?(result.output, "TRUNCATED")
    end
  end

  describe "yolo mode" do
    test "executes commands in yolo mode", %{test_dir: test_dir} do
      # Create a temp file to test with
      tmp_file = Path.join(test_dir, "test_file.txt")
      File.write!(tmp_file, "test content")

      result = Terminal.execute("cat #{tmp_file}", yolo: true)

      assert result.status == 0
      assert String.contains?(result.output, "test content")
    end
  end

  describe "blocked commands" do
    test "blocks interactive TUI commands" do
      result = Terminal.execute("vim test.txt")

      assert result.status == 1
      assert String.contains?(result.output, "prohibited")
    end

    test "blocks screen command" do
      result = Terminal.execute("screen -S test")

      assert result.status == 1
      assert String.contains?(result.output, "prohibited")
    end
  end

  describe "timeout handling" do
    test "terminates command after timeout" do
      result = Terminal.execute("sleep 10", timeout: 100, shell: "bash")

      assert result.status == 1
      assert String.contains?(result.output, "timed out")
    end
  end

  describe "error handling" do
    test "captures command errors" do
      result = Terminal.execute("nonexistent_command_12345", shell: "bash")

      assert result.status != 0
    end

    test "handles empty command" do
      result = Terminal.execute("")

      assert result.status == 1
      assert String.contains?(result.output, "error") || String.contains?(result.output, "Empty")
    end
  end
end
