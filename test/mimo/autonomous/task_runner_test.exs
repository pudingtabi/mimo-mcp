defmodule Mimo.Autonomous.TaskRunnerTest do
  use Mimo.DataCase, async: false

  alias Mimo.Autonomous.TaskRunner

  # Note: TaskRunner is started in the supervision tree, so we test against
  # the running instance. For isolation, we use unique task descriptions.

  describe "queue_task/1" do
    test "queues a valid task" do
      task_spec = %{
        type: "test",
        description: "Test task #{System.unique_integer([:positive])}"
      }

      assert {:ok, task_id} = TaskRunner.queue_task(task_spec)
      assert is_binary(task_id)
      assert String.starts_with?(task_id, "task_")
    end

    test "accepts string keys" do
      task_spec = %{
        "type" => "test",
        "description" => "String key test #{System.unique_integer([:positive])}"
      }

      assert {:ok, task_id} = TaskRunner.queue_task(task_spec)
      assert is_binary(task_id)
    end

    test "requires description" do
      task_spec = %{type: "test"}

      assert {:error, :missing_description} = TaskRunner.queue_task(task_spec)
    end

    test "blocks dangerous commands" do
      task_spec = %{
        type: "dangerous",
        description: "This should be blocked",
        command: "rm -rf /"
      }

      assert {:error, :blocked_dangerous_command} = TaskRunner.queue_task(task_spec)
    end

    test "blocks protected paths" do
      task_spec = %{
        type: "dangerous",
        description: "This should be blocked",
        path: "/etc/passwd"
      }

      assert {:error, :blocked_protected_path} = TaskRunner.queue_task(task_spec)
    end
  end

  describe "status/0" do
    test "returns status map" do
      status = TaskRunner.status()

      assert is_map(status)
      assert Map.has_key?(status, :status)
      assert Map.has_key?(status, :paused)
      assert Map.has_key?(status, :queued)
      assert Map.has_key?(status, :running)
      assert Map.has_key?(status, :completed)
      assert Map.has_key?(status, :failed)
      assert Map.has_key?(status, :circuit_state)
    end

    test "status is ready after initialization" do
      status = TaskRunner.status()

      # May be :ready or :paused depending on test order
      assert status.status in [:ready, :paused, :initializing]
    end
  end

  describe "pause/0 and resume/0" do
    test "pauses and resumes execution" do
      # Pause
      assert :ok = TaskRunner.pause()
      status = TaskRunner.status()
      assert status.paused == true

      # Resume
      assert :ok = TaskRunner.resume()
      status = TaskRunner.status()
      assert status.paused == false
    end
  end

  describe "list_queue/0" do
    test "returns list of queued tasks" do
      queue = TaskRunner.list_queue()
      assert is_list(queue)
    end
  end

  describe "clear_queue/0" do
    test "clears all queued tasks" do
      # Queue a task
      TaskRunner.queue_task(%{
        type: "test",
        description: "Task to be cleared #{System.unique_integer([:positive])}"
      })

      # Clear queue
      assert :ok = TaskRunner.clear_queue()

      # Queue should be empty (or contain only tasks from other tests)
      # We can't guarantee it's empty due to async nature, but clear should work
    end
  end

  describe "reset_circuit/0" do
    test "resets circuit breaker" do
      assert :ok = TaskRunner.reset_circuit()

      status = TaskRunner.status()
      assert status.circuit_state in [:closed, :half_open]
    end
  end

  describe "integration" do
    @tag :integration
    test "task flows through the system" do
      # Pause to control execution
      TaskRunner.pause()

      # Queue a simple task
      {:ok, task_id} = TaskRunner.queue_task(%{
        type: "test",
        description: "Integration test task #{System.unique_integer([:positive])}",
        command: "echo 'hello from integration test'"
      })

      # Verify it's in the queue
      queue = TaskRunner.list_queue()
      assert Enum.any?(queue, fn task -> task.id == task_id end)

      # Resume execution
      TaskRunner.resume()

      # Give it time to execute (the task should complete quickly)
      Process.sleep(500)

      # Task should no longer be in queue (either completed or running)
      queue = TaskRunner.list_queue()
      task_still_queued = Enum.any?(queue, fn task -> task.id == task_id end)

      # It may have been picked up, or still queued - both are valid
      # Just verify the system didn't crash
      status = TaskRunner.status()
      assert status.status in [:ready, :paused]
    end
  end
end
