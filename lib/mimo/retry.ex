defmodule Mimo.Retry do
  @moduledoc """
  Retry utilities with exponential backoff and jitter.

  Implements best practices for LLM API reliability:
  - Exponential backoff (doubles each attempt)
  - Random jitter (prevents thundering herd)
  - Configurable max retries and delays
  - Circuit breaker integration

  ## Usage

      # Simple retry
      Retry.with_backoff(fn ->
        make_llm_call()
      end)

      # Custom options
      Retry.with_backoff(fn ->
        make_llm_call()
      end, max_attempts: 5, base_delay: 2000)

  ## Configuration

  Environment variables:
  - `MIMO_RETRY_MAX_ATTEMPTS` - Maximum retry attempts (default: 3)
  - `MIMO_RETRY_BASE_DELAY` - Base delay in ms (default: 1000)
  - `MIMO_RETRY_MAX_DELAY` - Maximum delay in ms (default: 30000)
  - `MIMO_RETRY_JITTER_MAX` - Maximum jitter in ms (default: 500)
  """

  require Logger

  @default_max_attempts 3
  @default_base_delay 1_000
  @default_max_delay 30_000
  @default_jitter_max 500

  @doc """
  Execute a function with exponential backoff retry on failure.

  ## Options

    - `:max_attempts` - Maximum attempts (default: 3)
    - `:base_delay` - Base delay in milliseconds (default: 1000)
    - `:max_delay` - Maximum delay cap (default: 30000)
    - `:jitter_max` - Maximum random jitter (default: 500)
    - `:retryable` - Function to determine if error is retryable (default: rate limit and transport errors)

  ## Returns

    - `{:ok, result}` - Success result
    - `{:error, reason}` - Final error after all retries exhausted
  """
  @spec with_backoff(fun(), keyword()) :: {:ok, term()} | {:error, term()}
  def with_backoff(func, opts \\ []) do
    max_attempts = get_opt(opts, :max_attempts, @default_max_attempts)
    base_delay = get_opt(opts, :base_delay, @default_base_delay)
    max_delay = get_opt(opts, :max_delay, @default_max_delay)
    jitter_max = get_opt(opts, :jitter_max, @default_jitter_max)
    retryable_fn = Keyword.get(opts, :retryable, &default_retryable?/1)

    do_with_backoff(func, 1, max_attempts, base_delay, max_delay, jitter_max, retryable_fn, nil)
  end

  defp do_with_backoff(
         func,
         attempt,
         max_attempts,
         base_delay,
         max_delay,
         jitter_max,
         retryable_fn,
         _last_error
       ) do
    result = func.()

    handle_result(
      result,
      func,
      attempt,
      max_attempts,
      base_delay,
      max_delay,
      jitter_max,
      retryable_fn
    )
  end

  defp handle_result(
         {:ok, _} = success,
         _func,
         attempt,
         _max_attempts,
         _base_delay,
         _max_delay,
         _jitter_max,
         _retryable_fn
       ) do
    if attempt > 1, do: Logger.info("[Retry] Succeeded on attempt #{attempt}")
    success
  end

  defp handle_result(
         {:error, reason} = error,
         func,
         attempt,
         max_attempts,
         base_delay,
         max_delay,
         jitter_max,
         retryable_fn
       ) do
    handle_error(
      error,
      reason,
      func,
      attempt,
      max_attempts,
      base_delay,
      max_delay,
      jitter_max,
      retryable_fn
    )
  end

  defp handle_result(
         other,
         _func,
         _attempt,
         _max_attempts,
         _base_delay,
         _max_delay,
         _jitter_max,
         _retryable_fn
       ) do
    # Non-standard return, treat as success
    other
  end

  # All attempts exhausted
  defp handle_error(
         error,
         reason,
         _func,
         attempt,
         max_attempts,
         _base_delay,
         _max_delay,
         _jitter_max,
         _retryable_fn
       )
       when attempt >= max_attempts do
    Logger.warning(
      "[Retry] All #{max_attempts} attempts exhausted, final error: #{inspect(reason)}"
    )

    error
  end

  # More attempts available
  defp handle_error(
         error,
         reason,
         func,
         attempt,
         max_attempts,
         base_delay,
         max_delay,
         jitter_max,
         retryable_fn
       ) do
    if retryable_fn.(error) do
      retry_with_delay(
        func,
        attempt,
        max_attempts,
        base_delay,
        max_delay,
        jitter_max,
        retryable_fn,
        error,
        reason
      )
    else
      Logger.warning("[Retry] Error not retryable: #{inspect(reason)}")
      error
    end
  end

  defp retry_with_delay(
         func,
         attempt,
         max_attempts,
         base_delay,
         max_delay,
         jitter_max,
         retryable_fn,
         error,
         reason
       ) do
    delay = calculate_delay(attempt, base_delay, max_delay, jitter_max)

    Logger.warning(
      "[Retry] Attempt #{attempt}/#{max_attempts} failed (#{inspect(reason)}), retrying in #{delay}ms"
    )

    Process.sleep(delay)

    do_with_backoff(
      func,
      attempt + 1,
      max_attempts,
      base_delay,
      max_delay,
      jitter_max,
      retryable_fn,
      error
    )
  end

  @doc """
  Calculate delay with exponential backoff and jitter.

  Formula: min(base_delay * 2^(attempt-1) + random_jitter, max_delay)
  """
  @spec calculate_delay(pos_integer(), pos_integer(), pos_integer(), pos_integer()) :: pos_integer()
  def calculate_delay(attempt, base_delay, max_delay, jitter_max) do
    # Exponential: 1s, 2s, 4s, 8s, 16s...
    exponential = base_delay * :math.pow(2, attempt - 1)

    # Add random jitter (0 to jitter_max)
    jitter = :rand.uniform(jitter_max + 1) - 1

    # Cap at max_delay
    trunc(min(exponential + jitter, max_delay))
  end

  @doc """
  Check if an error is retryable.

  Retryable:
  - Rate limit errors (429)
  - Timeout/transport errors
  - Service unavailable (503)
  - Internal server errors (500, 502)

  Not retryable:
  - Client errors (400, 401, 403, 404)
  - Missing API keys
  - Invalid request format
  """
  @spec default_retryable?(term()) :: boolean()
  def default_retryable?(error) do
    case error do
      # Rate limiting - always retry
      {:error, {:rate_limited, _}} -> true
      {:error, {:cerebras_rate_limited, _}} -> true
      {:error, {:openrouter_rate_limited, _}} -> true
      {:error, {:openrouter_error, 429, _}} -> true
      {:error, {:cerebras_error, 429, _}} -> true
      # Server errors - usually transient
      {:error, {:openrouter_error, status, _}} when status in [500, 502, 503, 504] -> true
      {:error, {:cerebras_error, status, _}} when status in [500, 502, 503, 504] -> true
      {:error, {:groq_error, status, _}} when status in [500, 502, 503, 504] -> true
      # Transport/network errors - might be transient
      {:error, {:request_failed, :timeout}} -> true
      {:error, {:request_failed, :connect_timeout}} -> true
      {:error, {:request_failed, :closed}} -> true
      {:error, {:request_failed, {:tls_alert, _}}} -> true
      {:error, %Req.TransportError{}} -> true
      # Not retryable - API keys, auth, client errors
      {:error, :no_api_key} -> false
      {:error, :no_cerebras_key} -> false
      {:error, :no_openrouter_key} -> false
      {:error, {:openrouter_error, status, _}} when status in [400, 401, 403, 404] -> false
      {:error, {:cerebras_error, status, _}} when status in [400, 401, 403, 404] -> false
      # Unknown errors - conservative, don't retry
      _ -> false
    end
  end

  # Get option with environment variable fallback
  defp get_opt(opts, key, default) do
    Keyword.get_lazy(opts, key, fn ->
      env_key = "MIMO_RETRY_#{key |> to_string() |> String.upcase()}"

      case System.get_env(env_key) do
        nil ->
          default

        val ->
          case Integer.parse(val) do
            {int, _} when int > 0 -> int
            _ -> default
          end
      end
    end)
  end
end
