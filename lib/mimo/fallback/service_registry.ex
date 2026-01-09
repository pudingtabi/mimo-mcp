defmodule Mimo.Fallback.ServiceRegistry do
  @moduledoc """
  Service Registry for Graceful Degradation Framework (TASK 5 - Dec 6 2025 Incident Response)

  Tracks initialization status and health of all supervised services. Enables:
  - Services to register their initialization status and dependencies
  - Dependent services to operate in degraded mode when dependencies fail
  - Circuit breaker pattern for service recovery

  ## Architecture

  Uses ETS for fast lock-free reads with GenServer for coordinated writes.
  Services register during init/1 and report ready status when fully initialized.

  ## Example Usage

      # In a GenServer init/1:
      def init(_opts) do
        Mimo.Fallback.ServiceRegistry.register(__MODULE__, [:ToolRegistry, :Repo])
        # ... do initialization ...
        Mimo.Fallback.ServiceRegistry.ready(__MODULE__)
        {:ok, state}
      end

      # Check if a dependency is available:
      if ServiceRegistry.available?(Mimo.ToolRegistry) do
        # Normal operation
      else
        # Degraded mode
      end

  ## Design Principles (From Dec 6 2025 Incident)

  1. Never block startup with synchronous calls to other services
  2. Use Process.whereis + try/catch for defensive checks
  3. External entry points must not invoke internal services during init
  4. Rely on defensive error handling, not orchestration

  @see Mimo.Fallback.GracefulDegradation for fallback strategies
  @see Mimo.ErrorHandling.CircuitBreaker for failure detection
  """
  use GenServer
  require Logger

  @table :mimo_service_registry
  @status_table :mimo_service_status

  # Service states
  # Service started but not ready
  @state_registered :registered
  # Service fully initialized
  @state_ready :ready
  # Service running in degraded mode
  @state_degraded :degraded
  # Service failed to initialize
  @state_failed :failed
  # Note: :recovering state could be used for auto-recovery in future

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register a service with its dependencies.
  Called early in a service's init/1 before full initialization.

  ## Parameters
    - service: The service module name (e.g., Mimo.Brain.HealthMonitor)
    - dependencies: List of service modules this service depends on
    - opts: Additional options
      - :timeout - Max time to wait for dependencies (default: 5000ms)
      - :degraded_ok - Whether to start in degraded mode if deps unavailable
  """
  @spec register(module(), [module()], keyword()) :: :ok | {:error, term()}
  def register(service, dependencies \\ [], opts \\ []) do
    GenServer.call(__MODULE__, {:register, service, dependencies, opts}, 10_000)
  catch
    :exit, _ ->
      # ServiceRegistry not started yet - log to stderr and continue
      emit_stderr("[ServiceRegistry] Not available during registration of #{inspect(service)}")
      :ok
  end

  @doc """
  Mark a service as ready (fully initialized).
  Called at the end of successful init/1.
  """
  @spec ready(module()) :: :ok
  def ready(service) do
    GenServer.cast(__MODULE__, {:ready, service})
  catch
    :exit, _ -> :ok
  end

  @doc """
  Mark a service as degraded (running with reduced functionality).
  """
  @spec degraded(module(), term()) :: :ok
  def degraded(service, reason \\ :unknown) do
    GenServer.cast(__MODULE__, {:degraded, service, reason})
  catch
    :exit, _ -> :ok
  end

  @doc """
  Mark a service as failed.
  """
  @spec failed(module(), term()) :: :ok
  def failed(service, reason) do
    GenServer.cast(__MODULE__, {:failed, service, reason})
  catch
    :exit, _ -> :ok
  end

  @doc """
  Check if a service is available for use.
  Uses fast ETS lookup - safe to call frequently.

  Returns true if the service is :ready or :degraded (but operational).
  """
  @spec available?(module()) :: boolean()
  def available?(service) do
    case get_status(service) do
      :ready -> true
      :degraded -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc """
  Check if a service is fully ready (not degraded).
  """
  @spec ready?(module()) :: boolean()
  def ready?(service) do
    get_status(service) == :ready
  rescue
    _ -> false
  end

  @doc """
  Get the current status of a service.
  """
  @spec get_status(module()) :: atom() | nil
  def get_status(service) do
    case :ets.lookup(@status_table, service) do
      [{^service, status, _meta}] -> status
      [] -> nil
    end
  rescue
    # Table doesn't exist yet
    ArgumentError -> nil
  end

  @doc """
  Get full service info including dependencies and metadata.
  """
  @spec get_info(module()) :: map() | nil
  def get_info(service) do
    case :ets.lookup(@table, service) do
      [{^service, info}] -> info
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  List all registered services with their status.
  """
  @spec list_services() :: [map()]
  def list_services do
    try do
      :ets.tab2list(@table)
      |> Enum.map(fn {service, info} ->
        status = get_status(service)
        Map.merge(info, %{service: service, status: status})
      end)
    rescue
      _ -> []
    end
  end

  @doc """
  Get startup health summary for all services.
  """
  @spec startup_health() :: map()
  def startup_health do
    services = list_services()

    %{
      total: length(services),
      ready: Enum.count(services, &(&1.status == :ready)),
      degraded: Enum.count(services, &(&1.status == :degraded)),
      failed: Enum.count(services, &(&1.status == :failed)),
      pending: Enum.count(services, &(&1.status == :registered)),
      services: services,
      healthy: Enum.all?(services, &(&1.status in [:ready, :degraded]))
    }
  end

  @doc """
  Wait for a service to become available, with timeout.
  Returns immediately if already available.

  NOTE: Use sparingly - prefer defensive checks over waiting.
  """
  @spec wait_for(module(), timeout()) :: :ok | {:error, :timeout}
  def wait_for(service, timeout \\ 5000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for(service, deadline)
  end

  defp do_wait_for(service, deadline) do
    if available?(service) do
      :ok
    else
      now = System.monotonic_time(:millisecond)

      if now >= deadline do
        {:error, :timeout}
      else
        Process.sleep(50)
        do_wait_for(service, deadline)
      end
    end
  end

  @doc """
  Check if all dependencies of a service are available.
  """
  @spec dependencies_available?(module()) :: boolean()
  def dependencies_available?(service) do
    case get_info(service) do
      %{dependencies: deps} -> Enum.all?(deps, &available?/1)
      nil -> true
    end
  end

  @doc """
  Get unavailable dependencies for a service.
  """
  @spec unavailable_dependencies(module()) :: [module()]
  def unavailable_dependencies(service) do
    case get_info(service) do
      %{dependencies: deps} -> Enum.reject(deps, &available?/1)
      nil -> []
    end
  end

  @doc """
  Safely call a GenServer with defensive checks.

  This is the recommended pattern for external interfaces to call internal services.
  Handles:
  - Process not started yet (returns {:error, :not_ready})
  - Process crashed (returns {:error, :not_alive})
  - Timeout (returns {:error, :timeout})
  - Any other error (returns {:error, reason})

  ## Example

      case ServiceRegistry.safe_call(Mimo.ToolRegistry, :get_tools) do
        {:ok, tools} -> tools
        {:error, :not_ready} -> []  # Graceful degradation
        {:error, reason} -> Logger.warning("ToolRegistry unavailable: \#{reason}"); []
      end

  """
  @spec safe_call(module() | atom(), term(), timeout()) :: {:ok, term()} | {:error, term()}
  def safe_call(server, message, timeout \\ 5000) do
    case Process.whereis(server) do
      nil ->
        emit_stderr("[SafeCall] #{inspect(server)} not registered")
        {:error, :not_ready}

      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          try do
            result = GenServer.call(pid, message, timeout)
            {:ok, result}
          catch
            :exit, {:timeout, _} ->
              emit_stderr("[SafeCall] #{inspect(server)} timed out after #{timeout}ms")
              {:error, :timeout}

            :exit, {:noproc, _} ->
              emit_stderr("[SafeCall] #{inspect(server)} not running")
              {:error, :not_alive}

            :exit, reason ->
              emit_stderr("[SafeCall] #{inspect(server)} exited: #{inspect(reason)}")
              {:error, {:exit, reason}}
          end
        else
          emit_stderr("[SafeCall] #{inspect(server)} process dead")
          {:error, :not_alive}
        end
    end
  end

  @doc """
  Safe cast to a GenServer - fire and forget with defensive check.
  """
  @spec safe_cast(module() | atom(), term()) :: :ok | {:error, :not_ready}
  def safe_cast(server, message) do
    case Process.whereis(server) do
      nil ->
        {:error, :not_ready}

      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          GenServer.cast(pid, message)
          :ok
        else
          {:error, :not_alive}
        end
    end
  end

  @impl true
  def init(_opts) do
    # Create ETS tables for fast lookups
    # Using :public so any process can read
    Mimo.EtsSafe.ensure_table(@table, [:named_table, :public, :set, {:read_concurrency, true}])

    Mimo.EtsSafe.ensure_table(@status_table, [
      :named_table,
      :public,
      :set,
      {:read_concurrency, true}
    ])

    Logger.info("[ServiceRegistry] Started - tracking service initialization")

    {:ok, %{start_time: System.monotonic_time(:millisecond)}}
  end

  @impl true
  def handle_call({:register, service, dependencies, opts}, _from, state) do
    now = System.monotonic_time(:millisecond)

    info = %{
      dependencies: dependencies,
      registered_at: now,
      ready_at: nil,
      degraded_at: nil,
      failed_at: nil,
      opts: opts,
      degraded_reason: nil,
      failed_reason: nil
    }

    :ets.insert(@table, {service, info})
    :ets.insert(@status_table, {service, @state_registered, %{since: now}})

    Logger.debug(
      "[ServiceRegistry] Registered #{inspect(service)} with deps: #{inspect(dependencies)}"
    )

    # Emit telemetry
    :telemetry.execute(
      [:mimo, :service_registry, :registered],
      %{count: 1},
      %{service: service, dependencies: dependencies}
    )

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:ready, service}, state) do
    now = System.monotonic_time(:millisecond)

    # Update info
    case :ets.lookup(@table, service) do
      [{^service, info}] ->
        updated_info = %{info | ready_at: now}
        :ets.insert(@table, {service, updated_info})

        init_time = now - (info.registered_at || now)
        Logger.info("[ServiceRegistry] #{inspect(service)} ready (init: #{init_time}ms)")

        :telemetry.execute(
          [:mimo, :service_registry, :ready],
          %{init_time_ms: init_time},
          %{service: service}
        )

      [] ->
        # Service wasn't registered - register and mark ready
        :ets.insert(@table, {service, %{dependencies: [], registered_at: now, ready_at: now}})
    end

    :ets.insert(@status_table, {service, @state_ready, %{since: now}})

    {:noreply, state}
  end

  @impl true
  def handle_cast({:degraded, service, reason}, state) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, service) do
      [{^service, info}] ->
        updated_info = %{info | degraded_at: now, degraded_reason: reason}
        :ets.insert(@table, {service, updated_info})

      [] ->
        :ets.insert(
          @table,
          {service, %{dependencies: [], degraded_at: now, degraded_reason: reason}}
        )
    end

    :ets.insert(@status_table, {service, @state_degraded, %{since: now, reason: reason}})

    Logger.warning("[ServiceRegistry] #{inspect(service)} degraded: #{inspect(reason)}")

    :telemetry.execute(
      [:mimo, :service_registry, :degraded],
      %{count: 1},
      %{service: service, reason: reason}
    )

    {:noreply, state}
  end

  @impl true
  def handle_cast({:failed, service, reason}, state) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, service) do
      [{^service, info}] ->
        updated_info = %{info | failed_at: now, failed_reason: reason}
        :ets.insert(@table, {service, updated_info})

      [] ->
        :ets.insert(@table, {service, %{dependencies: [], failed_at: now, failed_reason: reason}})
    end

    :ets.insert(@status_table, {service, @state_failed, %{since: now, reason: reason}})

    Logger.error("[ServiceRegistry] #{inspect(service)} FAILED: #{inspect(reason)}")

    :telemetry.execute(
      [:mimo, :service_registry, :failed],
      %{count: 1},
      %{service: service, reason: reason}
    )

    {:noreply, state}
  end

  defp emit_stderr(message) do
    # Write to stderr so it's visible even when LOGGER_LEVEL=none
    # This is critical for debugging startup issues in MCP stdio mode
    IO.write(:standard_error, "#{message}\n")
  rescue
    _ -> :ok
  end
end
