defmodule MimoWeb.HealthController do
  @moduledoc """
  Health check controller for load balancers and monitoring (SPEC-061).

  Provides endpoints:
  - `/health` - Full health check with all subsystem status
  - `/health/ready` - Kubernetes readiness probe
  - `/health/live` - Kubernetes liveness probe
  - `/health/startup` - TASK 3: Startup health dashboard showing service initialization
  """
  use MimoWeb, :controller

  alias Mimo.Brain.Memory
  alias Mimo.Brain.HnswIndex
  alias Mimo.Fallback.ServiceRegistry

  @doc """
  GET /health/startup

  TASK 3 - Startup Health Dashboard (Dec 6 2025 Incident Response)

  Returns supervision tree initialization status in real-time:
  - Which services are started/ready/degraded/failed
  - Initialization duration for each service
  - Dependency graph information
  - Overall startup health

  This endpoint is safe to call during startup - uses defensive checks.
  """
  def startup(conn, _params) do
    startup_health = ServiceRegistry.startup_health()

    # Add supervision tree info
    supervisor_info = get_supervisor_info()

    # Add circuit breaker status
    circuit_breaker_status = get_circuit_breaker_status()

    response = %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      uptime_seconds: get_uptime(),
      overall: %{
        healthy: startup_health.healthy,
        total_services: startup_health.total,
        ready: startup_health.ready,
        degraded: startup_health.degraded,
        failed: startup_health.failed,
        pending: startup_health.pending
      },
      services: format_services(startup_health.services),
      supervision_tree: supervisor_info,
      circuit_breakers: circuit_breaker_status,
      recommendations: generate_recommendations(startup_health)
    }

    http_status = if startup_health.healthy, do: 200, else: 503

    conn
    |> put_status(http_status)
    |> json(response)
  end

  @doc """
  GET /health

  Returns comprehensive system health status including:
  - BEAM scheduler info
  - Memory usage
  - Database connectivity
  - Ollama status
  - HNSW index status
  - Memory count and cache stats
  """
  def check(conn, _params) do
    checks = %{
      database: check_database(),
      ollama: check_ollama(),
      hnsw: check_hnsw(),
      episodic: check_episodic_store(),
      semantic: check_semantic_store(),
      procedural: check_procedural_store()
    }

    # Determine overall status
    all_healthy = Enum.all?(Map.values(checks), &(&1 in [:ok, "healthy", "pending"]))
    status = if all_healthy, do: "healthy", else: "degraded"
    http_status = if all_healthy, do: 200, else: 503

    health = %{
      status: status,
      version: Application.spec(:mimo_mcp, :vsn) |> to_string(),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      uptime_seconds: get_uptime(),
      system: %{
        schedulers: :erlang.system_info(:schedulers_online),
        run_queue: :erlang.statistics(:total_run_queue_lengths_all),
        memory_mb: Float.round(:erlang.memory(:total) / (1024 * 1024), 2),
        process_count: :erlang.system_info(:process_count),
        port_count: :erlang.system_info(:port_count)
      },
      stores: %{
        episodic: checks.episodic,
        semantic: checks.semantic,
        procedural: checks.procedural
      },
      components: %{
        database: format_status(checks.database),
        ollama: format_status(checks.ollama),
        hnsw: format_status(checks.hnsw)
      },
      metrics: %{
        memory_count: get_memory_count(),
        hnsw_index_size: get_hnsw_size(),
        embedding_cache: get_cache_stats(),
        tools_count: length(Mimo.ToolRegistry.list_all_tools())
      }
    }

    conn
    |> put_status(http_status)
    |> json(health)
  end

  @doc """
  GET /health/ready

  Kubernetes readiness probe.
  Returns 200 if the service is ready to accept traffic.
  """
  def ready(conn, _params) do
    db_ready = check_database() == :ok
    ollama_ready = check_ollama() in [:ok, :degraded]

    if db_ready and ollama_ready do
      json(conn, %{ready: true, timestamp: DateTime.utc_now() |> DateTime.to_iso8601()})
    else
      conn
      |> put_status(503)
      |> json(%{
        ready: false,
        database: db_ready,
        ollama: ollama_ready,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      })
    end
  end

  @doc """
  GET /health/live

  Kubernetes liveness probe.
  Returns 200 if the BEAM VM is running.
  """
  def live(conn, _params) do
    json(conn, %{
      alive: true,
      pid: System.pid(),
      uptime_seconds: get_uptime(),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  # ==========================================================================
  # Component Checks
  # ==========================================================================

  defp check_database do
    case Mimo.Repo.query("SELECT 1") do
      {:ok, _} -> :ok
      {:error, _} -> :error
    end
  rescue
    _ -> :error
  end

  defp check_ollama do
    case Mimo.Brain.LLM.available?() do
      true -> :ok
      false -> :degraded
    end
  rescue
    _ -> :degraded
  end

  defp check_hnsw do
    case HnswIndex.stats() do
      {:ok, stats} when map_size(stats) > 0 -> :ok
      _ -> :degraded
    end
  rescue
    _ -> :degraded
  end

  defp check_episodic_store do
    try do
      Memory.search_memories("health check", limit: 1)
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

  # ==========================================================================
  # Metrics
  # ==========================================================================

  defp get_memory_count do
    Memory.count_memories()
  rescue
    _ -> 0
  end

  defp get_hnsw_size do
    case HnswIndex.stats() do
      {:ok, %{count: count}} -> count
      _ -> 0
    end
  rescue
    _ -> 0
  end

  defp get_cache_stats do
    if Mimo.Cache.Embedding.available?() do
      stats = Mimo.Cache.Embedding.stats()

      %{
        size: stats.size,
        hit_rate: stats.hit_rate
      }
    else
      %{size: 0, hit_rate: 0.0}
    end
  rescue
    _ -> %{size: 0, hit_rate: 0.0}
  end

  defp get_uptime do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    div(uptime_ms, 1000)
  end

  defp format_status(:ok), do: "ok"
  defp format_status(:error), do: "error"
  defp format_status(:degraded), do: "degraded"
  defp format_status(other), do: to_string(other)

  # ==========================================================================
  # Startup Health Helpers (TASK 3)
  # ==========================================================================

  defp format_services(services) do
    Enum.map(services, fn service ->
      %{
        name: inspect(service.service),
        status: to_string(service.status || :unknown),
        dependencies: Enum.map(service[:dependencies] || [], &inspect/1),
        init_time_ms: calculate_init_time(service),
        registered_at: service[:registered_at],
        ready_at: service[:ready_at],
        failed_reason: service[:failed_reason],
        degraded_reason: service[:degraded_reason]
      }
    end)
  end

  defp calculate_init_time(%{registered_at: reg, ready_at: ready})
       when is_integer(reg) and is_integer(ready) do
    ready - reg
  end

  defp calculate_init_time(_), do: nil

  defp get_supervisor_info do
    # Get info about Mimo.Supervisor children
    case Process.whereis(Mimo.Supervisor) do
      nil ->
        %{available: false, reason: "supervisor not running"}

      pid when is_pid(pid) ->
        try do
          children = Supervisor.which_children(pid)

          %{
            available: true,
            child_count: length(children),
            children:
              Enum.map(children, fn {id, child_pid, type, _modules} ->
                %{
                  id: format_child_id(id),
                  type: type,
                  alive: is_pid(child_pid) and Process.alive?(child_pid),
                  pid: if(is_pid(child_pid), do: inspect(child_pid), else: nil)
                }
              end)
          }
        rescue
          _ -> %{available: false, reason: "error querying supervisor"}
        end
    end
  end

  defp format_child_id(id) when is_atom(id), do: Atom.to_string(id)
  defp format_child_id(id), do: inspect(id)

  defp get_circuit_breaker_status do
    # Check known circuit breakers
    [:llm_service, :ollama]
    |> Enum.map(fn name ->
      status =
        try do
          Mimo.ErrorHandling.CircuitBreaker.status(name)
        catch
          _, _ -> :unknown
        end

      {name, to_string(status)}
    end)
    |> Map.new()
  end

  defp generate_recommendations(startup_health) do
    recommendations = []

    recommendations =
      if startup_health.failed > 0 do
        failed_services =
          startup_health.services
          |> Enum.filter(&(&1.status == :failed))
          |> Enum.map(&inspect(&1.service))

        recommendations ++ ["Check failed services: #{Enum.join(failed_services, ", ")}"]
      else
        recommendations
      end

    recommendations =
      if startup_health.pending > 0 and get_uptime() > 30 do
        recommendations ++ ["Services still pending after 30s - check for startup issues"]
      else
        recommendations
      end

    recommendations =
      if startup_health.degraded > 0 do
        recommendations ++ ["Some services running in degraded mode - review dependencies"]
      else
        recommendations
      end

    if recommendations == [], do: ["All services healthy"], else: recommendations
  end
end
