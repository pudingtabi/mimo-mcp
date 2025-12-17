defmodule Mimo.ErrorHandling.RetryStrategiesTest do
  use ExUnit.Case, async: true

  alias Mimo.ErrorHandling.RetryStrategies

  describe "with_retry/2" do
    test "returns immediately on success" do
      call_count = :counters.new(1, [])

      result =
        RetryStrategies.with_retry(fn ->
          :counters.add(call_count, 1, 1)
          {:ok, "success"}
        end)

      assert result == {:ok, "success"}
      assert :counters.get(call_count, 1) == 1
    end

    test "retries on failure" do
      call_count = :counters.new(1, [])

      result =
        RetryStrategies.with_retry(
          fn ->
            count = :counters.get(call_count, 1)
            :counters.add(call_count, 1, 1)

            if count < 2 do
              {:error, :temporary_failure}
            else
              {:ok, "eventually succeeded"}
            end
          end,
          max_retries: 5,
          base_delay: 10
        )

      assert result == {:ok, "eventually succeeded"}
      assert :counters.get(call_count, 1) == 3
    end

    test "gives up after max retries" do
      call_count = :counters.new(1, [])

      result =
        RetryStrategies.with_retry(
          fn ->
            :counters.add(call_count, 1, 1)
            {:error, :permanent_failure}
          end,
          max_retries: 3,
          base_delay: 10
        )

      assert result == {:error, :permanent_failure}
      # Initial + 3 retries
      assert :counters.get(call_count, 1) == 4
    end

    test "calls on_retry callback" do
      retry_attempts = :counters.new(1, [])

      RetryStrategies.with_retry(
        fn ->
          {:error, :fail}
        end,
        max_retries: 2,
        base_delay: 10,
        on_retry: fn _attempt, _reason ->
          :counters.add(retry_attempts, 1, 1)
        end
      )

      assert :counters.get(retry_attempts, 1) == 2
    end
  end

  describe "with_timeout/2" do
    test "returns result within timeout" do
      result =
        RetryStrategies.with_timeout(
          fn ->
            Process.sleep(10)
            {:ok, "done"}
          end,
          1000
        )

      assert result == {:ok, {:ok, "done"}}
    end

    test "returns timeout error when exceeded" do
      result =
        RetryStrategies.with_timeout(
          fn ->
            Process.sleep(1000)
            {:ok, "done"}
          end,
          50
        )

      assert result == {:error, :timeout}
    end
  end
end
