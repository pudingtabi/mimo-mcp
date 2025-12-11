defmodule Mimo.Fallback.GracefulDegradation do
  @moduledoc """
  Graceful degradation strategies for when external services fail.

  Provides fallback behaviors for:
  - LLM service failures → cached/default responses
  - Semantic store failures → episodic memory search
  - Database failures → in-memory cache
  - Embedding generation failures → hash-based vectors

  All fallback events are logged for monitoring.

  ## Retry Queue

  Failed operations can be queued for retry using `queue_for_retry/2`.
  The queue uses ETS for persistence within the current process lifecycle
  and implements exponential backoff with configurable max retries.

  Start the retry processor with `start_retry_processor/0` (called automatically
  by the application supervisor).
  """
  require Logger

  alias Mimo.ErrorHandling.CircuitBreaker

  # Retry configuration
  @retry_table :mimo_retry_queue
  @max_retries 3
  @base_delay_ms 1_000
  @max_delay_ms 30_000

  # ==========================================================================
  # Retry Queue Management
  # ==========================================================================

  @doc """
  Initialize the retry queue ETS table.
  Called during application startup.
  """
  def init_retry_queue do
    case :ets.whereis(@retry_table) do
      :undefined ->
        :ets.new(@retry_table, [:named_table, :public, :ordered_set])
        Logger.debug("Retry queue initialized")
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Start the retry processor that periodically checks and retries failed operations.
  Uses Task.Supervisor for proper supervision - crash recovery and visibility.
  """
  def start_retry_processor do
    init_retry_queue()

    case Mimo.TaskHelper.safe_start_child(fn -> retry_loop() end) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        require Logger
        Logger.warning("[GracefulDegradation] Failed to start retry processor: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp retry_loop do
    Process.sleep(5_000)

    try do
      process_retry_queue()
    rescue
      e ->
        Logger.error("Retry processor error: #{Exception.message(e)}")
    end

    retry_loop()
  end

  @doc """
  Process all pending retries that are due.
  """
  def process_retry_queue do
    now = System.monotonic_time(:millisecond)

    pending =
      try do
        :ets.select(@retry_table, [
          {{:"$1", :"$2"}, [{:"=<", :"$1", now}], [:"$2"]}
        ])
      rescue
        ArgumentError -> []
      end

    Enum.each(pending, fn entry ->
      execute_retry(entry, now)
    end)
  end

  defp execute_retry(%{id: id, db_fn: db_fn, attempt: attempt, opts: _opts} = entry, now) do
    Logger.info("Retry attempt #{attempt + 1}/#{@max_retries} for operation #{id}")

    try do
      case db_fn.() do
        {:ok, result} ->
          # Success - remove from queue
          delete_retry(entry.scheduled_at)
          Logger.info("Retry succeeded for #{id}")

          :telemetry.execute(
            [:mimo, :retry, :success],
            %{count: 1, attempts: attempt + 1},
            %{operation_id: id}
          )

          {:ok, result}

        {:error, reason} ->
          handle_retry_failure(entry, reason, now)
      end
    rescue
      e ->
        handle_retry_failure(entry, Exception.message(e), now)
    end
  end

  defp handle_retry_failure(%{id: id, attempt: attempt} = entry, reason, now) do
    delete_retry(entry.scheduled_at)

    if attempt + 1 < @max_retries do
      # Schedule next retry with exponential backoff
      delay = min((@base_delay_ms * :math.pow(2, attempt + 1)) |> round(), @max_delay_ms)
      new_entry = %{entry | attempt: attempt + 1, scheduled_at: now + delay}
      schedule_retry(new_entry)

      Logger.warning(
        "Retry #{attempt + 1} failed for #{id}, scheduling retry in #{delay}ms: #{inspect(reason)}"
      )
    else
      # Max retries exceeded - log to dead letter
      Logger.error("Operation #{id} failed after #{@max_retries} retries: #{inspect(reason)}")

      :telemetry.execute(
        [:mimo, :retry, :exhausted],
        %{count: 1, attempts: @max_retries},
        %{operation_id: id, reason: reason}
      )
    end
  end

  defp schedule_retry(%{scheduled_at: scheduled_at} = entry) do
    try do
      :ets.insert(@retry_table, {scheduled_at, entry})
    rescue
      ArgumentError ->
        init_retry_queue()
        :ets.insert(@retry_table, {scheduled_at, entry})
    end
  end

  defp delete_retry(scheduled_at) do
    try do
      :ets.delete(@retry_table, scheduled_at)
    rescue
      ArgumentError -> :ok
    end
  end

  @doc """
  Get retry queue statistics.
  """
  def retry_stats do
    try do
      size = :ets.info(@retry_table, :size) || 0

      entries =
        :ets.tab2list(@retry_table)
        |> Enum.map(fn {_, entry} -> entry end)

      %{
        pending: size,
        by_attempt: Enum.frequencies_by(entries, & &1.attempt),
        oldest: entries |> Enum.min_by(& &1.scheduled_at, fn -> nil end)
      }
    rescue
      _ -> %{pending: 0, by_attempt: %{}, oldest: nil}
    end
  end

  # ==========================================================================
  # LLM Fallback
  # ==========================================================================

  @doc """
  Execute LLM operation with fallback to cached/default response.

  ## Fallback chain:
  1. Try primary LLM (OpenRouter)
  2. Try cached response if available
  3. Return graceful error message
  """
  @spec with_llm_fallback(function(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def with_llm_fallback(llm_fn, opts \\ []) do
    cache_key = Keyword.get(opts, :cache_key)
    default_response = Keyword.get(opts, :default, "I'm unable to process this request right now.")

    case llm_fn.() do
      {:ok, response} = success ->
        # Cache successful response if key provided
        if cache_key, do: cache_response(cache_key, response)
        success

      {:error, :circuit_open} ->
        Logger.warning("LLM circuit open, using fallback")
        log_fallback_event(:llm, :circuit_open)
        get_cached_or_default(cache_key, default_response)

      {:error, :no_api_key} ->
        Logger.warning("No API key, using fallback")
        log_fallback_event(:llm, :no_api_key)
        get_cached_or_default(cache_key, default_response)

      {:error, reason} ->
        Logger.warning("LLM error: #{inspect(reason)}, using fallback")
        log_fallback_event(:llm, reason)
        get_cached_or_default(cache_key, default_response)
    end
  end

  # ==========================================================================
  # Semantic Store Fallback
  # ==========================================================================

  @doc """
  Query semantic store with fallback to episodic memory.

  ## Fallback chain:
  1. Try semantic store query
  2. Fall back to episodic memory search
  3. Return empty results with warning
  """
  @spec with_semantic_fallback(function(), function()) :: {:ok, list()} | {:error, term()}
  def with_semantic_fallback(semantic_fn, episodic_fn) do
    case semantic_fn.() do
      {:ok, results} = success when is_list(results) ->
        success

      {:error, reason} ->
        Logger.warning("Semantic store failed: #{inspect(reason)}, falling back to episodic")
        log_fallback_event(:semantic_store, reason)

        case episodic_fn.() do
          {:ok, results} = success ->
            Logger.info("Episodic fallback returned #{length(results)} results")
            success

          {:error, episodic_reason} ->
            Logger.error("Both semantic and episodic failed: #{inspect(episodic_reason)}")
            log_fallback_event(:episodic_store, episodic_reason)
            # Return empty rather than crash
            {:ok, []}
        end
    end
  end

  # ==========================================================================
  # Database Fallback
  # ==========================================================================

  @doc """
  Execute database operation with in-memory cache fallback.

  ## Fallback chain:
  1. Try database operation
  2. For reads: return cached data if available
  3. For writes: queue for retry
  """
  @spec with_db_fallback(function(), keyword()) :: {:ok, term()} | {:error, term()}
  def with_db_fallback(db_fn, opts \\ []) do
    operation_type = Keyword.get(opts, :type, :read)
    cache_key = Keyword.get(opts, :cache_key)

    case db_fn.() do
      {:ok, result} = success ->
        # Cache successful reads
        if operation_type == :read and cache_key do
          cache_response(cache_key, result)
        end

        success

      {:error, reason} ->
        Logger.warning("Database operation failed: #{inspect(reason)}")
        log_fallback_event(:database, reason)

        case operation_type do
          :read ->
            get_cached_or_error(cache_key, reason)

          :write ->
            # Queue write for later retry
            queue_for_retry(db_fn, opts)
            {:error, {:queued_for_retry, reason}}
        end
    end
  end

  # ==========================================================================
  # Embedding Fallback
  # ==========================================================================

  @doc """
  Generate an embedding with graceful fallback.

  - Tries primary embedding provider (LLM/Ollama via Mimo.Brain.LLM)
  - On failure or no API key, returns a deterministic hash-based embedding
    suitable for tests and non-critical flows.

  The hash-based embedding is seeded using `:erlang.phash2/2` and
  `:rand.seed(:exsss, {h, h*2, h*3})` to ensure determinism.

  Embedding dimension is read from `:mimo_mcp, :embedding_dim` (default: 1024).
  """
  @spec with_embedding_fallback(String.t()) :: {:ok, [float()]} | {:error, term()}
  def with_embedding_fallback(text) when is_binary(text) do
    case try_llm_embedding(text) do
      {:ok, embedding} ->
        {:ok, embedding}

      {:error, reason} ->
        Logger.warning("Embedding provider unavailable (#{inspect(reason)}); using hash fallback")
        log_fallback_event(:embedding, reason)
        generate_hash_embedding(text)
    end
  end

  defp try_llm_embedding(text) do
    # Prefer direct LLM embedding call; normalize error shapes
    case Mimo.Brain.LLM.get_embedding(text) do
      {:ok, embedding} when is_list(embedding) -> {:ok, embedding}
      {:error, :no_api_key} -> {:error, :no_api_key}
      {:error, other} -> {:error, other}
      other -> {:error, {:unexpected_response, other}}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp generate_hash_embedding(text) do
    dim = Application.get_env(:mimo_mcp, :embedding_dim, 1024)
    h = :erlang.phash2(text, 1_000_000)
    :rand.seed(:exsss, {h, h * 2, h * 3})
    embedding = for _ <- 1..dim, do: :rand.uniform() * 2 - 1
    {:ok, embedding}
  end

  # ==========================================================================
  # Circuit Breaker Status
  # ==========================================================================

  @doc """
  Check if a service is currently degraded (circuit open).
  """
  @spec service_degraded?(atom()) :: boolean()
  def service_degraded?(service) do
    case CircuitBreaker.status(service) do
      :open -> true
      :half_open -> true
      _ -> false
    end
  end

  @doc """
  Get degradation status for all services.
  """
  @spec degradation_status() :: map()
  def degradation_status do
    services = [:llm_service, :ollama, :database]

    Map.new(services, fn service ->
      {service,
       %{
         degraded: service_degraded?(service),
         status: CircuitBreaker.status(service)
       }}
    end)
  end

  # ==========================================================================
  # Private Helpers
  # ==========================================================================

  # Simple ETS-based cache (production should use proper caching)
  defp cache_response(key, value) do
    try do
      ensure_cache_table()
      :ets.insert(:mimo_fallback_cache, {key, value, System.monotonic_time(:second)})
    catch
      # Ignore cache failures
      _, _ -> :ok
    end
  end

  defp get_cached(key) do
    try do
      ensure_cache_table()

      case :ets.lookup(:mimo_fallback_cache, key) do
        [{^key, value, _timestamp}] -> {:ok, value}
        [] -> :miss
      end
    catch
      _, _ -> :miss
    end
  end

  defp get_cached_or_default(nil, default), do: {:ok, default}

  defp get_cached_or_default(key, default) do
    case get_cached(key) do
      {:ok, cached} -> {:ok, cached}
      :miss -> {:ok, default}
    end
  end

  defp get_cached_or_error(nil, reason), do: {:error, reason}

  defp get_cached_or_error(key, reason) do
    case get_cached(key) do
      {:ok, cached} -> {:ok, cached}
      :miss -> {:error, reason}
    end
  end

  defp ensure_cache_table do
    case :ets.whereis(:mimo_fallback_cache) do
      :undefined ->
        :ets.new(:mimo_fallback_cache, [:named_table, :public, :set])

      _ ->
        :ok
    end
  end

  defp queue_for_retry(db_fn, opts) do
    init_retry_queue()

    id = Keyword.get(opts, :id, "op_#{System.unique_integer([:positive])}")
    now = System.monotonic_time(:millisecond)

    entry = %{
      id: id,
      db_fn: db_fn,
      opts: opts,
      attempt: 0,
      scheduled_at: now + @base_delay_ms,
      created_at: now
    }

    schedule_retry(entry)

    Logger.info("Queued database operation for retry: #{id}")

    :telemetry.execute(
      [:mimo, :retry, :queued],
      %{count: 1},
      %{operation_id: id}
    )

    :ok
  end

  defp log_fallback_event(service, reason) do
    :telemetry.execute(
      [:mimo, :fallback, :triggered],
      %{count: 1},
      %{service: service, reason: reason, timestamp: DateTime.utc_now()}
    )
  end
end
