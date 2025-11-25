defmodule Mimo.Application do
  @moduledoc """
  OTP Application entry point.
  Uses lazy-loading: tools advertised from catalog, processes spawn on-demand.
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
    ]

    opts = [strategy: :one_for_one, name: Mimo.Supervisor]
    {:ok, sup} = Supervisor.start_link(children, opts)
    
    # Ensure catalog is fully loaded before MCP server starts
    wait_for_catalog_ready()
    
    # Start MCP server (tools available immediately from catalog)
    start_mcp_server(sup)
    
    Logger.info("Mimo-MCP Gateway v2.1 started (lazy-loading mode)")
    {:ok, sup}
  end

  defp start_mcp_server(sup) do
    port = Application.fetch_env!(:mimo_mcp, :mcp_port)
    
    child_spec = %{
      id: Mimo.McpServer,
      start: {Mimo.McpServer, :start_link, [[port: port]]},
      restart: :permanent
    }
    
    case Supervisor.start_child(sup, child_spec) do
      {:ok, _pid} -> :ok
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
end
