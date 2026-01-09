defmodule Mimo.Verification.ActionVerifierTest do
  @moduledoc """
  Tests for SPEC-2026-001: Agent Verification Layer

  Tests phantom success detection and verification tiers.
  """

  use ExUnit.Case, async: true

  alias Mimo.Verification.ActionVerifier

  @test_dir System.tmp_dir!()

  describe "capture_state/2" do
    test "captures file state for existing file" do
      path = Path.join(@test_dir, "test_capture_#{:rand.uniform(10000)}.txt")
      File.write!(path, "hello world")

      state = ActionVerifier.capture_state(:file_edit, path)

      assert state.type == :file_edit
      assert state.path == path
      assert is_integer(state.content_hash)
      assert state.content_length == 11
      assert is_integer(state.timestamp)

      File.rm(path)
    end

    test "captures state for non-existent file" do
      path = Path.join(@test_dir, "nonexistent_#{:rand.uniform(10000)}.txt")

      state = ActionVerifier.capture_state(:file_edit, path)

      assert state.type == :file_edit
      assert state.path == path
      assert state.content_hash == nil
      assert state.exists == false
    end

    test "captures terminal state" do
      state = ActionVerifier.capture_state(:terminal, "echo hello")

      assert state.type == :terminal
      assert is_integer(state.timestamp)
    end
  end

  describe "verify/4 - file changes" do
    test "detects actual file change (verified)" do
      path = Path.join(@test_dir, "test_verify_change_#{:rand.uniform(10000)}.txt")
      File.write!(path, "before content")

      before_state = ActionVerifier.capture_state(:file_edit, path)

      # Simulate edit
      File.write!(path, "after content - different!")

      result = ActionVerifier.verify(:file_edit, path, before_state, {:ok, %{}})

      assert {:verified, details} = result
      assert details.outcome == :change_confirmed
      assert details.before_hash != details.after_hash
      assert is_integer(details.size_delta)

      File.rm(path)
    end

    test "detects phantom success (no change)" do
      path = Path.join(@test_dir, "test_phantom_#{:rand.uniform(10000)}.txt")
      File.write!(path, "unchanged content")

      before_state = ActionVerifier.capture_state(:file_edit, path)

      # "Edit" that doesn't change anything
      File.write!(path, "unchanged content")

      result = ActionVerifier.verify(:file_edit, path, before_state, {:ok, %{}})

      assert {:phantom_success, details} = result
      assert details.outcome == :no_change
      assert details.warning =~ "unchanged"

      File.rm(path)
    end

    test "detects file creation" do
      path = Path.join(@test_dir, "test_create_#{:rand.uniform(10000)}.txt")
      # Ensure doesn't exist
      File.rm(path)

      before_state = ActionVerifier.capture_state(:file_edit, path)
      assert before_state.exists == false

      # Create file
      File.write!(path, "new content")

      result = ActionVerifier.verify(:file_edit, path, before_state, {:ok, %{}})

      assert {:verified, details} = result
      assert details.outcome == :file_created
      assert details.new_length > 0

      File.rm(path)
    end

    test "handles action failure" do
      path = Path.join(@test_dir, "test_fail_#{:rand.uniform(10000)}.txt")
      before_state = ActionVerifier.capture_state(:file_edit, path)

      result = ActionVerifier.verify(:file_edit, path, before_state, {:error, "permission denied"})

      assert {:verified, details} = result
      assert details.outcome == :action_failed
      assert details.reason == "permission denied"
    end
  end

  describe "verify/4 - terminal" do
    test "verifies successful command" do
      before_state = ActionVerifier.capture_state(:terminal, "echo hello")

      result =
        ActionVerifier.verify(
          :terminal,
          "echo hello",
          before_state,
          {:ok, %{exit_code: 0, stdout: "hello\n"}}
        )

      assert {:verified, details} = result
      assert details.outcome == :command_succeeded
      assert details.exit_code == 0
    end

    test "verifies failed command" do
      before_state = ActionVerifier.capture_state(:terminal, "false")

      result =
        ActionVerifier.verify(
          :terminal,
          "false",
          before_state,
          {:ok, %{exit_code: 1, stderr: "error"}}
        )

      assert {:verified, details} = result
      assert details.outcome == :command_failed
      assert details.exit_code == 1
    end
  end

  describe "verify_tiered/4" do
    test "light tier only checks diff" do
      path = Path.join(@test_dir, "test_tier_light_#{:rand.uniform(10000)}.txt")
      File.write!(path, "before")

      before_state = ActionVerifier.capture_state(:file_edit, path)
      File.write!(path, "after")

      result = ActionVerifier.verify_tiered(path, before_state, {:ok, %{}}, :light)

      assert {:verified, details} = result
      assert details.tier == :light
      refute Map.has_key?(details, :compile_check)

      File.rm(path)
    end

    test "medium tier includes compile check for non-elixir" do
      path = Path.join(@test_dir, "test_tier_medium_#{:rand.uniform(10000)}.txt")
      File.write!(path, "before")

      before_state = ActionVerifier.capture_state(:file_edit, path)
      File.write!(path, "after")

      result = ActionVerifier.verify_tiered(path, before_state, {:ok, %{}}, :medium)

      assert {:verified, details} = result
      assert details.tier == :medium
      # Not an .ex file
      assert details.compile_check == :skipped

      File.rm(path)
    end
  end
end
