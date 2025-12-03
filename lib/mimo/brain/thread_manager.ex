defmodule Mimo.Brain.ThreadManager do
  @moduledoc """
  ThreadManager manages AI session threads and their lifecycle.

  This GenServer:
  - Maintains the current active thread ID in process state
  - Provides fast thread lookup without DB queries
  - Handles thread lifecycle (create, touch, disconnect)
  - Schedules periodic cleanup of idle threads

  ## Architecture (SPEC-012)

  ```
  AI connects → ThreadManager.get_or_create_thread()
      ↓
  Thread ID stored in process state
      ↓
  All tool calls → ThreadManager.record_interaction()
      ↓
  Periodic cleanup → archive old threads
  ```
  """

  use GenServer
  require Logger

  alias Mimo.Brain.{Thread, Interaction}

  @cleanup_interval :timer.minutes(5)
  # Note: @idle_timeout is not currently used but kept for future auto-close
  # @idle_timeout :timer.minutes(30)

  # ─────────────────────────────────────────────────────────────
  # Client API
  # ─────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets the current thread ID, creating a new thread if needed.
  """
  def get_current_thread_id do
    GenServer.call(__MODULE__, :get_current_thread_id)
  end

  @doc """
  Gets the current thread struct.
  """
  def get_current_thread do
    GenServer.call(__MODULE__, :get_current_thread)
  end

  @doc """
  Records a tool interaction for the current thread.

  ## Options
  - `:arguments` - Map of arguments passed to the tool
  - `:result_summary` - Brief summary of the result (will be truncated)
  - `:duration_ms` - How long the call took
  """
  def record_interaction(tool_name, opts \\ []) do
    GenServer.cast(__MODULE__, {:record_interaction, tool_name, opts})
  end

  @doc """
  Touches the current thread (updates last_active_at).
  Called automatically on interactions, but can be called manually.
  """
  def touch do
    GenServer.cast(__MODULE__, :touch)
  end

  @doc """
  Forces creation of a new thread.
  """
  def new_thread(opts \\ []) do
    GenServer.call(__MODULE__, {:new_thread, opts})
  end

  @doc """
  Disconnects the current thread.
  """
  def disconnect do
    GenServer.call(__MODULE__, :disconnect)
  end

  @doc """
  Gets thread statistics.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Gets tool usage statistics from interaction history.
  Returns `{:ok, stats}` with summary, rankings, performance data.
  """
  @spec get_tool_usage_stats(keyword()) :: {:ok, map()} | {:error, term()}
  def get_tool_usage_stats(opts \\ []) do
    {:ok, Interaction.tool_usage_stats(opts)}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Gets recent interactions for the current thread.
  Returns `{:ok, interactions}` where each has tool_name, duration_ms, success.
  """
  @spec recent_interactions(non_neg_integer()) :: {:ok, [map()]} | {:error, term()}
  def recent_interactions(limit \\ 20) do
    case get_current_thread_id() do
      nil ->
        {:ok, []}

      thread_id ->
        interactions =
          Interaction.get_recent_for_thread(thread_id, limit: limit)
          |> Enum.map(fn i ->
            %{
              tool_name: i.tool_name,
              duration_ms: i.duration_ms,
              # Derive success from result_summary (no error keywords = success)
              success:
                not String.contains?(i.result_summary || "", ["error", "Error", "failed", "Failed"])
            }
          end)

        {:ok, interactions}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ─────────────────────────────────────────────────────────────────
  # Server Callbacks
  # ─────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    Logger.info("[ThreadManager] Starting thread manager")

    # Schedule periodic cleanup
    schedule_cleanup()

    # Try to resume the most recent active thread
    state =
      case Thread.get_or_create_current() do
        {:ok, thread} ->
          Logger.info("[ThreadManager] Resumed thread #{thread.id}")
          %{current_thread_id: thread.id, thread_cache: %{thread.id => thread}}

        {:error, reason} ->
          Logger.warning("[ThreadManager] Could not create thread: #{inspect(reason)}")
          %{current_thread_id: nil, thread_cache: %{}}
      end

    {:ok, state}
  end

  @impl true
  def handle_call(:get_current_thread_id, _from, state) do
    case ensure_thread(state) do
      {:ok, thread_id, new_state} ->
        {:reply, thread_id, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:get_current_thread, _from, state) do
    case ensure_thread(state) do
      {:ok, thread_id, new_state} ->
        thread = Map.get(new_state.thread_cache, thread_id)
        {:reply, thread, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:new_thread, opts}, _from, state) do
    case Thread.create(opts) do
      {:ok, thread} ->
        Logger.info("[ThreadManager] Created new thread #{thread.id}")

        new_state = %{
          state
          | current_thread_id: thread.id,
            thread_cache: Map.put(state.thread_cache, thread.id, thread)
        }

        {:reply, {:ok, thread.id}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:disconnect, _from, state) do
    case state.current_thread_id do
      nil ->
        {:reply, :ok, state}

      thread_id ->
        Thread.disconnect(thread_id)
        Logger.info("[ThreadManager] Disconnected thread #{thread_id}")
        new_state = %{state | current_thread_id: nil}
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    thread_stats = Thread.stats()
    interaction_stats = Interaction.stats()

    stats = %{
      current_thread_id: state.current_thread_id,
      cached_threads: map_size(state.thread_cache),
      threads: thread_stats,
      interactions: interaction_stats
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:record_interaction, tool_name, opts}, state) do
    case ensure_thread(state) do
      {:ok, thread_id, new_state} ->
        # Record the interaction asynchronously
        Mimo.Sandbox.run_async(Mimo.Repo, fn ->
          opts_with_thread = Keyword.put(opts, :thread_id, thread_id)

          case Interaction.record(tool_name, opts_with_thread) do
            {:ok, _interaction} ->
              Logger.debug("[ThreadManager] Recorded interaction: #{tool_name}")

            {:error, reason} ->
              Logger.warning("[ThreadManager] Failed to record interaction: #{inspect(reason)}")

              :telemetry.execute([:mimo, :thread_manager, :record_error], %{count: 1}, %{
                tool: tool_name,
                reason: inspect(reason)
              })
          end
        end)

        # Touch the thread to update last_active_at
        Task.Supervisor.start_child(Mimo.TaskSupervisor, fn ->
          Thread.touch(thread_id)
        end)

        {:noreply, new_state}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast(:touch, state) do
    case state.current_thread_id do
      nil ->
        {:noreply, state}

      thread_id ->
        Task.Supervisor.start_child(Mimo.TaskSupervisor, fn ->
          Thread.touch(thread_id)
        end)

        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:cleanup, state) do
    Logger.debug("[ThreadManager] Running periodic cleanup")

    # Clean up idle threads
    Task.Supervisor.start_child(Mimo.TaskSupervisor, fn ->
      try do
        Thread.cleanup_idle()
        Thread.archive_old(7)
        Interaction.cleanup_old(30)
      rescue
        _e in DBConnection.OwnershipError ->
          Logger.debug("[ThreadManager] Cleanup skipped (sandbox mode)")

        _e in DBConnection.ConnectionError ->
          Logger.debug("[ThreadManager] Cleanup skipped (connection)")

        e ->
          Logger.error("[ThreadManager] Cleanup failed: #{Exception.message(e)}")

          :telemetry.execute([:mimo, :thread_manager, :cleanup_error], %{count: 1}, %{
            error: Exception.message(e)
          })
      end
    end)

    # Refresh thread cache - remove stale entries
    new_cache =
      state.thread_cache
      |> Enum.filter(fn {id, _thread} ->
        id == state.current_thread_id
      end)
      |> Map.new()

    schedule_cleanup()
    {:noreply, %{state | thread_cache: new_cache}}
  end

  # ─────────────────────────────────────────────────────────────
  # Private Functions
  # ─────────────────────────────────────────────────────────────

  defp ensure_thread(state) do
    case state.current_thread_id do
      nil ->
        case Thread.get_or_create_current() do
          {:ok, thread} ->
            new_state = %{
              state
              | current_thread_id: thread.id,
                thread_cache: Map.put(state.thread_cache, thread.id, thread)
            }

            {:ok, thread.id, new_state}

          {:error, reason} ->
            {:error, reason}
        end

      thread_id ->
        {:ok, thread_id, state}
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
