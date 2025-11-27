defmodule Mimo.ErrorHandling.RetryStrategies do
  @moduledoc """
  Retry strategies with exponential backoff and circuit breaker patterns.
  """
  require Logger

  @max_retries 3
  @base_delay_ms 1000
  @max_delay_ms 30_000
  @jitter_factor 0.1

  @doc """
  Executes operation with exponential backoff retry.

  ## Options
    - `:max_retries` - Maximum retry attempts (default: 3)
    - `:base_delay` - Base delay in ms (default: 1000)
    - `:on_retry` - Callback function on retry
  """
  @spec with_retry((-> {:ok, any()} | {:error, any()}), keyword()) :: {:ok, any()} | {:error, any()}
  def with_retry(operation, opts \\ []) when is_function(operation, 0) do
    max_retries = Keyword.get(opts, :max_retries, @max_retries)
    base_delay = Keyword.get(opts, :base_delay, @base_delay_ms)
    on_retry = Keyword.get(opts, :on_retry)

    do_retry(operation, 0, max_retries, base_delay, on_retry)
  end

  defp do_retry(operation, attempt, max_retries, base_delay, on_retry) do
    case operation.() do
      {:ok, result} ->
        {:ok, result}

      :ok ->
        :ok

      {:error, reason} = _error when attempt < max_retries ->
        delay = calculate_delay(attempt, base_delay)

        Logger.warning(
          "Operation failed (attempt #{attempt + 1}/#{max_retries}), retrying in #{delay}ms",
          error: inspect(reason),
          attempt: attempt + 1
        )

        if on_retry, do: on_retry.(attempt, reason)

        Process.sleep(delay)
        do_retry(operation, attempt + 1, max_retries, base_delay, on_retry)

      {:error, reason} = error ->
        Logger.error("Operation failed after #{max_retries} retries",
          error: inspect(reason)
        )

        error
    end
  end

  defp calculate_delay(attempt, base_delay) do
    base = base_delay * :math.pow(2, attempt)
    jitter = base * @jitter_factor * (:rand.uniform() - 0.5)
    round(min(base + jitter, @max_delay_ms))
  end

  @doc """
  Wraps operation with timeout protection.
  """
  @spec with_timeout((-> any()), non_neg_integer()) :: {:ok, any()} | {:error, :timeout}
  def with_timeout(operation, timeout_ms) when is_function(operation, 0) do
    task = Task.async(fn -> operation.() end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task) do
      {:ok, result} -> {:ok, result}
      nil -> {:error, :timeout}
    end
  end
end
