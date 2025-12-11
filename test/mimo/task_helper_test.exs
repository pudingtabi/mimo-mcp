defmodule Mimo.TaskHelperTest do
  use ExUnit.Case, async: false
  
  alias Mimo.TaskHelper
  
  describe "safe_start_child/1" do
    test "returns {:ok, pid} when TaskSupervisor is available" do
      assert {:ok, pid} = TaskHelper.safe_start_child(fn -> :ok end)
      assert is_pid(pid)
    end
    
    test "task executes successfully" do
      parent = self()
      
      {:ok, _pid} = TaskHelper.safe_start_child(fn -> 
        send(parent, :task_executed)
        :done
      end)
      
      assert_receive :task_executed, 1000
    end
    
    test "propagates $callers for Ecto sandbox" do
      parent = self()
      Process.put(:"$callers", [self()])
      
      {:ok, _pid} = TaskHelper.safe_start_child(fn ->
        callers = Process.get(:"$callers", [])
        send(parent, {:callers, callers})
      end)
      
      assert_receive {:callers, callers}, 1000
      assert parent in callers
    end
  end
  
  describe "safe_start_child/2 with custom supervisor" do
    test "returns {:error, :supervisor_unavailable} for non-existent supervisor" do
      assert {:error, :supervisor_unavailable} = 
        TaskHelper.safe_start_child(:non_existent_supervisor, fn -> :ok end)
    end
  end
  
  describe "supervisor_available?/1" do
    test "returns true for running TaskSupervisor" do
      assert TaskHelper.supervisor_available?(Mimo.TaskSupervisor)
    end
    
    test "returns false for non-existent supervisor" do
      refute TaskHelper.supervisor_available?(:fake_supervisor)
    end
    
    test "works with pid" do
      {:ok, sup} = Task.Supervisor.start_link()
      assert TaskHelper.supervisor_available?(sup)
      
      Supervisor.stop(sup)
      Process.sleep(50)
      refute TaskHelper.supervisor_available?(sup)
    end
  end
  
  describe "async_with_callers/1" do
    test "returns a Task" do
      task = TaskHelper.async_with_callers(fn -> 42 end)
      assert %Task{} = task
      assert Task.await(task) == 42
    end
    
    test "propagates $callers" do
      Process.put(:"$callers", [self()])
      parent = self()
      
      task = TaskHelper.async_with_callers(fn ->
        Process.get(:"$callers", [])
      end)
      
      callers = Task.await(task)
      assert parent in callers
    end
  end
  
  describe "async_nolink_with_callers/1" do
    test "doesn't crash caller on task failure" do
      task = TaskHelper.async_nolink_with_callers(fn ->
        raise "intentional failure"
      end)
      
      # Should get exit instead of crashing
      result = Task.yield(task, 100) || Task.shutdown(task)
      assert {:exit, _} = result
    end
  end
end
