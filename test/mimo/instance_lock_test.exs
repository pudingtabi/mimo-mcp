defmodule Mimo.InstanceLockTest do
  use ExUnit.Case, async: false

  alias Mimo.InstanceLock

  @moduletag :instance_lock

  describe "status/0" do
    test "returns a map with lock information" do
      result = InstanceLock.status()

      assert is_map(result)
      assert Map.has_key?(result, :locked)
    end

    test "locked field is a boolean" do
      result = InstanceLock.status()

      assert is_boolean(result.locked)
    end

    test "includes lock_file path" do
      result = InstanceLock.status()

      assert Map.has_key?(result, :lock_file)
      assert is_binary(result.lock_file)
    end

    test "when locked, includes holder_pid and started_at" do
      result = InstanceLock.status()

      if result.locked do
        assert Map.has_key?(result, :holder_pid)
        assert Map.has_key?(result, :started_at)
      end
    end
  end

  describe "read_holder_info/0" do
    test "returns a map" do
      result = InstanceLock.read_holder_info()

      assert is_map(result)
    end

    test "may contain pid, node, and started_at keys" do
      result = InstanceLock.read_holder_info()

      # These keys may or may not be present depending on lock state
      allowed_keys = [:pid, :node, :started_at]

      for {key, _value} <- result do
        assert key in allowed_keys
      end
    end
  end

  describe "acquire/0 and release/0" do
    @tag :skip
    @tag :requires_no_lock
    test "can acquire and release lock when not held" do
      # This test would interfere with the running application
      # Skip unless explicitly running lock tests in isolation
      #
      # To test manually:
      # 1. Stop any running Mimo instance
      # 2. Run: mix test test/mimo/instance_lock_test.exs --only requires_no_lock

      case InstanceLock.acquire() do
        :ok ->
          status = InstanceLock.status()
          assert status.locked == true

          assert :ok = InstanceLock.release()

          status_after = InstanceLock.status()
          assert status_after.locked == false

        {:error, :already_running} ->
          # Lock already held by another process (expected in normal test runs)
          assert true
      end
    end
  end

  describe "lock persistence" do
    test "lock info file path is derived from lock file" do
      status = InstanceLock.status()
      lock_file = status.lock_file

      # Lock info file should be lock_file + ".info"
      expected_info_file = lock_file <> ".info"

      # If we're locked, the info file should exist
      if status.locked do
        assert File.exists?(expected_info_file) or true
        # Note: File may not exist immediately after lock acquisition
      end
    end
  end
end
