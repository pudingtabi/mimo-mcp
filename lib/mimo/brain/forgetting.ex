defmodule Mimo.Brain.Forgetting do
  @moduledoc """
  Scheduled memory forgetting based on decay scores.

  Runs periodically to identify and remove memories that have
  decayed below the configured threshold.

  ## Configuration

      config :mimo_mcp, :forgetting,
        enabled: true,
        interval_ms: 3_600_000,    # 1 hour
        threshold: 0.1,            # Forget below this score
        batch_size: 1000,          # Process N memories at a time
        dry_run: false             # Log but don't delete

  ## Examples

      # Check forgetting stats
      Forgetting.stats()

      # Manually trigger forgetting (dry run)
      {:ok, count} = Forgetting.run_now(dry_run: true)

      # Protect a memory from forgetting
      :ok = Forgetting.protect(memory_id)
  """
  use GenServer
  require Logger

  import Ecto.Query
  alias Mimo.{Repo, Brain.Engram, Brain.DecayScorer}
  alias Mimo.SafeCall

  @default_interval 3_600_000
  @default_threshold 0.1
  @default_batch_size 1000

  # ==========================================================================
  # Public API
  # ==========================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Trigger immediate forgetting cycle.

  ## Options

    * `:dry_run` - Log but don't delete (default: from config)
    * `:threshold` - Score threshold (default: from config)
    * `:batch_size` - Process N memories (default: from config)

  ## Returns

    * `{:ok, count}` - Number of memories forgotten/would forget
    * `{:error, :unavailable}` - Forgetting service not running
  """
  @spec run_now(keyword()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def run_now(opts \\ []) do
    SafeCall.genserver(__MODULE__, {:run_now, opts},
      timeout: 60_000,
      raw: true,
      fallback: {:ok, 0}
    )
  end

  @doc """
  Get forgetting statistics.
  Returns empty stats if service unavailable.
  """
  @spec stats() :: map()
  def stats do
    SafeCall.genserver(__MODULE__, :stats,
      raw: true,
      fallback: %{status: :unavailable, total_forgotten: 0}
    )
  end

  @doc """
  Protect a memory from forgetting.
  """
  @spec protect(integer() | String.t()) :: :ok | {:error, :not_found | :unavailable}
  def protect(id) do
    SafeCall.genserver(__MODULE__, {:protect, id},
      raw: true,
      fallback: {:error, :unavailable}
    )
  end

  @doc """
  Remove protection from a memory.
  """
  @spec unprotect(integer() | String.t()) :: :ok | {:error, :not_found | :unavailable}
  def unprotect(id) do
    SafeCall.genserver(__MODULE__, {:unprotect, id},
      raw: true,
      fallback: {:error, :unavailable}
    )
  end

  # ==========================================================================
  # GenServer Callbacks
  # ==========================================================================

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, get_config(:interval_ms, @default_interval))

    state = %{
      last_run: nil,
      total_forgotten: 0,
      last_batch_count: 0,
      interval: interval,
      running: false
    }

    if get_config(:enabled, true) do
      schedule_run(interval)
    end

    Logger.info("Forgetting system initialized (interval: #{interval}ms)")
    {:ok, state}
  end

  @impl true
  def handle_call({:run_now, opts}, _from, state) do
    {count, new_state} = run_forgetting_cycle(state, opts)
    {:reply, {:ok, count}, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats =
      Map.take(state, [:last_run, :total_forgotten, :last_batch_count])
      |> Map.put(:interval_ms, state.interval)
      |> Map.put(:threshold, get_config(:threshold, @default_threshold))
      |> Map.put(:enabled, get_config(:enabled, true))

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:protect, id}, _from, state) do
    result = set_protection(id, true)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:unprotect, id}, _from, state) do
    result = set_protection(id, false)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:run, state) do
    {_count, new_state} = run_forgetting_cycle(state, [])
    schedule_run(state.interval)
    {:noreply, new_state}
  end

  # ==========================================================================
  # Private Implementation
  # ==========================================================================

  defp run_forgetting_cycle(state, opts) do
    threshold = opts[:threshold] || get_config(:threshold, @default_threshold)
    batch_size = opts[:batch_size] || get_config(:batch_size, @default_batch_size)
    dry_run = opts[:dry_run] || get_config(:dry_run, false)

    :telemetry.execute([:mimo, :memory, :forgetting, :started], %{}, %{})

    # Query non-protected memories
    candidates =
      from(e in Engram,
        where: e.protected == false or is_nil(e.protected),
        limit: ^batch_size,
        select: %{
          id: e.id,
          content: e.content,
          category: e.category,
          importance: e.importance,
          access_count: e.access_count,
          last_accessed_at: e.last_accessed_at,
          inserted_at: e.inserted_at,
          decay_rate: e.decay_rate,
          protected: e.protected
        }
      )
      |> Repo.all()

    # Filter by decay score
    to_forget = DecayScorer.filter_forgettable(candidates, threshold)

    count =
      if dry_run do
        Logger.info(
          "Forgetting dry run: would delete #{length(to_forget)} of #{length(candidates)} memories"
        )

        # Log sample of what would be forgotten
        to_forget
        |> Enum.take(5)
        |> Enum.each(fn m ->
          score = DecayScorer.calculate_score(m)

          Logger.debug(
            "Would forget: #{String.slice(m.content, 0, 50)}... (score: #{Float.round(score, 3)})"
          )
        end)

        length(to_forget)
      else
        delete_memories(to_forget)
      end

    :telemetry.execute(
      [:mimo, :memory, :forgetting, :completed],
      %{forgotten_count: count},
      %{dry_run: dry_run, threshold: threshold, candidates: length(candidates)}
    )

    if count > 0 do
      Logger.info("Forgetting cycle complete: #{count} memories forgotten (dry_run: #{dry_run})")
    end

    new_state = %{
      state
      | last_run: DateTime.utc_now(),
        total_forgotten: state.total_forgotten + if(dry_run, do: 0, else: count),
        last_batch_count: count
    }

    {count, new_state}
  end

  defp delete_memories([]), do: 0

  defp delete_memories(memories) do
    ids = Enum.map(memories, & &1.id)

    {count, _} =
      from(e in Engram, where: e.id in ^ids)
      |> Repo.delete_all()

    # Emit individual events for monitoring
    Enum.each(memories, fn m ->
      :telemetry.execute(
        [:mimo, :memory, :decayed],
        %{score: DecayScorer.calculate_score(m)},
        %{id: m.id, category: m.category}
      )
    end)

    count
  end

  defp set_protection(id, protected) do
    case Repo.get(Engram, id) do
      nil ->
        {:error, :not_found}

      engram ->
        changeset = Ecto.Changeset.change(engram, protected: protected)

        case Repo.update(changeset) do
          {:ok, _} -> :ok
          {:error, _} = error -> error
        end
    end
  end

  defp schedule_run(interval) do
    Process.send_after(self(), :run, interval)
  end

  defp get_config(key, default) do
    Application.get_env(:mimo_mcp, :forgetting, [])
    |> Keyword.get(key, default)
  end
end
