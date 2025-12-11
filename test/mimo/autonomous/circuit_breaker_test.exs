defmodule Mimo.Autonomous.CircuitBreakerTest do
  use ExUnit.Case, async: true

  alias Mimo.Autonomous.CircuitBreaker

  describe "new/1" do
    test "creates circuit in closed state" do
      circuit = CircuitBreaker.new()
      assert circuit.state == :closed
      assert circuit.consecutive_failures == 0
      assert circuit.last_failure_at == nil
    end

    test "accepts custom configuration" do
      circuit = CircuitBreaker.new(max_failures: 5, cooldown_ms: 60_000)
      assert circuit.config.max_failures == 5
      assert circuit.config.cooldown_ms == 60_000
    end
  end

  describe "check/1" do
    test "returns :closed for new circuit" do
      circuit = CircuitBreaker.new()
      assert {:closed, ^circuit} = CircuitBreaker.check(circuit)
    end

    test "returns :open for tripped circuit within cooldown" do
      circuit =
        CircuitBreaker.new(cooldown_ms: 60_000)
        |> CircuitBreaker.record_failure(:error1)
        |> CircuitBreaker.record_failure(:error2)
        |> CircuitBreaker.record_failure(:error3)

      assert circuit.state == :open
      assert {:open, _} = CircuitBreaker.check(circuit)
    end

    test "returns :half_open after cooldown elapsed" do
      # Create a circuit with very short cooldown for testing
      circuit = CircuitBreaker.new(cooldown_ms: 1)

      # Trip the circuit
      circuit =
        circuit
        |> CircuitBreaker.record_failure(:error1)
        |> CircuitBreaker.record_failure(:error2)
        |> CircuitBreaker.record_failure(:error3)

      assert circuit.state == :open

      # Wait for cooldown
      Process.sleep(5)

      # Check should transition to half-open
      assert {:half_open, updated} = CircuitBreaker.check(circuit)
      assert updated.state == :half_open
    end
  end

  describe "record_success/1" do
    test "resets consecutive failures in closed state" do
      circuit = CircuitBreaker.new()
      |> CircuitBreaker.record_failure(:error)
      |> CircuitBreaker.record_success()

      assert circuit.consecutive_failures == 0
      assert circuit.state == :closed
    end

    test "closes circuit from half-open after success threshold" do
      circuit = CircuitBreaker.new(cooldown_ms: 1, success_threshold: 1)

      # Trip the circuit
      circuit =
        circuit
        |> CircuitBreaker.record_failure(:error1)
        |> CircuitBreaker.record_failure(:error2)
        |> CircuitBreaker.record_failure(:error3)

      # Wait for cooldown and check to get half-open state
      Process.sleep(5)
      {:half_open, circuit} = CircuitBreaker.check(circuit)

      # Record success
      circuit = CircuitBreaker.record_success(circuit)

      assert circuit.state == :closed
      assert circuit.consecutive_failures == 0
    end
  end

  describe "record_failure/2" do
    test "increments consecutive failures" do
      circuit = CircuitBreaker.new()
      |> CircuitBreaker.record_failure(:error)

      assert circuit.consecutive_failures == 1
      assert circuit.state == :closed
    end

    test "opens circuit after max failures" do
      circuit = CircuitBreaker.new(max_failures: 3)

      circuit =
        circuit
        |> CircuitBreaker.record_failure(:error1)
        |> CircuitBreaker.record_failure(:error2)
        |> CircuitBreaker.record_failure(:error3)

      assert circuit.state == :open
      assert circuit.consecutive_failures == 3
      assert circuit.last_failure_at != nil
    end

    test "reopens circuit from half-open on failure" do
      circuit = CircuitBreaker.new(cooldown_ms: 1)

      # Trip and wait for half-open
      circuit =
        circuit
        |> CircuitBreaker.record_failure(:error1)
        |> CircuitBreaker.record_failure(:error2)
        |> CircuitBreaker.record_failure(:error3)

      Process.sleep(5)
      {:half_open, circuit} = CircuitBreaker.check(circuit)

      # Record failure in half-open state
      circuit = CircuitBreaker.record_failure(circuit, :another_error)

      assert circuit.state == :open
    end
  end

  describe "reset/1" do
    test "forces circuit to closed state" do
      circuit = CircuitBreaker.new()
      |> CircuitBreaker.record_failure(:error1)
      |> CircuitBreaker.record_failure(:error2)
      |> CircuitBreaker.record_failure(:error3)

      assert circuit.state == :open

      circuit = CircuitBreaker.reset(circuit)

      assert circuit.state == :closed
      assert circuit.consecutive_failures == 0
      assert circuit.last_failure_at == nil
    end
  end

  describe "status/1" do
    test "returns readable status map" do
      circuit = CircuitBreaker.new()
      status = CircuitBreaker.status(circuit)

      assert status.state == :closed
      assert status.consecutive_failures == 0
      assert status.last_failure_at == nil
      assert is_map(status.config)
    end

    test "includes remaining cooldown for open circuit" do
      circuit = CircuitBreaker.new(cooldown_ms: 60_000)
      |> CircuitBreaker.record_failure(:error1)
      |> CircuitBreaker.record_failure(:error2)
      |> CircuitBreaker.record_failure(:error3)

      status = CircuitBreaker.status(circuit)

      assert status.state == :open
      assert is_integer(status.remaining_cooldown_ms)
      assert status.remaining_cooldown_ms > 0
    end
  end
end
