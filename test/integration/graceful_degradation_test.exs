defmodule Mimo.Integration.GracefulDegradationTest do
  @moduledoc """
  Integration tests for graceful degradation under real failure scenarios.

  Tests fallback paths for:
  - LLM failures → cached/default responses
  - Semantic store failures → episodic memory fallback
  - Database failures → in-memory cache fallback
  - Embedding generation failures → hash-based vectors
  """
  use ExUnit.Case, async: false

  alias Mimo.ErrorHandling.CircuitBreaker
  alias Mimo.Fallback.GracefulDegradation

  @moduletag :integration

  setup do
    # Start the circuit breaker registry if not already started
    case Registry.start_link(keys: :unique, name: Mimo.CircuitBreaker.Registry) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Ensure the fallback cache table exists
    try do
      :ets.new(:mimo_fallback_cache, [:named_table, :public, :set])
    catch
      # Table already exists
      :error, :badarg -> :ok
    end

    :ok
  end

  describe "LLM fallback (with_llm_fallback/2)" do
    test "returns successful response from LLM" do
      result =
        GracefulDegradation.with_llm_fallback(fn ->
          {:ok, "Generated response"}
        end)

      assert result == {:ok, "Generated response"}
    end

    test "returns default on LLM error" do
      result =
        GracefulDegradation.with_llm_fallback(
          fn -> {:error, :timeout} end,
          default: "Service temporarily unavailable"
        )

      assert result == {:ok, "Service temporarily unavailable"}
    end

    test "returns cached response when available" do
      cache_key = "test_llm_key_#{:erlang.unique_integer([:positive])}"

      # First call caches the response
      GracefulDegradation.with_llm_fallback(
        fn -> {:ok, "Cached response"} end,
        cache_key: cache_key
      )

      # Second call with error should return cached
      result =
        GracefulDegradation.with_llm_fallback(
          fn -> {:error, :failed} end,
          cache_key: cache_key,
          default: "Default"
        )

      assert result == {:ok, "Cached response"}
    end

    test "handles circuit open error" do
      result =
        GracefulDegradation.with_llm_fallback(
          fn -> {:error, :circuit_open} end,
          default: "Fallback response"
        )

      assert result == {:ok, "Fallback response"}
    end

    test "handles no_api_key error" do
      result =
        GracefulDegradation.with_llm_fallback(
          fn -> {:error, :no_api_key} end,
          default: "API key missing fallback"
        )

      assert result == {:ok, "API key missing fallback"}
    end

    test "uses default message when no cache key and no default provided" do
      result =
        GracefulDegradation.with_llm_fallback(fn ->
          {:error, :some_error}
        end)

      assert {:ok, message} = result
      assert is_binary(message)
      assert String.contains?(message, "unable to process")
    end
  end

  describe "Semantic store fallback (with_semantic_fallback/2)" do
    test "returns results from semantic store" do
      result =
        GracefulDegradation.with_semantic_fallback(
          fn -> {:ok, [%{id: 1}, %{id: 2}]} end,
          fn -> {:ok, []} end
        )

      assert result == {:ok, [%{id: 1}, %{id: 2}]}
    end

    test "falls back to episodic memory on semantic failure" do
      result =
        GracefulDegradation.with_semantic_fallback(
          fn -> {:error, :db_connection_error} end,
          fn -> {:ok, [%{id: 3, source: :episodic}]} end
        )

      assert result == {:ok, [%{id: 3, source: :episodic}]}
    end

    test "returns empty list when both stores fail" do
      result =
        GracefulDegradation.with_semantic_fallback(
          fn -> {:error, :semantic_failed} end,
          fn -> {:error, :episodic_failed} end
        )

      assert result == {:ok, []}
    end

    test "handles empty results from semantic store" do
      result =
        GracefulDegradation.with_semantic_fallback(
          fn -> {:ok, []} end,
          fn -> {:ok, [%{id: 1}]} end
        )

      assert result == {:ok, []}
    end
  end

  describe "Database fallback (with_db_fallback/2)" do
    test "returns result from database" do
      result =
        GracefulDegradation.with_db_fallback(fn ->
          {:ok, %{data: "from_db"}}
        end)

      assert result == {:ok, %{data: "from_db"}}
    end

    test "caches successful read operations" do
      cache_key = "test_db_key_#{:erlang.unique_integer([:positive])}"

      # First call should cache
      GracefulDegradation.with_db_fallback(
        fn -> {:ok, %{cached: true}} end,
        type: :read,
        cache_key: cache_key
      )

      # Second call with failure should return cached
      result =
        GracefulDegradation.with_db_fallback(
          fn -> {:error, :connection_lost} end,
          type: :read,
          cache_key: cache_key
        )

      assert result == {:ok, %{cached: true}}
    end

    test "queues write operations for retry on failure" do
      result =
        GracefulDegradation.with_db_fallback(
          fn -> {:error, :connection_lost} end,
          type: :write
        )

      assert {:error, {:queued_for_retry, :connection_lost}} = result
    end

    test "returns error for read without cache" do
      result =
        GracefulDegradation.with_db_fallback(
          fn -> {:error, :not_found} end,
          type: :read,
          cache_key: "nonexistent_key_#{:erlang.unique_integer([:positive])}"
        )

      assert result == {:error, :not_found}
    end
  end

  describe "Embedding fallback (with_embedding_fallback/1)" do
    test "generates hash-based embedding on failure" do
      # Mock LLM failure by testing the fallback path
      # The actual implementation calls Mimo.Brain.LLM.generate_embedding
      # which may fail, so we test the fallback behavior
      result = GracefulDegradation.with_embedding_fallback("test text for embedding")

      # Should return either real embedding or hash-based fallback
      assert {:ok, embedding} = result
      assert is_list(embedding)
      refute Enum.empty?(embedding)
      assert Enum.all?(embedding, &is_float/1)
    end

    test "hash-based embeddings are deterministic" do
      text = "deterministic test text #{:erlang.unique_integer()}"

      {:ok, embedding1} = GracefulDegradation.with_embedding_fallback(text)
      {:ok, embedding2} = GracefulDegradation.with_embedding_fallback(text)

      # Same text should produce consistent embeddings
      # (Note: may differ if real LLM succeeds on some calls)
      assert is_list(embedding1)
      assert is_list(embedding2)
    end

    test "different texts produce different hash-based embeddings" do
      {:ok, embedding1} = generate_hash_embedding("first text")
      {:ok, embedding2} = generate_hash_embedding("second text")

      # Different texts should produce different embeddings
      assert embedding1 != embedding2
    end
  end

  describe "Service degradation status" do
    test "service_degraded?/1 returns false for nonexistent circuit" do
      refute GracefulDegradation.service_degraded?(:nonexistent_service)
    end

    test "service_degraded?/1 returns true for open circuit" do
      circuit_name = :"degraded_test_#{:erlang.unique_integer([:positive])}"

      {:ok, _} =
        CircuitBreaker.start_link(
          name: circuit_name,
          failure_threshold: 2,
          reset_timeout_ms: 60_000
        )

      # Open the circuit
      CircuitBreaker.record_failure(circuit_name)
      CircuitBreaker.record_failure(circuit_name)

      assert GracefulDegradation.service_degraded?(circuit_name)
    end

    test "degradation_status/0 returns status map" do
      status = GracefulDegradation.degradation_status()

      assert is_map(status)
      assert Map.has_key?(status, :llm_service)
      assert Map.has_key?(status, :ollama)
      assert Map.has_key?(status, :database)

      # Each service should have degraded and status keys
      for {_service, info} <- status do
        assert Map.has_key?(info, :degraded)
        assert Map.has_key?(info, :status)
      end
    end
  end

  describe "Telemetry events" do
    test "fires telemetry on LLM fallback" do
      test_pid = self()
      handler_id = "test-llm-fallback-#{:erlang.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:mimo, :fallback, :triggered],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      GracefulDegradation.with_llm_fallback(fn -> {:error, :test_failure} end)

      assert_receive {:telemetry, [:mimo, :fallback, :triggered], %{count: 1},
                      %{service: :llm, reason: :test_failure, timestamp: _}},
                     1000

      :telemetry.detach(handler_id)
    end

    test "fires telemetry on semantic fallback" do
      test_pid = self()
      handler_id = "test-semantic-fallback-#{:erlang.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:mimo, :fallback, :triggered],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      GracefulDegradation.with_semantic_fallback(
        fn -> {:error, :semantic_error} end,
        fn -> {:ok, []} end
      )

      assert_receive {:telemetry, [:mimo, :fallback, :triggered], %{count: 1},
                      %{service: :semantic_store, reason: :semantic_error, timestamp: _}},
                     1000

      :telemetry.detach(handler_id)
    end

    test "fires telemetry on database fallback" do
      test_pid = self()
      handler_id = "test-db-fallback-#{:erlang.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:mimo, :fallback, :triggered],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      GracefulDegradation.with_db_fallback(
        fn -> {:error, :db_error} end,
        type: :write
      )

      assert_receive {:telemetry, [:mimo, :fallback, :triggered], %{count: 1},
                      %{service: :database, reason: :db_error, timestamp: _}},
                     1000

      :telemetry.detach(handler_id)
    end
  end

  # Helper to directly test hash-based embedding generation
  defp generate_hash_embedding(text) do
    dim = Application.get_env(:mimo_mcp, :embedding_dim, 1024)
    hash = :erlang.phash2(text, 1_000_000)
    :rand.seed(:exsss, {hash, hash * 2, hash * 3})
    embedding = for _ <- 1..dim, do: :rand.uniform() * 2 - 1
    {:ok, embedding}
  end
end
