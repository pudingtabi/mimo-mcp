defmodule MimoWeb.ToolController do
  @moduledoc """
  Controller for the /v1/mimo/tool endpoint.
  
  Provides direct, low-level execution of specific memory operations:
  - store_fact: Insert JSON-LD triples into Semantic Store
  - recall_procedure: Retrieve rules from Procedural Store
  - search_vibes: Vector similarity search in Episodic Store
  - mimo_reload_skills: Hot-reload Procedural Store from disk
  """
  use MimoWeb, :controller
  require Logger

  @doc """
  GET /v1/mimo/tools
  
  List all available tools with their schemas.
  """
  def index(conn, _params) do
    tools = Mimo.ToolInterface.list_tools()
    json(conn, %{tools: tools})
  end

  @doc """
  POST /v1/mimo/tool

  Request body:
    - tool: The tool name to execute (required)
    - arguments: Tool-specific arguments (required)

  Response:
    - tool_call_id: UUID for this tool call
    - status: "success" or "error"
    - data: Tool-specific response payload
  """
  def create(conn, params) do
    tool = Map.get(params, "tool")
    arguments = Map.get(params, "arguments", %{})
    sandbox_mode = Map.get(conn.assigns, :sandbox_mode, false)

    cond do
      is_nil(tool) or tool == "" ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Missing required parameter: tool"})

      sandbox_mode and tool in ["store_fact", "recall_procedure", "mimo_store_memory"] ->
        conn
        |> put_status(:forbidden)
        |> json(%{
          error: "Tool disabled in sandbox mode",
          tool: tool,
          sandbox_mode: true
        })

      true ->
        execute_tool(conn, tool, arguments)
    end
  end

  defp execute_tool(conn, tool, arguments) do
    {time_us, result} = :timer.tc(fn ->
      Mimo.ToolInterface.execute(tool, arguments)
    end)

    latency_ms = time_us / 1000

    # Emit telemetry for tool endpoint
    :telemetry.execute(
      [:mimo, :http, :tool],
      %{latency_ms: latency_ms},
      %{tool: tool}
    )

    if latency_ms > 50 do
      Logger.warning("Tool '#{tool}' latency exceeded 50ms: #{Float.round(latency_ms, 2)}ms")
    end

    case result do
      {:ok, data} ->
        json(conn, Map.put(data, :latency_ms, Float.round(latency_ms, 2)))

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          tool_call_id: UUID.uuid4(),
          status: "error",
          error: to_string(reason),
          latency_ms: Float.round(latency_ms, 2)
        })
    end
  end
end
