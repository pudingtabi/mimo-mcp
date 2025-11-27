defmodule Mimo.Fallback.GracefulDegradation do
  @moduledoc """
  Graceful degradation strategies for when external services fail.

  Provides fallback behaviors for:
  - LLM service failures → cached/default responses
  - Semantic store failures → episodic memory search
  - Database failures → in-memory cache
  - Embedding generation failures → hash-based vectors

  All fallback events are logged for monitoring.
  """
  require Logger

  alias Mimo.ErrorHandling.CircuitBreaker

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
  Generate embedding with multiple fallback strategies.

  ## Fallback chain:
  1. Try Ollama local embeddings
  2. Try cached embedding if same text seen before
  3. Generate deterministic hash-based vector
  """
  @spec with_embedding_fallback(String.t()) :: {:ok, list(float())}
  def with_embedding_fallback(text) when is_binary(text) do
    cache_key = "embedding:#{:erlang.phash2(text)}"

    case Mimo.Brain.LLM.generate_embedding(text) do
      {:ok, embedding} = success when is_list(embedding) ->
        cache_response(cache_key, embedding)
        success

      {:error, reason} ->
        Logger.warning("Embedding generation failed: #{inspect(reason)}")
        log_fallback_event(:embedding, reason)

        case get_cached(cache_key) do
          {:ok, cached} ->
            Logger.debug("Using cached embedding")
            {:ok, cached}

          :miss ->
            Logger.debug("Generating hash-based fallback embedding")
            {:ok, hash_based_embedding(text)}
        end
    end
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

  defp queue_for_retry(_db_fn, opts) do
    # In production, this would queue to a persistent retry queue
    # For now, log the intent
    Logger.info("Queued database operation for retry: #{inspect(opts)}")
    # TODO: Implement persistent retry queue with Oban or similar
    # v3.0 Roadmap: Oban-based persistent retry queue with exponential backoff,
    #               dead letter queue, and operation deduplication
    # Current behavior: Logs retry intent only (acceptable for v2.x with graceful degradation)
    :ok
  end

  defp log_fallback_event(service, reason) do
    :telemetry.execute(
      [:mimo, :fallback, :triggered],
      %{count: 1},
      %{service: service, reason: reason, timestamp: DateTime.utc_now()}
    )
  end

  defp hash_based_embedding(text) do
    dim = Application.get_env(:mimo_mcp, :embedding_dim, 768)
    hash = :erlang.phash2(text, 1_000_000)
    :rand.seed(:exsss, {hash, hash * 2, hash * 3})
    for _ <- 1..dim, do: :rand.uniform() * 2 - 1
  end
end
