defmodule Mimo.McpServer do
  @moduledoc """
  MCP Server GenServer - manages server state and coordination.

  NOTE: The actual JSON-RPC 2.0 over stdio handling is implemented in
  `Mimo.McpServer.Stdio` which is invoked directly via:
    `mix run --no-halt -e "Mimo.McpServer.Stdio.start()"`

  This GenServer is started by the supervisor for:
  - Tool registry initialization
  - State management and coordination
  - HTTP/WebSocket adapter support (MimoWeb)

  It does NOT handle stdio I/O to avoid race conditions with Stdio module.
  """
  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, 9000)
    Logger.info("MCP Server initializing on port #{port}")
    {:ok, %{port: port}}
  end
end
