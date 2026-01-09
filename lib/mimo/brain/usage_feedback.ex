defmodule Mimo.Brain.UsageFeedback do
  @moduledoc """
  Memory Usage Feedback Loop - Learn which memories are actually useful.

  Part of P3 in the Intelligence Roadmap.

  This module tracks:
  1. Which memories are retrieved during searches
  2. Whether those memories led to successful outcomes
  3. A "helpfulness score" that adjusts future ranking

  Over time, frequently useful memories rise in rank, while noise sinks.

  ## Design

  The feedback loop:
  1. OBSERVE: Track every memory retrieval with context
  2. SIGNAL: Receive feedback on session outcome (useful/noise)
  3. ADJUST: Boost or decay helpfulness scores
  4. RANK: Future searches weight by helpfulness

  ## Storage

  We store feedback in the engram metadata:
  - `retrieval_count`: How many times this memory was retrieved
  - `usefulness_signals`: List of {session_id, useful?, timestamp}
  - `helpfulness_score`: Computed score (0.0-1.0, default 0.5)

  ## Integration

      # When memory is retrieved
      UsageFeedback.on_retrieved(memory_id, session_context)

      # When session ends with good outcome
      UsageFeedback.signal_useful(session_id, memory_ids)

      # When memory was noise
      UsageFeedback.signal_noise(session_id, memory_ids)

      # In search ranking
      adjusted_score = similarity * UsageFeedback.get_helpfulness(memory_id)
  """

  use GenServer
  require Logger

  alias Mimo.Brain.{AttentionLearner, Engram}
  alias Mimo.Repo

  @default_helpfulness 0.5
  @boost_amount 0.05
  @decay_amount 0.03

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Record that a memory was retrieved during a search.
  Call this whenever a memory is returned from search.
  """
  @spec on_retrieved(integer(), map()) :: :ok
  def on_retrieved(memory_id, context \\ %{}) do
    GenServer.cast(__MODULE__, {:retrieved, memory_id, context})
  end

  @doc """
  Signal that memories were useful in this session.
  Call when user interaction succeeds or explicitly approves.
  """
  @spec signal_useful(String.t(), [integer()]) :: :ok
  def signal_useful(session_id, memory_ids) when is_list(memory_ids) do
    GenServer.cast(__MODULE__, {:signal, :useful, session_id, memory_ids})
  end

  @doc """
  Signal that memories were noise/unhelpful.
  Call when user indicates irrelevant results or corrects.
  """
  @spec signal_noise(String.t(), [integer()]) :: :ok
  def signal_noise(session_id, memory_ids) when is_list(memory_ids) do
    GenServer.cast(__MODULE__, {:signal, :noise, session_id, memory_ids})
  end

  @doc """
  Get the helpfulness score for a memory.
  Returns 0.5 (neutral) if not found.
  """
  @spec get_helpfulness(integer()) :: float()
  def get_helpfulness(memory_id) do
    case GenServer.call(__MODULE__, {:get_helpfulness, memory_id}) do
      score when is_float(score) -> score
      _ -> @default_helpfulness
    end
  end

  @doc """
  Adjust a similarity score by helpfulness.
  Use in search ranking: adjusted = similarity * helpfulness_factor
  """
  @spec adjust_similarity(float(), integer()) :: float()
  def adjust_similarity(similarity, memory_id) do
    helpfulness = get_helpfulness(memory_id)
    # Helpfulness ranges 0-1, center at 0.5
    # Factor ranges 0.5-1.5 to modestly adjust ranking
    factor = 0.5 + helpfulness
    similarity * factor
  end

  @doc """
  Get feedback statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Force immediate processing of all pending signals.
  Useful for testing and benchmarks.
  """
  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :force_flush)
  end

  @impl true
  def init(_opts) do
    state = %{
      # memory_id => %{count, contexts}
      retrieval_buffer: %{},
      # [{type, session_id, memory_ids}]
      pending_signals: [],
      total_retrievals: 0,
      total_useful_signals: 0,
      total_noise_signals: 0
    }

    # Schedule periodic flush
    schedule_flush()

    Logger.info("[UsageFeedback] Initialized")
    {:ok, state}
  end

  @impl true
  def handle_cast({:retrieved, memory_id, context}, state) do
    buffer =
      Map.update(
        state.retrieval_buffer,
        memory_id,
        %{count: 1, contexts: [context]},
        fn existing ->
          %{
            existing
            | count: existing.count + 1,
              contexts: Enum.take([context | existing.contexts], 5)
          }
        end
      )

    {:noreply, %{state | retrieval_buffer: buffer, total_retrievals: state.total_retrievals + 1}}
  end

  @impl true
  def handle_cast({:signal, type, session_id, memory_ids}, state) do
    new_signals = [{type, session_id, memory_ids, DateTime.utc_now()} | state.pending_signals]

    # Process immediately if we have enough signals
    new_state =
      if length(new_signals) >= 5 do
        process_signals(new_signals, state)
      else
        %{state | pending_signals: new_signals}
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_call({:get_helpfulness, memory_id}, _from, state) do
    # Check buffer first, then DB
    score =
      case fetch_helpfulness_from_db(memory_id) do
        {:ok, s} -> s
        _ -> @default_helpfulness
      end

    {:reply, score, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      buffered_retrievals: map_size(state.retrieval_buffer),
      pending_signals: length(state.pending_signals),
      total_retrievals: state.total_retrievals,
      total_useful_signals: state.total_useful_signals,
      total_noise_signals: state.total_noise_signals
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:force_flush, _from, state) do
    new_state =
      if Enum.empty?(state.pending_signals) do
        flush_retrieval_counts(state)
      else
        process_signals(state.pending_signals, state)
      end

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:flush, state) do
    new_state =
      if Enum.empty?(state.pending_signals) do
        flush_retrieval_counts(state)
      else
        process_signals(state.pending_signals, state)
      end

    schedule_flush()
    {:noreply, new_state}
  end

  defp process_signals(signals, state) do
    # Group by memory_id
    {useful_count, noise_count} =
      Enum.reduce(signals, {0, 0}, fn {type, _session, memory_ids, _ts}, {u, n} ->
        Enum.each(memory_ids, fn id ->
          case type do
            :useful ->
              update_helpfulness(id, @boost_amount)
              # Also send positive feedback to AttentionLearner for online RL
              send_attention_feedback(id, :positive)

            :noise ->
              update_helpfulness(id, -@decay_amount)
              # Also send negative feedback to AttentionLearner
              send_attention_feedback(id, :negative)
          end
        end)

        case type do
          :useful -> {u + length(memory_ids), n}
          :noise -> {u, n + length(memory_ids)}
        end
      end)

    Logger.debug(
      "[UsageFeedback] Processed #{length(signals)} signals: +#{useful_count} useful, -#{noise_count} noise"
    )

    %{
      state
      | pending_signals: [],
        total_useful_signals: state.total_useful_signals + useful_count,
        total_noise_signals: state.total_noise_signals + noise_count
    }
  end

  defp flush_retrieval_counts(state) do
    # Update retrieval counts in DB
    Enum.each(state.retrieval_buffer, fn {memory_id, %{count: count}} ->
      update_retrieval_count(memory_id, count)
    end)

    %{state | retrieval_buffer: %{}}
  end

  defp update_helpfulness(memory_id, delta) do
    try do
      case Repo.get(Engram, memory_id) do
        nil ->
          :ok

        engram ->
          metadata = engram.metadata || %{}
          current = Map.get(metadata, "helpfulness_score", @default_helpfulness)

          # Clamp to 0.0-1.0
          new_score = max(0.0, min(1.0, current + delta))

          new_metadata = Map.put(metadata, "helpfulness_score", new_score)

          Engram.changeset(engram, %{metadata: new_metadata})
          |> Repo.update()
      end
    rescue
      e ->
        Logger.debug("[UsageFeedback] Failed to update helpfulness: #{Exception.message(e)}")
        :ok
    end
  end

  defp update_retrieval_count(memory_id, additional_count) do
    try do
      case Repo.get(Engram, memory_id) do
        nil ->
          :ok

        engram ->
          metadata = engram.metadata || %{}
          current = Map.get(metadata, "retrieval_count", 0)
          new_metadata = Map.put(metadata, "retrieval_count", current + additional_count)

          Engram.changeset(engram, %{metadata: new_metadata})
          |> Repo.update()
      end
    rescue
      _ -> :ok
    end
  end

  defp fetch_helpfulness_from_db(memory_id) do
    try do
      case Repo.get(Engram, memory_id) do
        nil ->
          {:error, :not_found}

        engram ->
          score = get_in(engram.metadata || %{}, ["helpfulness_score"]) || @default_helpfulness
          {:ok, score}
      end
    rescue
      _ -> {:error, :db_error}
    end
  end

  defp schedule_flush do
    # Flush every 30 seconds
    Process.send_after(self(), :flush, 30_000)
  end

  # Send feedback to AttentionLearner for online RL weight updates
  # This closes the loop: user feedback -> attention weight adjustment
  defp send_attention_feedback(memory_id, signal) do
    try do
      # Get the memory to extract context about how it was scored
      case Repo.get(Engram, memory_id) do
        nil ->
          :ok

        engram ->
          # Construct context with approximate factor contributions
          # These represent how the memory was likely scored during retrieval
          context = %{
            edge_weight: Map.get(engram.metadata || %{}, "graph_score", 0.5),
            embedding_sim: Map.get(engram, :similarity, 0.5),
            recency: compute_recency_factor(engram.inserted_at),
            access: compute_access_factor(engram.access_count)
          }

          AttentionLearner.feedback(signal, memory_id, context)
      end
    rescue
      _ -> :ok
    end
  end

  defp compute_recency_factor(nil), do: 0.5

  defp compute_recency_factor(inserted_at) do
    # Exponential decay based on age
    days_ago = NaiveDateTime.diff(NaiveDateTime.utc_now(), inserted_at, :second) / 86_400
    :math.exp(-0.1 * days_ago) |> max(0.01)
  end

  defp compute_access_factor(nil), do: 0.3
  defp compute_access_factor(0), do: 0.3

  defp compute_access_factor(count) when is_integer(count) do
    # Logarithmic scaling
    (:math.log(1 + count) / :math.log(1 + 100)) |> min(1.0)
  end
end
