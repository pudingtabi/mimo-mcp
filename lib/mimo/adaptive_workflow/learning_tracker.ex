defmodule Mimo.AdaptiveWorkflow.LearningTracker do
  @moduledoc """
  Learning Tracker for SPEC-054: Adaptive Workflow Engine.

  Tracks workflow execution outcomes and learns optimal patterns
  for different model/task combinations. Updates success metrics
  and refines pattern recommendations.

  ## Learning Signals

  The tracker collects and analyzes:
  - Execution success/failure rates
  - Time to completion by pattern
  - Step-level failure points
  - Model-pattern affinity scores
  - User feedback (implicit and explicit)

  ## Architecture

           Execution Events
                 │
                 ▼
    ┌────────────────────────────┐
    │     LearningTracker        │
    │  ┌──────────────────────┐  │
    │  │  Event Collector    │  │
    │  │  - Success/failure  │  │
    │  │  - Latency metrics  │  │
    │  │  - Step outcomes    │  │
    │  └──────────┬──────────┘  │
    │             │             │
    │             ▼             │
    │  ┌──────────────────────┐  │
    │  │  Metric Aggregator   │  │
    │  │  - Rolling averages │  │
    │  │  - Trend detection  │  │
    │  │  - Anomaly flagging │  │
    │  └──────────┬──────────┘  │
    │             │             │
    │             ▼             │
    │  ┌──────────────────────┐  │
    │  │  Pattern Optimizer   │  │
    │  │  - Success rate calc│  │
    │  │  - Affinity updates │  │
    │  │  - Threshold adjust │  │
    │  └──────────────────────┘  │
    └────────────────────────────┘
               │
               ▼
    Pattern Registry + Model Profiler

  """
  use GenServer
  require Logger

  alias Mimo.Workflow.PatternRegistry
  alias Mimo.AdaptiveWorkflow.ModelProfiler

  # =============================================================================
  # Types
  # =============================================================================

  @type learning_event :: %{
          execution_id: String.t(),
          pattern_name: String.t(),
          model_id: String.t() | nil,
          outcome: :success | :failure | :partial,
          duration_ms: pos_integer(),
          step_outcomes: [step_outcome()],
          context: map(),
          timestamp: DateTime.t()
        }

  @type step_outcome :: %{
          step_name: String.t(),
          tool: String.t(),
          success: boolean(),
          duration_ms: pos_integer(),
          error: String.t() | nil
        }

  @type affinity_score :: %{
          pattern_name: String.t(),
          model_id: String.t(),
          score: float(),
          confidence: float(),
          sample_count: pos_integer()
        }

  # Minimum samples before we trust affinity scores
  @min_samples 5
  
  # Decay factor for exponential moving average
  @decay_factor 0.1

  # =============================================================================
  # GenServer
  # =============================================================================

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    state = %{
      # Recent events buffer
      event_buffer: [],
      # Model-pattern affinity scores
      affinities: load_affinities(),
      # Pattern success rates
      pattern_stats: %{},
      # Step failure hotspots
      failure_hotspots: %{},
      # Last aggregation time
      last_aggregation: DateTime.utc_now()
    }
    
    # Schedule periodic aggregation
    schedule_aggregation()
    
    {:ok, state}
  end

  # =============================================================================
  # Public API
  # =============================================================================

  @doc """
  Record a learning event from a completed workflow execution.

  This is the primary entry point for the learning system.
  """
  @spec record_event(learning_event()) :: :ok
  def record_event(event) do
    GenServer.cast(__MODULE__, {:record_event, event})
  end

  @doc """
  Record a simple success/failure for a pattern.

  Convenience wrapper for simple outcome tracking.
  """
  @spec record_outcome(String.t(), :success | :failure, keyword()) :: :ok
  def record_outcome(pattern_name, outcome, opts \\ []) do
    event = %{
      execution_id: Keyword.get(opts, :execution_id, generate_id()),
      pattern_name: pattern_name,
      model_id: Keyword.get(opts, :model_id),
      outcome: outcome,
      duration_ms: Keyword.get(opts, :duration_ms, 0),
      step_outcomes: Keyword.get(opts, :step_outcomes, []),
      context: Keyword.get(opts, :context, %{}),
      timestamp: DateTime.utc_now()
    }
    
    record_event(event)
  end

  @doc """
  Get the affinity score between a model and pattern.

  Returns how well-suited a model is for executing a pattern
  based on historical performance.
  """
  @spec get_affinity(String.t(), String.t()) :: {:ok, affinity_score()} | {:error, :no_data}
  def get_affinity(model_id, pattern_name) do
    GenServer.call(__MODULE__, {:get_affinity, model_id, pattern_name})
  end

  @doc """
  Get the best patterns for a model.

  Returns patterns sorted by affinity score.
  """
  @spec get_best_patterns(String.t(), keyword()) :: [affinity_score()]
  def get_best_patterns(model_id, opts \\ []) do
    GenServer.call(__MODULE__, {:get_best_patterns, model_id, opts})
  end

  @doc """
  Get the best models for a pattern.

  Returns models sorted by affinity score.
  """
  @spec get_best_models(String.t(), keyword()) :: [affinity_score()]
  def get_best_models(pattern_name, opts \\ []) do
    GenServer.call(__MODULE__, {:get_best_models, pattern_name, opts})
  end

  @doc """
  Get pattern statistics.

  Returns aggregated stats for a pattern.
  """
  @spec get_pattern_stats(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_pattern_stats(pattern_name) do
    GenServer.call(__MODULE__, {:get_pattern_stats, pattern_name})
  end

  @doc """
  Get failure hotspots.

  Returns steps that frequently fail across patterns.
  """
  @spec get_failure_hotspots(keyword()) :: [map()]
  def get_failure_hotspots(opts \\ []) do
    GenServer.call(__MODULE__, {:get_failure_hotspots, opts})
  end

  @doc """
  Force aggregation of buffered events.

  Useful for testing or when immediate updates are needed.
  """
  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @doc """
  Get learning statistics.

  Returns overall tracker health and metrics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # =============================================================================
  # GenServer Callbacks
  # =============================================================================

  @impl true
  def handle_cast({:record_event, event}, state) do
    # Buffer the event
    new_buffer = [event | state.event_buffer]
    
    # If buffer is large enough, trigger aggregation
    new_state = if length(new_buffer) >= 10 do
      aggregate_events(%{state | event_buffer: new_buffer})
    else
      %{state | event_buffer: new_buffer}
    end
    
    {:noreply, new_state}
  end

  @impl true
  def handle_call({:get_affinity, model_id, pattern_name}, _from, state) do
    key = {model_id, pattern_name}
    
    case Map.get(state.affinities, key) do
      nil -> {:reply, {:error, :no_data}, state}
      affinity -> {:reply, {:ok, affinity}, state}
    end
  end

  @impl true
  def handle_call({:get_best_patterns, model_id, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 10)
    min_confidence = Keyword.get(opts, :min_confidence, 0.3)
    
    best = state.affinities
    |> Enum.filter(fn {{mid, _pn}, aff} -> 
      mid == model_id and aff.confidence >= min_confidence
    end)
    |> Enum.map(fn {_key, aff} -> aff end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
    
    {:reply, best, state}
  end

  @impl true
  def handle_call({:get_best_models, pattern_name, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 10)
    min_confidence = Keyword.get(opts, :min_confidence, 0.3)
    
    best = state.affinities
    |> Enum.filter(fn {{_mid, pn}, aff} -> 
      pn == pattern_name and aff.confidence >= min_confidence
    end)
    |> Enum.map(fn {_key, aff} -> aff end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
    
    {:reply, best, state}
  end

  @impl true
  def handle_call({:get_pattern_stats, pattern_name}, _from, state) do
    case Map.get(state.pattern_stats, pattern_name) do
      nil -> {:reply, {:error, :not_found}, state}
      stats -> {:reply, {:ok, stats}, state}
    end
  end

  @impl true
  def handle_call({:get_failure_hotspots, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 20)
    
    hotspots = state.failure_hotspots
    |> Enum.map(fn {key, stats} -> Map.put(stats, :key, key) end)
    |> Enum.sort_by(& &1.failure_count, :desc)
    |> Enum.take(limit)
    
    {:reply, hotspots, state}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    new_state = aggregate_events(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      buffered_events: length(state.event_buffer),
      affinity_count: map_size(state.affinities),
      pattern_count: map_size(state.pattern_stats),
      hotspot_count: map_size(state.failure_hotspots),
      last_aggregation: state.last_aggregation
    }
    
    {:reply, stats, state}
  end

  @impl true
  def handle_info(:aggregate, state) do
    new_state = aggregate_events(state)
    schedule_aggregation()
    {:noreply, new_state}
  end

  # =============================================================================
  # Aggregation Logic
  # =============================================================================

  defp aggregate_events(state) do
    events = state.event_buffer
    
    if Enum.empty?(events) do
      state
    else
      # Update affinities
      new_affinities = update_affinities(state.affinities, events)
      
      # Update pattern stats
      new_pattern_stats = update_pattern_stats(state.pattern_stats, events)
      
      # Update failure hotspots
      new_hotspots = update_failure_hotspots(state.failure_hotspots, events)
      
      # Persist changes
      persist_affinities(new_affinities)
      
      # Notify pattern registry of updates
      notify_pattern_updates(events)
      
      # Notify model profiler of performance data
      notify_model_updates(events)
      
      %{state |
        event_buffer: [],
        affinities: new_affinities,
        pattern_stats: new_pattern_stats,
        failure_hotspots: new_hotspots,
        last_aggregation: DateTime.utc_now()
      }
    end
  end

  defp update_affinities(affinities, events) do
    Enum.reduce(events, affinities, fn event, acc ->
      # Skip events without model_id
      if event.model_id do
        key = {event.model_id, event.pattern_name}
        current = Map.get(acc, key, %{
          pattern_name: event.pattern_name,
          model_id: event.model_id,
          score: 0.5,
          confidence: 0.0,
          sample_count: 0,
          successes: 0,
          total_duration_ms: 0
        })
        
        # Update with exponential moving average
        success_val = if event.outcome == :success, do: 1.0, else: 0.0
        new_score = current.score * (1 - @decay_factor) + success_val * @decay_factor
        
        # Update sample count and calculate confidence
        new_sample_count = current.sample_count + 1
        new_confidence = calculate_confidence(new_sample_count)
        
        new_successes = current.successes + (if event.outcome == :success, do: 1, else: 0)
        new_duration = current.total_duration_ms + event.duration_ms
        
        updated = %{current |
          score: Float.round(new_score, 3),
          confidence: new_confidence,
          sample_count: new_sample_count,
          successes: new_successes,
          total_duration_ms: new_duration
        }
        
        Map.put(acc, key, updated)
      else
        acc
      end
    end)
  end

  defp calculate_confidence(sample_count) do
    # Confidence increases with sample count, plateaus at high counts
    min(1.0, Float.round(sample_count / (@min_samples * 4), 2))
  end

  defp update_pattern_stats(stats, events) do
    Enum.reduce(events, stats, fn event, acc ->
      current = Map.get(acc, event.pattern_name, %{
        pattern_name: event.pattern_name,
        total_executions: 0,
        successes: 0,
        failures: 0,
        partial: 0,
        total_duration_ms: 0,
        avg_duration_ms: 0,
        last_execution: nil
      })
      
      {successes, failures, partial} = case event.outcome do
        :success -> {current.successes + 1, current.failures, current.partial}
        :failure -> {current.successes, current.failures + 1, current.partial}
        :partial -> {current.successes, current.failures, current.partial + 1}
      end
      
      total = current.total_executions + 1
      total_duration = current.total_duration_ms + event.duration_ms
      avg_duration = div(total_duration, total)
      
      updated = %{current |
        total_executions: total,
        successes: successes,
        failures: failures,
        partial: partial,
        total_duration_ms: total_duration,
        avg_duration_ms: avg_duration,
        last_execution: event.timestamp
      }
      
      Map.put(acc, event.pattern_name, updated)
    end)
  end

  defp update_failure_hotspots(hotspots, events) do
    # Extract step failures from events
    step_failures = events
    |> Enum.flat_map(fn event ->
      event.step_outcomes
      |> Enum.filter(fn so -> not so.success end)
      |> Enum.map(fn so ->
        %{
          pattern_name: event.pattern_name,
          step_name: so.step_name,
          tool: so.tool,
          error: so.error
        }
      end)
    end)
    
    # Aggregate failures by step
    Enum.reduce(step_failures, hotspots, fn failure, acc ->
      key = {failure.pattern_name, failure.step_name}
      
      current = Map.get(acc, key, %{
        pattern_name: failure.pattern_name,
        step_name: failure.step_name,
        tool: failure.tool,
        failure_count: 0,
        error_samples: []
      })
      
      # Keep last 5 error samples
      error_samples = [failure.error | Enum.take(current.error_samples, 4)]
      |> Enum.filter(& &1)
      
      updated = %{current |
        failure_count: current.failure_count + 1,
        error_samples: error_samples
      }
      
      Map.put(acc, key, updated)
    end)
  end

  # =============================================================================
  # Persistence
  # =============================================================================

  defp load_affinities do
    # Load from database if available
    # For now, start empty
    %{}
  end

  defp persist_affinities(_affinities) do
    # Persist to database
    # TODO: Implement with Ecto schema
    :ok
  end

  # =============================================================================
  # Notifications
  # =============================================================================

  defp notify_pattern_updates(events) do
    # Group events by pattern
    by_pattern = Enum.group_by(events, & &1.pattern_name)
    
    Enum.each(by_pattern, fn {pattern_name, pattern_events} ->
      successes = Enum.count(pattern_events, & &1.outcome == :success)
      total = length(pattern_events)
      success_rate = if total > 0, do: successes / total, else: 0.5

      # Update pattern registry with new success rate
      PatternRegistry.update_pattern_metrics(pattern_name, success_rate > 0.5, 0)
    end)
  rescue
    _ -> :ok
  end

  defp notify_model_updates(events) do
    # Group events by model
    by_model = events
    |> Enum.filter(& &1.model_id)
    |> Enum.group_by(& &1.model_id)
    
    Enum.each(by_model, fn {model_id, model_events} ->
      Enum.each(model_events, fn event ->
        metrics = %{
          success: event.outcome == :success,
          latency_ms: event.duration_ms
        }
        
        ModelProfiler.record_performance(model_id, event.pattern_name, metrics)
      end)
    end)
  rescue
    _ -> :ok
  end

  # =============================================================================
  # Helpers
  # =============================================================================

  defp generate_id do
    "learn_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  end

  defp schedule_aggregation do
    # Aggregate every 30 seconds
    Process.send_after(self(), :aggregate, :timer.seconds(30))
  end
end
