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
        semantic: check_semantic_store(),
        procedural: check_procedural_store()
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

  defp check_semantic_store do
    try do
      Mimo.Repo.query("SELECT 1 FROM semantic_triples LIMIT 1")
      "healthy"
    rescue
      _ -> "pending"
    end
  end

  defp check_procedural_store do
    try do
      Mimo.Repo.query("SELECT 1 FROM procedural_registry LIMIT 1")
      "healthy"
    rescue
      _ -> "pending"
    end
  end
end
