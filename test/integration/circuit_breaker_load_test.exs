defmodule Mimo.Integration.CircuitBreakerLoadTest do
  @moduledoc """
  Integration tests for CircuitBreaker under real failure scenarios.

  Tests state transitions:
  - :closed → :open after failure threshold
  - :open → :half_open after reset timeout
  - :half_open → :closed on success
  - :half_open → :open on failure
  - Concurrent failure handling
  """
  use ExUnit.Case, async: false

  alias Mimo.ErrorHandling.CircuitBreaker

  @moduletag :integration

  # Use shorter timeouts for testing
  @test_reset_timeout_ms 100
  @test_failure_threshold 3
  @test_half_open_max_calls 2

  setup do
    # Start the circuit breaker registry if not already started
    case Registry.start_link(keys: :unique, name: Mimo.CircuitBreaker.Registry) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Start a circuit breaker for testing with shorter timeouts
    circuit_name = :"test_circuit_#{:erlang.unique_integer([:positive])}"

    {:ok, _pid} =
      CircuitBreaker.start_link(
        name: circuit_name,
        failure_threshold: @test_failure_threshold,
        reset_timeout_ms: @test_reset_timeout_ms,
        half_open_max_calls: @test_half_open_max_calls
      )

    {:ok, circuit_name: circuit_name}
  end

  describe "CircuitBreaker state transitions" do
    test "starts in closed state", %{circuit_name: name} do
      assert CircuitBreaker.get_state(name) == :closed
    end

    test "opens after failure threshold reached", %{circuit_name: name} do
      # Record failures up to threshold
      for _ <- 1..@test_failure_threshold do
        CircuitBreaker.record_failure(name)
      end

      # Circuit should now be open
      assert CircuitBreaker.get_state(name) == :open
    end

    test "stays closed below failure threshold", %{circuit_name: name} do
      # Record failures below threshold
      for _ <- 1..(@test_failure_threshold - 1) do
        CircuitBreaker.record_failure(name)
      end

      # Circuit should still be closed
      assert CircuitBreaker.get_state(name) == :closed
    end

    test "transitions to half-open after reset timeout", %{circuit_name: name} do
      # Open the circuit
      for _ <- 1..@test_failure_threshold do
        CircuitBreaker.record_failure(name)
      end

      assert CircuitBreaker.get_state(name) == :open

      # Wait for reset timeout
      Process.sleep(@test_reset_timeout_ms + 50)

      # Should now be half-open
      assert CircuitBreaker.get_state(name) == :half_open
    end

    test "closes from half-open after successful calls", %{circuit_name: name} do
      # Open the circuit
      for _ <- 1..@test_failure_threshold do
        CircuitBreaker.record_failure(name)
      end

      # Wait for half-open
      Process.sleep(@test_reset_timeout_ms + 50)
      assert CircuitBreaker.get_state(name) == :half_open

      # Record successful calls
      for _ <- 1..@test_half_open_max_calls do
        CircuitBreaker.record_success(name)
      end

      # Should now be closed
      assert CircuitBreaker.get_state(name) == :closed
    end

    test "reopens from half-open on failure", %{circuit_name: name} do
      # Open the circuit
      for _ <- 1..@test_failure_threshold do
        CircuitBreaker.record_failure(name)
      end

      # Wait for half-open
      Process.sleep(@test_reset_timeout_ms + 50)
      assert CircuitBreaker.get_state(name) == :half_open

      # Record another failure - should trip back to open
      for _ <- 1..@test_failure_threshold do
        CircuitBreaker.record_failure(name)
      end

      assert CircuitBreaker.get_state(name) == :open
    end

    test "manual reset returns to closed state", %{circuit_name: name} do
      # Open the circuit
      for _ <- 1..@test_failure_threshold do
        CircuitBreaker.record_failure(name)
      end

      assert CircuitBreaker.get_state(name) == :open

      # Manual reset
      CircuitBreaker.reset(name)

      # Small delay for async cast to process
      Process.sleep(10)

      assert CircuitBreaker.get_state(name) == :closed
    end
  end

  describe "CircuitBreaker call/2 API" do
    test "executes function when circuit is closed", %{circuit_name: name} do
      result =
        CircuitBreaker.call(name, fn ->
          {:ok, "success"}
        end)

      assert result == {:ok, "success"}
    end

    test "returns :circuit_breaker_open when circuit is open", %{circuit_name: name} do
      # Open the circuit
      for _ <- 1..@test_failure_threshold do
        CircuitBreaker.record_failure(name)
      end

      result =
        CircuitBreaker.call(name, fn ->
          {:ok, "should not execute"}
        end)

      assert result == {:error, :circuit_breaker_open}
    end

    test "records failure on error result", %{circuit_name: name} do
      # Make calls that return errors
      for _ <- 1..@test_failure_threshold do
        CircuitBreaker.call(name, fn -> {:error, "test error"} end)
      end

      # Circuit should be open after threshold failures
      assert CircuitBreaker.get_state(name) == :open
    end

    test "records failure on exception", %{circuit_name: name} do
      # Make calls that raise exceptions
      for _ <- 1..@test_failure_threshold do
        result = CircuitBreaker.call(name, fn -> raise "test exception" end)
        assert match?({:error, {:exception, _}}, result)
      end

      # Circuit should be open after threshold failures
      assert CircuitBreaker.get_state(name) == :open
    end

    test "records success and decrements failure count", %{circuit_name: name} do
      # Record some failures (below threshold)
      for _ <- 1..(@test_failure_threshold - 1) do
        CircuitBreaker.record_failure(name)
      end

      # Record a success - should decrement failure count
      CircuitBreaker.call(name, fn -> {:ok, "success"} end)

      # Now one more failure shouldn't open the circuit
      CircuitBreaker.record_failure(name)
      assert CircuitBreaker.get_state(name) == :closed
    end
  end

  describe "CircuitBreaker under concurrent load" do
    test "handles concurrent failures correctly", %{circuit_name: name} do
      # Spawn many concurrent tasks that all fail
      tasks =
        for _ <- 1..100 do
          Task.async(fn ->
            CircuitBreaker.call(name, fn -> {:error, "concurrent failure"} end)
          end)
        end

      # Wait for all tasks to complete
      Task.await_many(tasks, 5000)

      # Circuit should be open (no race conditions)
      assert CircuitBreaker.get_state(name) == :open
    end

    test "handles concurrent successes correctly in half-open state", %{circuit_name: name} do
      # Open the circuit first
      for _ <- 1..@test_failure_threshold do
        CircuitBreaker.record_failure(name)
      end

      # Wait for half-open
      Process.sleep(@test_reset_timeout_ms + 50)
      assert CircuitBreaker.get_state(name) == :half_open

      # Spawn concurrent successful calls
      tasks =
        for _ <- 1..20 do
          Task.async(fn ->
            CircuitBreaker.call(name, fn -> {:ok, "success"} end)
          end)
        end

      Task.await_many(tasks, 5000)

      # Circuit should eventually close
      Process.sleep(50)
      state = CircuitBreaker.get_state(name)
      assert state in [:closed, :half_open]
    end

    test "handles mixed concurrent operations", %{circuit_name: name} do
      # Spawn a mix of operations
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            case rem(i, 3) do
              0 -> CircuitBreaker.record_failure(name)
              1 -> CircuitBreaker.record_success(name)
              2 -> CircuitBreaker.get_state(name)
            end
          end)
        end

      # Should complete without crashes
      results = Task.await_many(tasks, 5000)
      assert length(results) == 50
    end
  end

  describe "CircuitBreaker with nonexistent circuit" do
    test "get_state returns :closed for nonexistent circuit" do
      assert CircuitBreaker.get_state(:nonexistent_circuit) == :closed
    end

    test "record_failure silently succeeds for nonexistent circuit" do
      assert CircuitBreaker.record_failure(:nonexistent_circuit) == :ok
    end

    test "reset silently succeeds for nonexistent circuit" do
      assert CircuitBreaker.reset(:nonexistent_circuit) == :ok
    end
  end
end
