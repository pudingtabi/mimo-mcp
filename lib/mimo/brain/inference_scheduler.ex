defmodule Mimo.Brain.InferenceScheduler do
  @moduledoc """
  Smart LLM Orchestration Layer - Efficient use of external LLM APIs.

  Part of revised P4 in the Intelligence Roadmap.

  Instead of a local small model, this module optimizes use of existing
  LLM infrastructure (Cerebras primary, OpenRouter fallback) by:

  1. **Priority Queue**: User-facing requests > Background tasks
  2. **Batching**: Combine similar requests into single LLM calls
  3. **Rate Limiting**: Respect API limits, retry gracefully
  4. **Idle Processing**: Run background tasks only when user is idle

  ## Usage

      # For user-facing (immediate)
      InferenceScheduler.request(:high, prompt, opts)

      # For background tasks (can wait)
      InferenceScheduler.request(:low, prompt, opts)

      # Check if we can process background tasks
      if InferenceScheduler.idle?() do
        # Safe to run heavy synthesis
      end

  ## Integration

  - Synthesizer, ContradictionGuard call with :low priority
  - ask_mimo, tool execution call with :high priority
  - Circuit breaker integration for graceful degradation
  """

  use GenServer
  require Logger

  alias Mimo.Brain.LLM

  @idle_threshold_ms 30_000  # 30 seconds of no high-priority activity = idle
  @batch_timeout_ms 1_000    # Wait up to 1 second to batch requests
  @max_batch_size 5          # Maximum requests per batch
  @rate_limit_backoff_ms 60_000  # Wait 1 minute after rate limit

  # =============================================================================
  # Public API
  # =============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Submit an inference request with priority.

  ## Options
    - :priority - :high (user-facing) or :low (background)
    - :max_tokens, :temperature, :format - passed to LLM.complete()
    - :callback - function to call with result (for async)

  Returns {:ok, result} or {:error, reason}
  """
  @spec request(atom(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def request(priority, prompt, opts \\ []) do
    timeout = if priority == :high, do: 30_000, else: 120_000
    GenServer.call(__MODULE__, {:request, priority, prompt, opts}, timeout)
  catch
    :exit, {:timeout, _} ->
      Logger.warning("[InferenceScheduler] Request timed out (priority: #{priority})")
      {:error, :timeout}
  end

  @doc """
  Submit async request, result delivered via callback.
  """
  @spec request_async(atom(), String.t(), keyword(), function()) :: :ok
  def request_async(priority, prompt, opts, callback) when is_function(callback, 1) do
    GenServer.cast(__MODULE__, {:request_async, priority, prompt, opts, callback})
  end

  @doc """
  Check if the system is idle (safe for background processing).
  """
  @spec idle?() :: boolean()
  def idle? do
    GenServer.call(__MODULE__, :idle?)
  end

  @doc """
  Record user activity (resets idle timer).
  """
  @spec touch() :: :ok
  def touch do
    GenServer.cast(__MODULE__, :touch)
  end

  @doc """
  Get scheduler statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # =============================================================================
  # GenServer Callbacks
  # =============================================================================

  @impl true
  def init(_opts) do
    state = %{
      last_high_priority: DateTime.utc_now(),
      high_queue: :queue.new(),
      low_queue: :queue.new(),
      pending_batch: [],
      batch_timer: nil,
      rate_limited_until: nil,
      stats: %{
        total_requests: 0,
        high_priority_requests: 0,
        low_priority_requests: 0,
        batched_requests: 0,
        rate_limited_skips: 0
      }
    }

    # Start processing loop
    schedule_process()

    Logger.info("[InferenceScheduler] Initialized")
    {:ok, state}
  end

  @impl true
  def handle_call({:request, priority, prompt, opts}, from, state) do
    state = update_stats(state, priority)
    state = if priority == :high, do: %{state | last_high_priority: DateTime.utc_now()}, else: state

    # Check rate limiting
    if rate_limited?(state) and priority == :low do
      {:reply, {:error, :rate_limited}, update_stat(state, :rate_limited_skips)}
    else
      # Add to appropriate queue
      request = %{from: from, prompt: prompt, opts: opts, priority: priority}

      new_state = case priority do
        :high ->
          # Process high priority immediately
          process_single_request(request, state)

        :low ->
          # Add to batch
          add_to_batch(request, state)
      end

      {:noreply, new_state}
    end
  end

  @impl true
  def handle_call(:idle?, _from, state) do
    idle = is_idle?(state)
    {:reply, idle, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = Map.merge(state.stats, %{
      queue_sizes: %{
        high: :queue.len(state.high_queue),
        low: :queue.len(state.low_queue)
      },
      pending_batch: length(state.pending_batch),
      rate_limited: rate_limited?(state),
      idle: is_idle?(state)
    })
    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:request_async, priority, prompt, opts, callback}, state) do
    state = update_stats(state, priority)

    # Spawn async processing
    Task.Supervisor.start_child(Mimo.TaskSupervisor, fn ->
      result = do_llm_request(prompt, opts)
      callback.(result)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast(:touch, state) do
    {:noreply, %{state | last_high_priority: DateTime.utc_now()}}
  end

  @impl true
  def handle_info(:process, state) do
    new_state =
      if is_idle?(state) and length(state.pending_batch) > 0 do
        process_batch(state)
      else
        state
      end

    schedule_process()
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:batch_timeout, state) do
    # Process whatever we have in the batch
    new_state = process_batch(state)
    {:noreply, %{new_state | batch_timer: nil}}
  end

  # =============================================================================
  # Private Implementation
  # =============================================================================

  defp process_single_request(request, state) do
    result = do_llm_request(request.prompt, request.opts)

    new_state = case result do
      {:error, {:cerebras_rate_limited, _}} ->
        %{state | rate_limited_until: DateTime.add(DateTime.utc_now(), @rate_limit_backoff_ms, :millisecond)}

      _ ->
        state
    end

    GenServer.reply(request.from, result)
    new_state
  end

  defp add_to_batch(request, state) do
    new_batch = [request | state.pending_batch]

    # Start batch timer if not already running
    timer = state.batch_timer || Process.send_after(self(), :batch_timeout, @batch_timeout_ms)

    # Process immediately if batch is full
    if length(new_batch) >= @max_batch_size do
      process_batch(%{state | pending_batch: new_batch, batch_timer: nil})
    else
      %{state | pending_batch: new_batch, batch_timer: timer}
    end
  end

  defp process_batch(%{pending_batch: []} = state), do: state
  defp process_batch(state) do
    batch = state.pending_batch

    # Cancel timer if running
    if state.batch_timer, do: Process.cancel_timer(state.batch_timer)

    # Process each request (could be batched into single LLM call in future)
    Enum.each(batch, fn request ->
      result = do_llm_request(request.prompt, request.opts)
      GenServer.reply(request.from, result)
    end)

    %{state |
      pending_batch: [],
      batch_timer: nil,
      stats: Map.update!(state.stats, :batched_requests, & &1 + length(batch))
    }
  end

  defp do_llm_request(prompt, opts) do
    max_tokens = Keyword.get(opts, :max_tokens, 200)
    temperature = Keyword.get(opts, :temperature, 0.1)
    format = Keyword.get(opts, :format, :text)
    raw = Keyword.get(opts, :raw, false)

    LLM.complete(prompt,
      max_tokens: max_tokens,
      temperature: temperature,
      format: format,
      raw: raw
    )
  end

  defp is_idle?(state) do
    last = state.last_high_priority
    now = DateTime.utc_now()
    DateTime.diff(now, last, :millisecond) > @idle_threshold_ms
  end

  defp rate_limited?(state) do
    case state.rate_limited_until do
      nil -> false
      until -> DateTime.compare(DateTime.utc_now(), until) == :lt
    end
  end

  defp update_stats(state, priority) do
    state
    |> update_stat(:total_requests)
    |> update_stat(if priority == :high, do: :high_priority_requests, else: :low_priority_requests)
  end

  defp update_stat(state, key) do
    %{state | stats: Map.update!(state.stats, key, & &1 + 1)}
  end

  defp schedule_process do
    Process.send_after(self(), :process, 5_000)  # Check every 5 seconds
  end
end
