defmodule Mimo.TimeoutConfig do
  @moduledoc """
  Centralized timeout configuration for Mimo operations.

  ## Timeout Hierarchy

  MCP operations follow a cascading timeout hierarchy. Outer timeouts should
  always be larger than inner timeouts to prevent race conditions.

  ```
  MCP Tool (300s) → Query (45s) → GenServer (15s) → DB/HTTP (10-30s)
  ```

  ## Configuration

  All timeouts can be overridden via environment variables:
  - `MIMO_TIMEOUT_MCP` - MCP tool execution timeout
  - `MIMO_TIMEOUT_QUERY` - Query interface timeout
  - `MIMO_TIMEOUT_GENSERVER` - Default GenServer call timeout
  - `MIMO_TIMEOUT_DATABASE` - Database operation timeout
  - `MIMO_TIMEOUT_EMBEDDING` - Embedding generation timeout
  - `MIMO_TIMEOUT_HTTP` - HTTP request timeout

  ## Usage

      # Use default timeout
      GenServer.call(server, message, TimeoutConfig.genserver_default())

      # Use with environment override
      timeout = TimeoutConfig.get(:query)
  """

  # MCP tool execution outer limit (5 minutes for long-running commands like mix test)
  @mcp_tool_timeout 300_000

  # Complex query operations (ask_mimo, prepare_context)
  @query_timeout 45_000

  # Default GenServer call timeout (increased from 5s)
  @genserver_default 15_000

  # Database operations
  @database_timeout 10_000

  # Embedding generation (Ollama, OpenRouter)
  @embedding_timeout 30_000

  # HTTP requests (general)
  @http_timeout 30_000

  # HTTP connection establishment timeout (fast fail for unreachable hosts)
  @connect_timeout 5_000

  # LLM API request timeout (longer for cloud LLM providers)
  @llm_timeout 45_000

  # LLM synthesis timeout (shorter than query to allow graceful degradation)
  @llm_synthesis_timeout 25_000

  # Short operations (cache lookups, simple checks)
  @short_timeout 5_000

  @doc "MCP tool execution timeout (300s / 5 minutes)"
  @spec mcp_tool_timeout() :: pos_integer()
  def mcp_tool_timeout, do: get(:mcp, @mcp_tool_timeout)

  @doc "Query interface timeout (45s)"
  @spec query_timeout() :: pos_integer()
  def query_timeout, do: get(:query, @query_timeout)

  @doc "Default GenServer call timeout (15s)"
  @spec genserver_default() :: pos_integer()
  def genserver_default, do: get(:genserver, @genserver_default)

  @doc "Database operation timeout (10s)"
  @spec database_timeout() :: pos_integer()
  def database_timeout, do: get(:database, @database_timeout)

  @doc "Embedding generation timeout (30s)"
  @spec embedding_timeout() :: pos_integer()
  def embedding_timeout, do: get(:embedding, @embedding_timeout)

  @doc "HTTP request timeout (30s)"
  @spec http_timeout() :: pos_integer()
  def http_timeout, do: get(:http, @http_timeout)

  @doc "HTTP connect timeout (5s - fast fail for unreachable hosts)"
  @spec connect_timeout() :: pos_integer()
  def connect_timeout, do: get(:connect, @connect_timeout)

  @doc "LLM API request timeout (45s - longer for cloud providers)"
  @spec llm_timeout() :: pos_integer()
  def llm_timeout, do: get(:llm, @llm_timeout)

  @doc "LLM synthesis timeout (25s - shorter than query to allow graceful degradation)"
  @spec llm_synthesis_timeout() :: pos_integer()
  def llm_synthesis_timeout, do: get(:llm_synthesis, @llm_synthesis_timeout)

  @doc "Short operation timeout (5s)"
  @spec short_timeout() :: pos_integer()
  def short_timeout, do: get(:short, @short_timeout)

  @doc """
  Get timeout with environment override support.

  Environment variables follow the pattern: `MIMO_TIMEOUT_{TYPE}`

  ## Examples

      iex> TimeoutConfig.get(:query)
      45000

      # With MIMO_TIMEOUT_QUERY=60000 set
      iex> TimeoutConfig.get(:query)
      60000

      # With explicit default
      iex> TimeoutConfig.get(:custom, 10_000)
      10000
  """
  @spec get(atom(), pos_integer() | nil) :: pos_integer()
  def get(type, default \\ nil) do
    env_key = "MIMO_TIMEOUT_#{type |> to_string() |> String.upcase()}"

    case System.get_env(env_key) do
      nil ->
        default || default_for(type)

      val ->
        case Integer.parse(val) do
          {int, _} when int > 0 -> int
          _ -> default || default_for(type)
        end
    end
  end

  # Default values by type
  defp default_for(:mcp), do: @mcp_tool_timeout
  defp default_for(:query), do: @query_timeout
  defp default_for(:genserver), do: @genserver_default
  defp default_for(:database), do: @database_timeout
  defp default_for(:embedding), do: @embedding_timeout
  defp default_for(:http), do: @http_timeout
  defp default_for(:connect), do: @connect_timeout
  defp default_for(:llm), do: @llm_timeout
  defp default_for(:llm_synthesis), do: @llm_synthesis_timeout
  defp default_for(:short), do: @short_timeout
  defp default_for(_), do: @genserver_default
end
