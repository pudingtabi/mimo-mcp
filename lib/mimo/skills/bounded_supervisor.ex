defmodule Mimo.Skills.Supervisor do
  @moduledoc """
  Supervised skill process management with resource limits.

  Features:
  - Maximum concurrent skills limit (default: 100)
  - Automatic cleanup on skill termination
  - Telemetry for monitoring skill lifecycle
  - Graceful handling of limit exceeded errors

  ## Configuration

  Configure in `config/config.exs`:

      config :mimo_mcp, Mimo.Skills.Supervisor,
        max_concurrent_skills: 100,
        max_restart_intensity: 3,
        restart_period_seconds: 5

  ## Usage

      # Start a new skill (respects limits)
      {:ok, pid} = Mimo.Skills.Supervisor.start_skill("filesystem", config)
      
      # Check current skill count
      count = Mimo.Skills.Supervisor.count_skills()
      
      # Get skill statistics
      stats = Mimo.Skills.Supervisor.stats()
  """
  use DynamicSupervisor
  require Logger

  @default_max_skills 100
  @default_restart_intensity 3
  @default_restart_period 5

  # ==========================================================================
  # Public API
  # ==========================================================================

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc """
  Starts a new skill process under supervision.

  Returns `{:error, :max_skills_limit_reached}` if limit exceeded.
  """
  @spec start_skill(String.t(), map()) :: {:ok, pid()} | {:error, term()}
  def start_skill(skill_name, config) do
    max_skills = get_max_skills()
    current_count = count_skills()

    if current_count >= max_skills do
      Logger.warning(
        "Skills limit reached (#{current_count}/#{max_skills}), rejecting #{skill_name}"
      )

      emit_telemetry(:skill_rejected, %{skill_name: skill_name, reason: :limit_reached})
      {:error, :max_skills_limit_reached}
    else
      do_start_skill(skill_name, config)
    end
  end

  @doc """
  Returns count of currently active skills.
  """
  @spec count_skills() :: non_neg_integer()
  def count_skills do
    DynamicSupervisor.count_children(__MODULE__).active
  end

  @doc """
  Returns detailed statistics about skill processes.
  """
  @spec stats() :: map()
  def stats do
    children = DynamicSupervisor.count_children(__MODULE__)
    max_skills = get_max_skills()

    %{
      active: children.active,
      max_allowed: max_skills,
      utilization: children.active / max_skills * 100,
      supervisors: children.supervisors,
      workers: children.workers,
      specs: children.specs
    }
  end

  @doc """
  Lists all running skill processes with their info.
  """
  @spec list_skills() :: [{String.t(), pid(), map()}]
  def list_skills do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.map(fn {_id, pid, _type, _modules} ->
      info =
        try do
          if Process.alive?(pid) do
            %{
              pid: pid,
              alive: true,
              memory: Process.info(pid, :memory) |> elem(1),
              message_queue_len: Process.info(pid, :message_queue_len) |> elem(1)
            }
          else
            %{pid: pid, alive: false}
          end
        catch
          _, _ -> %{pid: pid, alive: false, error: :info_failed}
        end

      {pid, info}
    end)
  end

  @doc """
  Terminates a skill by pid.
  """
  @spec terminate_skill(pid()) :: :ok | {:error, :not_found}
  def terminate_skill(pid) when is_pid(pid) do
    case DynamicSupervisor.terminate_child(__MODULE__, pid) do
      :ok ->
        emit_telemetry(:skill_terminated, %{pid: pid})
        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Terminates all skill processes. Use with caution.
  """
  @spec terminate_all() :: :ok
  def terminate_all do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.each(fn {_id, pid, _type, _modules} ->
      DynamicSupervisor.terminate_child(__MODULE__, pid)
    end)

    Logger.warning("All skill processes terminated")
    :ok
  end

  @doc """
  Checks if a skill can be started (under limit).
  """
  @spec can_start_skill?() :: boolean()
  def can_start_skill? do
    count_skills() < get_max_skills()
  end

  # ==========================================================================
  # DynamicSupervisor Callbacks
  # ==========================================================================

  @impl true
  def init(_init_arg) do
    Logger.info("Skills Supervisor started (max: #{get_max_skills()})")

    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: get_restart_intensity(),
      max_seconds: get_restart_period()
    )
  end

  # ==========================================================================
  # Private Functions
  # ==========================================================================

  defp do_start_skill(skill_name, config) do
    child_spec = %{
      id: {Mimo.Skills.Client, skill_name},
      start: {Mimo.Skills.Client, :start_link, [skill_name, config]},
      restart: :transient,
      shutdown: 30_000
    }

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} ->
        emit_telemetry(:skill_started, %{skill_name: skill_name, pid: pid})
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} = error ->
        Logger.error("Failed to start skill '#{skill_name}': #{inspect(reason)}")
        emit_telemetry(:skill_start_failed, %{skill_name: skill_name, reason: reason})
        error
    end
  end

  defp get_max_skills do
    Application.get_env(:mimo_mcp, __MODULE__, [])
    |> Keyword.get(:max_concurrent_skills, @default_max_skills)
  end

  defp get_restart_intensity do
    Application.get_env(:mimo_mcp, __MODULE__, [])
    |> Keyword.get(:max_restart_intensity, @default_restart_intensity)
  end

  defp get_restart_period do
    Application.get_env(:mimo_mcp, __MODULE__, [])
    |> Keyword.get(:restart_period_seconds, @default_restart_period)
  end

  defp emit_telemetry(event, metadata) do
    :telemetry.execute(
      [:mimo, :skills, event],
      %{count: 1, timestamp: System.system_time(:millisecond)},
      metadata
    )
  end
end
