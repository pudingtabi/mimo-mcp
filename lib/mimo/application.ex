defmodule Mimo.Application do
  @moduledoc """
  OTP Application entry point.
  Note: Router starts LAST to prevent empty tool list.
  """
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      # Start Repo first
      Mimo.Repo,
      # Elixir Registry for via_tuple skill lookups (must be before Mimo.Registry)
      {Registry, keys: :unique, name: Mimo.Skills.Registry},
      # ETS-based registry for tool routing
      Mimo.Registry,
      # Task supervisor for async operations
      {Task.Supervisor, name: Mimo.TaskSupervisor},
      # Dynamic supervisor for skills
      {DynamicSupervisor, strategy: :one_for_one, name: Mimo.Skills.Supervisor},
    ]

    opts = [strategy: :one_for_one, name: Mimo.Supervisor]
    {:ok, sup} = Supervisor.start_link(children, opts)
    
    # Bootstrap skills FIRST
    Mimo.bootstrap_skills()
    
    # THEN start Router to ensure tool list is populated
    start_mcp_server(sup)
    
    Logger.info("Mimo-MCP Gateway v2.1 started on port #{Application.fetch_env!(:mimo_mcp, :mcp_port)}")
    {:ok, sup}
  end

  defp start_mcp_server(sup) do
    port = Application.fetch_env!(:mimo_mcp, :mcp_port)
    
    # Try to start with hermes_mcp if available
    child_spec = %{
      id: Mimo.McpServer,
      start: {Mimo.McpServer, :start_link, [[port: port]]},
      restart: :permanent
    }
    
    case Supervisor.start_child(sup, child_spec) do
      {:ok, _pid} -> :ok
      {:error, reason} ->
        Logger.warning("MCP Server start failed: #{inspect(reason)}, using fallback")
        # Fallback to simple TCP server if hermes not available
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
end
