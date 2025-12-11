defmodule Mimo.CLI do
  @moduledoc """
  Entry point for the Burrito-wrapped binary.
  Parses command line arguments and starts the appropriate supervision tree.
  """

  def main(args) do
    # Parse arguments manually since we don't want a heavy CLI framework dependency
    case args do
      [] ->
        # Default: stdio mode (for MCP)
        start_stdio()

      ["stdio"] ->
        start_stdio()

      ["server" | server_args] ->
        start_server(server_args)

      ["help"] ->
        print_help()

      ["--help"] ->
        print_help()

      _ ->
        IO.puts(:stderr, "Unknown command. Use 'mimo help' for usage.")
        System.halt(1)
    end
  end

  defp start_stdio do
    # Ensure logging is silent
    :logger.set_primary_config(:level, :none)
    Application.put_env(:logger, :level, :none)

    {:ok, _} = Application.ensure_all_started(:mimo_mcp)

    # Wait for ToolRegistry to be ready before accepting MCP requests
    wait_for_tool_registry()

    Mimo.McpServer.Stdio.start()
  end

  defp wait_for_tool_registry(retries \\ 50) do
    case Process.whereis(Mimo.ToolRegistry) do
      nil when retries > 0 ->
        Process.sleep(100)
        wait_for_tool_registry(retries - 1)

      nil ->
        # Give up after 5 seconds, stdio will handle gracefully
        :ok

      _pid ->
        :ok
    end
  end

  defp start_server(args) do
    port = parse_port(args)

    # Override configuration with CLI args
    Application.put_env(:mimo_mcp, MimoWeb.Endpoint, http: [port: port])

    IO.puts("Starting Mimo Server on port #{port}...")

    {:ok, _} = Application.ensure_all_started(:mimo_mcp)

    # Keep the main process alive
    Process.sleep(:infinity)
  end

  defp parse_port(args) do
    case OptionParser.parse(args, strict: [port: :integer], aliases: [p: :port]) do
      {[port: p], _, _} -> p
      # Default port
      _ -> 4000
    end
  end

  defp print_help do
    IO.puts("""
    Mimo - Intelligent Agent Infrastructure

    Usage:
      mimo [command] [options]

    Commands:
      stdio           Start in MCP mode (JSON-RPC over stdin/stdout) - Default
      server          Start HTTP server
      help            Show this help message

    Options (server):
      -p, --port      HTTP port to listen on (default: 4000)

    Examples:
      mimo stdio      # Used by Claude/VS Code
      mimo server -p 8080
    """)
  end
end
