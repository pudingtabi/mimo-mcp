defmodule Mimo.Brain.AttentionLearner do
  @moduledoc """
  Online learning for spreading activation attention weights.

  Implements reinforcement learning without external ML frameworks,
  using exponential moving average updates based on feedback signals.

  ## Machine Learning Approach: Contextual Bandits

  The attention weights form a policy that selects how to weight
  different factors when scoring neighbors. We learn which factors
  best predict successful retrievals.

  **Weight Factors:**
  - `edge_weight` - Learned graph structure (Hebbian LTP)
  - `embedding_sim` - Semantic similarity
  - `recency` - Temporal relevance
  - `access` - Usage frequency

  ## Learning Algorithm

  For each retrieval that receives feedback:
  1. Compute contribution of each factor to the attention score
  2. If positive feedback: increase weight of contributing factors
  3. If negative feedback: decrease weight of contributing factors
  4. Normalize weights to sum to 1.0

  ## Feedback Signals

  - `:positive` - Memory was useful (re-accessed, led to success)
  - `:negative` - Memory was not useful (ignored, led to correction)
  - `:neutral` - No signal (default)

  ## Persistence

  Learned weights are stored in ETS during runtime and can be
  persisted to the database for cross-session learning.

  ## Example

      # Record positive feedback for a retrieval
      AttentionLearner.feedback(:positive, memory_id, context)

      # Get current learned weights
      weights = AttentionLearner.get_weights()
  """

  use GenServer
  require Logger

  # Base learning rate
  @learning_rate 0.01

  # Minimum weight for any factor (prevents collapse)
  @min_weight 0.05

  # Initial weights (will be learned)
  @initial_weights %{
    edge_weight: 0.4,
    embedding_sim: 0.3,
    recency: 0.2,
    access: 0.1
  }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Record feedback for a memory retrieval.

  ## Parameters

    - `signal` - `:positive`, `:negative`, or `:neutral`
    - `memory_id` - The memory that was retrieved
    - `context` - Map with factor contributions used in scoring

  ## Context Format

      %{
        edge_weight: 0.8,      # The edge weight used
        embedding_sim: 0.6,    # The similarity score
        recency: 0.9,          # The recency score
        access: 0.3            # The access score
      }
  """
  @spec feedback(atom(), integer(), map()) :: :ok
  def feedback(signal, memory_id, context \\ %{}) when signal in [:positive, :negative, :neutral] do
    GenServer.cast(__MODULE__, {:feedback, signal, memory_id, context})
  end

  @doc """
  Get current learned attention weights.
  """
  @spec get_weights() :: map()
  def get_weights do
    GenServer.call(__MODULE__, :get_weights)
  catch
    :exit, _ -> @initial_weights
  end

  @doc """
  Reset weights to initial values.
  """
  def reset_weights do
    GenServer.call(__MODULE__, :reset_weights)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Get learning statistics.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  catch
    :exit, _ -> %{status: :unavailable}
  end

  @impl true
  def init(_opts) do
    state = %{
      weights: @initial_weights,
      positive_count: 0,
      negative_count: 0,
      total_updates: 0,
      weight_history: [@initial_weights]
    }

    Logger.info("AttentionLearner initialized with weights: #{inspect(@initial_weights)}")
    {:ok, state}
  end

  @impl true
  def handle_call(:get_weights, _from, state) do
    {:reply, state.weights, state}
  end

  @impl true
  def handle_call(:reset_weights, _from, state) do
    new_state = %{state | weights: @initial_weights, weight_history: [@initial_weights]}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      weights: state.weights,
      positive_count: state.positive_count,
      negative_count: state.negative_count,
      total_updates: state.total_updates,
      history_length: length(state.weight_history)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:feedback, :neutral, _memory_id, _context}, state) do
    # Neutral feedback - no update
    {:noreply, state}
  end

  @impl true
  def handle_cast({:feedback, signal, _memory_id, context}, state) do
    # Compute update based on feedback
    new_weights = update_weights(state.weights, context, signal)

    # Track statistics
    new_state =
      case signal do
        :positive ->
          %{
            state
            | weights: new_weights,
              positive_count: state.positive_count + 1,
              total_updates: state.total_updates + 1,
              weight_history: [new_weights | Enum.take(state.weight_history, 99)]
          }

        :negative ->
          %{
            state
            | weights: new_weights,
              negative_count: state.negative_count + 1,
              total_updates: state.total_updates + 1,
              weight_history: [new_weights | Enum.take(state.weight_history, 99)]
          }
      end

    Logger.debug("AttentionLearner updated weights: #{inspect(new_weights)}")
    {:noreply, new_state}
  end

  defp update_weights(current_weights, context, signal) do
    # Compute contribution of each factor
    contributions = compute_contributions(current_weights, context)

    # Direction based on signal
    direction = if signal == :positive, do: 1.0, else: -1.0

    # Update each weight
    updated =
      Enum.reduce(contributions, current_weights, fn {factor, contribution}, weights ->
        current = Map.get(weights, factor, 0.25)

        # Learning update:
        # positive: increase weight proportional to contribution
        # negative: decrease weight proportional to contribution
        delta = @learning_rate * contribution * direction

        # Bounded update
        new_value =
          if direction > 0 do
            # Positive: grow toward 1
            current + delta * (1.0 - current)
          else
            # Negative: shrink toward 0
            current + delta * current
          end

        # Clamp to valid range
        Map.put(weights, factor, max(@min_weight, min(1.0, new_value)))
      end)

    # Normalize to sum to 1
    normalize_weights(updated)
  end

  defp compute_contributions(weights, context) do
    # For each factor, compute its contribution to the total score
    # contribution = (factor_value × weight) / total_score

    factors = [:edge_weight, :embedding_sim, :recency, :access]

    scores =
      Enum.map(factors, fn factor ->
        weight = Map.get(weights, factor, 0.25)
        value = Map.get(context, factor, 0.5)
        {factor, weight * value}
      end)

    total = Enum.reduce(scores, 0, fn {_, score}, acc -> acc + score end)

    if total == 0 do
      # Uniform contribution
      Enum.map(factors, fn f -> {f, 0.25} end) |> Map.new()
    else
      Enum.map(scores, fn {factor, score} -> {factor, score / total} end) |> Map.new()
    end
  end

  defp normalize_weights(weights) do
    total = Map.values(weights) |> Enum.sum()

    if total == 0 do
      @initial_weights
    else
      Map.new(weights, fn {k, v} -> {k, v / total} end)
    end
  end
end
