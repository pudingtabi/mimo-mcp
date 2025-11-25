defmodule Mimo.Application do
  @moduledoc """
  OTP Application entry point.
  Uses lazy-loading: tools advertised from catalog, processes spawn on-demand.
  
  Universal Aperture Architecture:
  - MCP Server (stdio) for GitHub Copilot compatibility
  - Phoenix HTTP endpoint for REST/OpenAI API access
  - Both adapters talk to the same Core via Port interfaces
  """
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      # Start Repo first
      Mimo.Repo,
      # Elixir Registry for via_tuple skill lookups
      {Registry, keys: :unique, name: Mimo.Skills.Registry},
      # ETS-based registry for tool routing
      Mimo.Registry,
      # Static tool catalog for lazy-loading (reads manifest)
      Mimo.Skills.Catalog,
      # Task supervisor for async operations
      {Task.Supervisor, name: Mimo.TaskSupervisor},
      # Dynamic supervisor for lazy-spawned skills
      {DynamicSupervisor, strategy: :one_for_one, name: Mimo.Skills.Supervisor},
      # Telemetry supervisor for metrics
      Mimo.Telemetry,
    ]

    opts = [strategy: :one_for_one, name: Mimo.Supervisor]
    {:ok, sup} = Supervisor.start_link(children, opts)
    
    # Ensure catalog is fully loaded before servers start
    wait_for_catalog_ready()
    
    # Start HTTP endpoint (Universal Aperture)
    start_http_endpoint(sup)
    
    # Start MCP server (stdio for GitHub Copilot)
    start_mcp_server(sup)
    
    Logger.info("Mimo-MCP Gateway v2.2 started (Universal Aperture mode)")
    Logger.info("  HTTP API: http://localhost:#{http_port()}")
    Logger.info("  MCP Server: stdio (port #{mcp_port()})")
    {:ok, sup}
  end

  defp start_http_endpoint(sup) do
    child_spec = {MimoWeb.Endpoint, []}
    
    case Supervisor.start_child(sup, child_spec) do
      {:ok, _pid} -> 
        Logger.info("✅ HTTP Gateway started on port #{http_port()}")
      {:error, reason} ->
        Logger.warning("⚠️ HTTP Gateway failed to start: #{inspect(reason)}")
    end
  end

  defp start_mcp_server(sup) do
    port = mcp_port()
    
    child_spec = %{
      id: Mimo.McpServer,
      start: {Mimo.McpServer, :start_link, [[port: port]]},
      restart: :permanent
    }
    
    case Supervisor.start_child(sup, child_spec) do
      {:ok, _pid} -> 
        Logger.info("✅ MCP Server started")
      {:error, reason} ->
        Logger.warning("MCP Server start failed: #{inspect(reason)}, using fallback")
        start_fallback_server(sup, port)
    end
  end

  defp start_fallback_server(sup, port) do
    child_spec = %{
      id: Mimo.McpServer.Fallback,
      start: {Mimo.McpServer.Fallback, :start_link, [[port: port]]},
      restart: :permanent
    }
    Supervisor.start_child(sup, child_spec)
  end

  # Block until catalog has loaded tools from manifest
  defp wait_for_catalog_ready do
    wait_for_catalog_ready(50)  # 50 retries * 100ms = 5 seconds max
  end

  defp wait_for_catalog_ready(0) do
    Logger.warning("⚠️ Catalog not ready after timeout, starting anyway")
    :ok
  end

  defp wait_for_catalog_ready(retries) do
    tools = Mimo.Skills.Catalog.list_tools()
    if length(tools) > 0 do
      Logger.info("✅ Catalog ready with #{length(tools)} tools")
      :ok
    else
      Process.sleep(100)
      wait_for_catalog_ready(retries - 1)
    end
  end

  defp http_port do
    Application.get_env(:mimo_mcp, MimoWeb.Endpoint)[:http][:port] || 4000
  end

  defp mcp_port do
    Application.fetch_env!(:mimo_mcp, :mcp_port)
  end
end
