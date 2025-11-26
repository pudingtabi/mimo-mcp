defmodule MimoWeb.AskController do
  @moduledoc """
  Controller for the /v1/mimo/ask endpoint.

  Accepts natural language queries and routes them through the Meta-Cognitive Router
  to the appropriate Triad Stores (Episodic, Semantic, Procedural).
  """
  use MimoWeb, :controller
  require Logger

  @doc """
  POST /v1/mimo/ask

  Request body:
    - query: The natural language query (required)
    - context_id: Session/context identifier (optional)
    - timeout_ms: Query timeout in milliseconds (optional, default: 5000)

  Response:
    - query_id: UUID for this query
    - router_decision: Classification results from Meta-Cognitive Router
    - results: Results from each store (episodic, semantic, procedural)
    - latency_ms: Total processing time
  """
  def create(conn, params) do
    query = Map.get(params, "query")
    context_id = Map.get(params, "context_id")
    timeout_ms = Map.get(params, "timeout_ms", 5000)

    if is_nil(query) or query == "" do
      conn
      |> put_status(:bad_request)
      |> json(%{error: "Missing required parameter: query"})
    else
      {time_us, result} =
        :timer.tc(fn ->
          Mimo.QueryInterface.ask(query, context_id, timeout_ms: timeout_ms)
        end)

      latency_ms = time_us / 1000

      # Emit telemetry for ask endpoint
      :telemetry.execute(
        [:mimo, :http, :ask],
        %{latency_ms: latency_ms},
        %{context_id: context_id}
      )

      if latency_ms > 50 do
        Logger.warning("Ask latency exceeded 50ms: #{Float.round(latency_ms, 2)}ms")
      end

      case result do
        {:ok, data} ->
          json(conn, Map.put(data, :latency_ms, Float.round(latency_ms, 2)))

        {:error, :timeout} ->
          conn
          |> put_status(:gateway_timeout)
          |> json(%{
            error: "Query timed out",
            timeout_ms: timeout_ms,
            latency_ms: Float.round(latency_ms, 2)
          })

        {:error, reason} ->
          conn
          |> put_status(:internal_server_error)
          |> json(%{
            error: "Query failed",
            reason: to_string(reason),
            latency_ms: Float.round(latency_ms, 2)
          })
      end
    end
  end
end
