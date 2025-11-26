defmodule MimoWeb.HealthController do
  @moduledoc """
  Health check controller for load balancers and monitoring.
  """
  use MimoWeb, :controller

  @doc """
  GET /health

  Returns system health status including:
  - BEAM scheduler info
  - Memory usage
  - Tool catalog status
  """
  def check(conn, _params) do
    health = %{
      status: "healthy",
      version: Application.spec(:mimo_mcp, :vsn) |> to_string(),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      system: %{
        schedulers: :erlang.system_info(:schedulers_online),
        run_queue: :erlang.statistics(:total_run_queue_lengths_all),
        memory_mb: (:erlang.memory(:total) / (1024 * 1024)) |> Float.round(2)
      },
      stores: %{
        episodic: check_episodic_store(),
        semantic: "pending",
        procedural: "pending"
      },
      tools: %{
        count: length(Mimo.ToolRegistry.list_all_tools())
      }
    }

    json(conn, health)
  end

  defp check_episodic_store do
    try do
      Mimo.Brain.Memory.search_memories("health check", limit: 1)
      "healthy"
    rescue
      _ -> "error"
    end
  end
end
