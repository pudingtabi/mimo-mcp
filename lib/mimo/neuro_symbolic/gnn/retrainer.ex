defmodule Mimo.NeuroSymbolic.GnnRetrainer do
  @moduledoc """
  SPEC-051 Phase 2: Periodic GNN model retraining.

  Ensures the GnnPredictor model stays fresh as new memories accumulate.
  Default schedule: every 4 hours, or can be triggered after N new memories.

  ## Configuration

      config :mimo, Mimo.NeuroSymbolic.GnnRetrainer,
        enabled: true,
        interval_ms: 4 * 60 * 60 * 1000,  # 4 hours
        memory_threshold: 100,            # Retrain after 100 new memories
        k: 10,                            # Number of clusters
        sample_size: 500                  # Memories to sample
  """
  use GenServer
  require Logger

  alias Mimo.NeuroSymbolic.GnnPredictor
  alias Mimo.Brain.Engram
  alias Mimo.Repo
  import Ecto.Query

  # 4 hours default
  @default_interval_ms 4 * 60 * 60 * 1000
  # 5 seconds after startup
  @startup_delay_ms 5 * 1000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Manually trigger a retraining cycle.
  """
  def retrain_now do
    GenServer.cast(__MODULE__, :retrain)
  end

  @doc """
  Get the retrainer status.
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Called when a new memory is stored - checks if threshold reached.
  """
  def notify_memory_stored do
    GenServer.cast(__MODULE__, :memory_stored)
  end

  @impl true
  def init(_opts) do
    config = get_config()

    state = %{
      enabled: config.enabled,
      interval_ms: config.interval_ms,
      memory_threshold: config.memory_threshold,
      k: config.k,
      sample_size: config.sample_size,
      last_trained: nil,
      last_memory_count: get_memory_count(),
      memories_since_train: 0,
      train_count: 0,
      error_count: 0
    }

    # Schedule first training after startup delay
    if config.enabled do
      Process.send_after(self(), :retrain, @startup_delay_ms)
      Logger.debug("[GnnRetrainer] Started, first train in #{div(@startup_delay_ms, 1000)}s")
    end

    {:ok, state}
  end

  @impl true
  def handle_cast(:retrain, state) do
    new_state = execute_retrain(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:memory_stored, state) do
    # Increment counter
    new_count = state.memories_since_train + 1

    # Check if threshold reached
    if new_count >= state.memory_threshold do
      Logger.info("[GnnRetrainer] Memory threshold reached (#{new_count}), triggering retrain")
      new_state = execute_retrain(%{state | memories_since_train: 0})
      {:noreply, new_state}
    else
      {:noreply, %{state | memories_since_train: new_count}}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      enabled: state.enabled,
      interval_ms: state.interval_ms,
      interval_human: format_duration(state.interval_ms),
      memory_threshold: state.memory_threshold,
      memories_since_train: state.memories_since_train,
      last_trained: state.last_trained,
      train_count: state.train_count,
      error_count: state.error_count,
      next_train_in_ms: time_to_next_train(state),
      model_config: %{k: state.k, sample_size: state.sample_size}
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:retrain, state) do
    new_state =
      if state.enabled do
        execute_retrain(state)
      else
        state
      end

    # Schedule next cycle
    schedule_next_retrain(new_state)

    {:noreply, new_state}
  end

  defp execute_retrain(state) do
    Logger.info("[GnnRetrainer] Running retrain cycle (k=#{state.k}, sample=#{state.sample_size})")
    start_time = System.monotonic_time(:millisecond)

    result =
      try do
        GnnPredictor.train(%{k: state.k, sample_size: state.sample_size})
      rescue
        _e in DBConnection.OwnershipError ->
          Logger.debug("[GnnRetrainer] Skipped (sandbox mode)")
          {:error, :sandbox_mode}

        e in DBConnection.ConnectionError ->
          Logger.debug("[GnnRetrainer] Skipped (connection): #{Exception.message(e)}")
          {:error, :connection_error}

        e ->
          Logger.error("[GnnRetrainer] Failed: #{Exception.message(e)}")
          {:error, Exception.message(e)}
      end

    duration_ms = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, model} ->
        Logger.info(
          "[GnnRetrainer] Trained in #{duration_ms}ms: #{model.k} clusters from #{model.sample_size} memories"
        )

        %{
          state
          | last_trained: DateTime.utc_now(),
            last_memory_count: get_memory_count(),
            memories_since_train: 0,
            train_count: state.train_count + 1
        }

      {:error, :sandbox_mode} ->
        # Don't count sandbox errors
        state

      {:error, _reason} ->
        %{
          state
          | last_trained: DateTime.utc_now(),
            error_count: state.error_count + 1
        }
    end
  end

  defp schedule_next_retrain(state) do
    if state.enabled do
      Process.send_after(self(), :retrain, state.interval_ms)
    end
  end

  defp get_config do
    app_config = Application.get_env(:mimo, __MODULE__, [])

    %{
      enabled: Keyword.get(app_config, :enabled, true),
      interval_ms: Keyword.get(app_config, :interval_ms, @default_interval_ms),
      memory_threshold: Keyword.get(app_config, :memory_threshold, 100),
      k: Keyword.get(app_config, :k, 10),
      sample_size: Keyword.get(app_config, :sample_size, 500)
    }
  end

  defp get_memory_count do
    try do
      Repo.one(from(e in Engram, where: not is_nil(e.embedding_int8), select: count(e.id))) || 0
    rescue
      _ -> 0
    end
  end

  defp format_duration(ms) when ms < 60_000, do: "#{div(ms, 1000)}s"
  defp format_duration(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)}m"
  defp format_duration(ms), do: "#{div(ms, 3_600_000)}h"

  defp time_to_next_train(%{last_trained: nil, interval_ms: interval_ms}), do: interval_ms

  defp time_to_next_train(%{last_trained: last, interval_ms: interval_ms}) do
    elapsed = DateTime.diff(DateTime.utc_now(), last, :millisecond)
    max(0, interval_ms - elapsed)
  end
end
