defmodule Mimo.Context.ContextWindowManager do
  @moduledoc """
  Tracks and manages context window usage across sessions.

  Part of Phase 2 Cognitive Enhancement - Context Window Awareness.

  This GenServer maintains awareness of current context usage per thread,
  providing warnings when approaching limits and suggesting actions.

  ## Features

  - Real-time token tracking per thread/session
  - Configurable thresholds for warnings
  - Automatic summarization suggestions
  - Usage statistics and monitoring

  ## Example

      # Track tokens used
      ContextWindowManager.track_usage("thread_123", 1500)

      # Get current usage
      ContextWindowManager.get_usage("thread_123")
      # => %{tokens_used: 1500, model_limit: 200_000, percentage: 0.75, status: :ok}

      # Get all sessions
      ContextWindowManager.all_sessions()
  """

  use GenServer
  require Logger

  alias Mimo.Context.BudgetAllocator

  @table_name :context_window_tracker
  @cleanup_interval :timer.minutes(30)
  @session_ttl :timer.hours(2)

  # Thresholds for warnings
  @warning_threshold 0.70
  @critical_threshold 0.85
  @summarize_threshold 0.90

  # Default model limits (tokens)
  @default_model_limit 200_000

  @type thread_id :: String.t()
  @type usage_status :: :ok | :warning | :critical | :summarize_recommended
  @type session_state :: %{
          thread_id: thread_id(),
          tokens_used: non_neg_integer(),
          model_limit: pos_integer(),
          model_type: atom(),
          percentage: float(),
          status: usage_status(),
          started_at: DateTime.t(),
          last_updated: DateTime.t(),
          history: [non_neg_integer()]
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Track token usage for a thread.

  ## Parameters

    - `thread_id` - Unique identifier for the session/thread
    - `tokens` - Number of tokens used in this operation
    - `opts` - Options including :model (string), :operation (atom)

  ## Returns

    - `{:ok, session_state}` with current usage info and status
  """
  @spec track_usage(thread_id(), non_neg_integer(), keyword()) :: {:ok, session_state()}
  def track_usage(thread_id, tokens, opts \\ []) do
    GenServer.call(__MODULE__, {:track_usage, thread_id, tokens, opts})
  end

  @doc """
  Get current usage for a thread.
  """
  @spec get_usage(thread_id()) :: {:ok, session_state()} | {:error, :not_found}
  def get_usage(thread_id) do
    GenServer.call(__MODULE__, {:get_usage, thread_id})
  end

  @doc """
  Reset usage for a thread (e.g., after summarization).
  """
  @spec reset_usage(thread_id(), non_neg_integer()) :: :ok
  def reset_usage(thread_id, new_tokens \\ 0) do
    GenServer.call(__MODULE__, {:reset_usage, thread_id, new_tokens})
  end

  @doc """
  Set model type for a thread (affects limit calculation).
  """
  @spec set_model(thread_id(), String.t() | atom()) :: :ok
  def set_model(thread_id, model) do
    GenServer.call(__MODULE__, {:set_model, thread_id, model})
  end

  @doc """
  Get all active sessions.
  """
  @spec all_sessions() :: [session_state()]
  def all_sessions do
    GenServer.call(__MODULE__, :all_sessions)
  end

  @doc """
  Get aggregate statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Check if a thread should be summarized (above threshold).
  """
  @spec should_summarize?(thread_id()) :: boolean()
  def should_summarize?(thread_id) do
    case get_usage(thread_id) do
      {:ok, %{status: :summarize_recommended}} -> true
      _ -> false
    end
  end

  @impl true
  def init(_opts) do
    # Create ETS table for fast reads
    Mimo.EtsSafe.ensure_table(@table_name, [
      :named_table,
      :set,
      :public,
      read_concurrency: true
    ])

    # Schedule cleanup
    schedule_cleanup()

    state = %{
      sessions: %{},
      total_tokens_tracked: 0,
      total_operations: 0,
      warnings_issued: 0,
      summarize_recommendations: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:track_usage, thread_id, tokens, opts}, _from, state) do
    model = Keyword.get(opts, :model, "opus")
    model_type = BudgetAllocator.model_type(model)
    model_limit = get_model_limit(model)

    session =
      case Map.get(state.sessions, thread_id) do
        nil ->
          # New session
          %{
            thread_id: thread_id,
            tokens_used: tokens,
            model_limit: model_limit,
            model_type: model_type,
            percentage: tokens / model_limit,
            status: :ok,
            started_at: DateTime.utc_now(),
            last_updated: DateTime.utc_now(),
            history: [tokens]
          }

        existing ->
          # Update existing session
          new_total = existing.tokens_used + tokens
          history = [tokens | Enum.take(existing.history, 99)]

          %{
            existing
            | tokens_used: new_total,
              model_limit: model_limit,
              percentage: new_total / model_limit,
              last_updated: DateTime.utc_now(),
              history: history
          }
      end

    # Determine status
    session = update_status(session)

    # Update ETS cache
    :ets.insert(@table_name, {thread_id, session})

    # Update state
    new_sessions = Map.put(state.sessions, thread_id, session)

    new_state = %{
      state
      | sessions: new_sessions,
        total_tokens_tracked: state.total_tokens_tracked + tokens,
        total_operations: state.total_operations + 1,
        warnings_issued:
          if(session.status in [:warning, :critical],
            do: state.warnings_issued + 1,
            else: state.warnings_issued
          ),
        summarize_recommendations:
          if(session.status == :summarize_recommended,
            do: state.summarize_recommendations + 1,
            else: state.summarize_recommendations
          )
    }

    # Log warnings
    log_status_change(session)

    {:reply, {:ok, session}, new_state}
  end

  @impl true
  def handle_call({:get_usage, thread_id}, _from, state) do
    case Map.get(state.sessions, thread_id) do
      nil -> {:reply, {:error, :not_found}, state}
      session -> {:reply, {:ok, session}, state}
    end
  end

  @impl true
  def handle_call({:reset_usage, thread_id, new_tokens}, _from, state) do
    case Map.get(state.sessions, thread_id) do
      nil ->
        {:reply, :ok, state}

      session ->
        updated = %{
          session
          | tokens_used: new_tokens,
            percentage: new_tokens / session.model_limit,
            status: :ok,
            last_updated: DateTime.utc_now(),
            history: [new_tokens]
        }

        :ets.insert(@table_name, {thread_id, updated})
        new_sessions = Map.put(state.sessions, thread_id, updated)
        {:reply, :ok, %{state | sessions: new_sessions}}
    end
  end

  @impl true
  def handle_call({:set_model, thread_id, model}, _from, state) do
    model_type = BudgetAllocator.model_type(model)
    model_limit = get_model_limit(model)

    case Map.get(state.sessions, thread_id) do
      nil ->
        {:reply, :ok, state}

      session ->
        updated =
          %{
            session
            | model_type: model_type,
              model_limit: model_limit,
              percentage: session.tokens_used / model_limit
          }
          |> update_status()

        :ets.insert(@table_name, {thread_id, updated})
        new_sessions = Map.put(state.sessions, thread_id, updated)
        {:reply, :ok, %{state | sessions: new_sessions}}
    end
  end

  @impl true
  def handle_call(:all_sessions, _from, state) do
    sessions = Map.values(state.sessions)
    {:reply, sessions, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    active_sessions = Enum.count(state.sessions)

    avg_usage =
      if active_sessions > 0 do
        state.sessions
        |> Map.values()
        |> Enum.map(& &1.percentage)
        |> Enum.sum()
        |> Kernel./(active_sessions)
      else
        0.0
      end

    status_counts =
      state.sessions
      |> Map.values()
      |> Enum.group_by(& &1.status)
      |> Enum.map(fn {status, sessions} -> {status, length(sessions)} end)
      |> Enum.into(%{})

    stats = %{
      active_sessions: active_sessions,
      total_tokens_tracked: state.total_tokens_tracked,
      total_operations: state.total_operations,
      warnings_issued: state.warnings_issued,
      summarize_recommendations: state.summarize_recommendations,
      average_usage_percentage: Float.round(avg_usage * 100, 1),
      status_distribution: status_counts,
      thresholds: %{
        warning: @warning_threshold,
        critical: @critical_threshold,
        summarize: @summarize_threshold
      }
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cutoff = DateTime.add(DateTime.utc_now(), -div(@session_ttl, 1000), :second)

    # Remove stale sessions
    active_sessions =
      state.sessions
      |> Enum.filter(fn {_id, session} ->
        DateTime.compare(session.last_updated, cutoff) == :gt
      end)
      |> Enum.into(%{})

    # Clean ETS
    stale_ids = Map.keys(state.sessions) -- Map.keys(active_sessions)
    Enum.each(stale_ids, &:ets.delete(@table_name, &1))

    unless Enum.empty?(stale_ids) do
      Logger.debug("[ContextWindowManager] Cleaned #{length(stale_ids)} stale sessions")
    end

    schedule_cleanup()
    {:noreply, %{state | sessions: active_sessions}}
  end

  defp update_status(session) do
    status =
      cond do
        session.percentage >= @summarize_threshold -> :summarize_recommended
        session.percentage >= @critical_threshold -> :critical
        session.percentage >= @warning_threshold -> :warning
        true -> :ok
      end

    %{session | status: status}
  end

  defp log_status_change(session) do
    case session.status do
      :warning ->
        Logger.warning(
          "[ContextWindow] Thread #{session.thread_id}: #{Float.round(session.percentage * 100, 1)}% used (#{session.tokens_used}/#{session.model_limit})"
        )

      :critical ->
        Logger.warning(
          "[ContextWindow] CRITICAL: Thread #{session.thread_id}: #{Float.round(session.percentage * 100, 1)}% used"
        )

      :summarize_recommended ->
        Logger.info(
          "[ContextWindow] Summarization recommended for #{session.thread_id}: #{Float.round(session.percentage * 100, 1)}% used"
        )

      _ ->
        :ok
    end
  end

  defp get_model_limit(model) when is_binary(model) do
    model_lower = String.downcase(model)

    cond do
      String.contains?(model_lower, "gemini") and String.contains?(model_lower, "flash") ->
        1_000_000

      String.contains?(model_lower, "opus") ->
        200_000

      String.contains?(model_lower, "sonnet") ->
        200_000

      String.contains?(model_lower, "haiku") ->
        200_000

      String.contains?(model_lower, "gpt-4") and String.contains?(model_lower, "turbo") ->
        128_000

      String.contains?(model_lower, "gpt-4") ->
        32_000

      String.contains?(model_lower, "gpt-3.5") ->
        16_000

      true ->
        @default_model_limit
    end
  end

  defp get_model_limit(_), do: @default_model_limit

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
