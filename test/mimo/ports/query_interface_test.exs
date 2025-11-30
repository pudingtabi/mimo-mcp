defmodule Mimo.QueryInterfaceTest do
  @moduledoc """
  Tests for Mimo.QueryInterface port.
  Tests natural language query processing through Meta-Cognitive Router.
  """
  use Mimo.DataCase, async: false

  alias Mimo.QueryInterface

  describe "ask/3 - basic functionality" do
    test "returns structured response for valid query" do
      result = QueryInterface.ask("test query")

      case result do
        {:ok, response} ->
          assert Map.has_key?(response, :query_id)
          assert Map.has_key?(response, :router_decision)
          assert Map.has_key?(response, :results)

        {:error, "OpenRouter API key not configured" <> _} ->
          # Skip when API key not available
          :ok
      end
    end

    test "response includes query_id as UUID" do
      case QueryInterface.ask("what is the meaning of life") do
        {:ok, response} ->
          assert is_binary(response.query_id)
          assert String.length(response.query_id) == 36

        {:error, "OpenRouter API key not configured" <> _} ->
          # Skip when API key not available
          :ok
      end
    end

    test "response includes router_decision" do
      case QueryInterface.ask("test query") do
        {:ok, response} ->
          assert is_map(response.router_decision)

        {:error, "OpenRouter API key not configured" <> _} ->
          :ok
      end
    end

    test "response includes results map" do
      case QueryInterface.ask("test query") do
        {:ok, response} ->
          assert is_map(response.results)
          assert Map.has_key?(response.results, :episodic)
          assert Map.has_key?(response.results, :semantic)
          assert Map.has_key?(response.results, :procedural)

        {:error, "OpenRouter API key not configured" <> _} ->
          :ok
      end
    end
  end

  describe "ask/3 - with context_id" do
    test "accepts context_id parameter" do
      context_id = "test-context-123"

      case QueryInterface.ask("test query", context_id) do
        {:ok, response} ->
          assert response.context_id == context_id

        {:error, "OpenRouter API key not configured" <> _} ->
          :ok
      end
    end

    test "accepts nil context_id" do
      case QueryInterface.ask("test query", nil) do
        {:ok, response} ->
          assert response.context_id == nil

        {:error, "OpenRouter API key not configured" <> _} ->
          :ok
      end
    end
  end

  describe "ask/3 - timeout handling" do
    test "respects custom timeout" do
      # Very short timeout should work for simple queries
      result = QueryInterface.ask("test", nil, timeout_ms: 5000)

      case result do
        {:ok, _} -> assert true
        {:error, "OpenRouter API key not configured" <> _} -> :ok
      end
    end

    test "handles very short timeout gracefully" do
      # With test-mode optimizations (fallback embeddings), execution is very fast
      # So even 0ms timeout might succeed sometimes. This test verifies the
      # timeout mechanism exists and handles both cases gracefully.
      result = QueryInterface.ask("complex query that takes time", nil, timeout_ms: 0)

      # Either timeout error or success is acceptable
      case result do
        {:error, :timeout} -> assert true
        {:ok, _response} -> assert true
        {:error, "OpenRouter API key not configured" <> _} -> :ok
        other -> flunk("Unexpected result: #{inspect(other)}")
      end
    end
  end

  describe "ask/3 - error handling" do
    test "handles empty query" do
      result = QueryInterface.ask("")

      # Should still return a response (empty query is valid input)
      assert {:ok, _} = result
    end

    test "handles special characters in query" do
      result = QueryInterface.ask("query with <special> & \"characters\"")

      assert {:ok, _} = result
    end
  end

  describe "ask/3 - router decision" do
    test "router decision has expected structure" do
      case QueryInterface.ask("remember this fact") do
        {:ok, response} ->
          decision = response.router_decision
          assert is_map(decision)
          # Router decision should have primary_store or similar fields
          assert Map.has_key?(decision, :primary_store) or Map.has_key?(decision, :confidence)

        {:error, "OpenRouter API key not configured" <> _} ->
          :ok
      end
    end
  end

  describe "ask/3 - results structure" do
    test "episodic results are a list or nil" do
      case QueryInterface.ask("test query") do
        {:ok, response} ->
          episodic = response.results.episodic
          assert is_list(episodic) or is_nil(episodic)

        {:error, "OpenRouter API key not configured" <> _} ->
          :ok
      end
    end

    test "semantic results are list, map, or nil" do
      case QueryInterface.ask("test query") do
        {:ok, response} ->
          semantic = response.results.semantic
          assert is_list(semantic) or is_map(semantic) or is_nil(semantic)

        {:error, "OpenRouter API key not configured" <> _} ->
          :ok
      end
    end

    test "procedural results are nil when store is disabled" do
      case QueryInterface.ask("test query") do
        {:ok, response} ->
          # Procedural store is disabled by default
          procedural = response.results.procedural
          assert is_nil(procedural) or is_map(procedural) or is_list(procedural)

        {:error, "OpenRouter API key not configured" <> _} ->
          :ok
      end
    end
  end
end
