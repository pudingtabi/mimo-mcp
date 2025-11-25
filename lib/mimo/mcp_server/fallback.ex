defmodule Mimo.McpServer.Fallback do
  @moduledoc """
  Fallback stdio-based MCP server if hermes_mcp is unavailable.
  """
  require Logger

  def start_link(opts) do
    port = Keyword.get(opts, :port, 9000)
    Logger.info("Starting fallback MCP server (stdio mode)")
    
    # Just start the main MCP server in stdio mode
    Mimo.McpServer.start_link(opts)
  end
end
