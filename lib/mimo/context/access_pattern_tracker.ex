defmodule Mimo.Context.AccessPatternTracker do
  @moduledoc """
  SPEC-051 Phase 3: Access pattern tracking for predictive loading.

  Extends basic access tracking with pattern analysis for predicting
  likely-needed context based on task type and history.

  ## Features

    - Task type detection from queries
    - Access pattern tracking and clustering
    - Workflow sequence detection
    - Prediction suggestions based on patterns

  ## Examples

      # Track an access with context
      AccessPatternTracker.track_access(:memory, 123, task: "debugging")

      # Get predictions for a task type
      predictions = AccessPatternTracker.predict("implement auth feature")

      # Get patterns for analysis
      patterns = AccessPatternTracker.patterns()
  """
  use GenServer
  require Logger

  @flush_interval 30_000
  @max_pattern_age_days 30

  # Task type patterns
  @task_patterns %{
    coding: ~r/(implement|add|create|write|build|develop)\s+/i,
    debugging: ~r/(debug|fix|error|bug|issue|crash|fail)/i,
    architecture: ~r/(design|architect|refactor|restructure|plan)/i,
    documentation: ~r/(document|explain|describe|readme|doc)/i,
    research: ~r/(research|explore|investigate|analyze|understand)/i,
    testing: ~r/(test|spec|assert|verify|check)/i
  }

  # Access type weights for predictions
  @source_weights %{
    memory: 0.3,
    code_symbol: 0.25,
    knowledge: 0.20,
    library: 0.15,
    file: 0.10
  }

  # ==========================================================================
  # Public API
  # ==========================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Track an access to a resource with task context.

  ## Parameters

    * `source_type` - Type of source (:memory, :code_symbol, :knowledge, :library, :file)
    * `source_id` - ID of the accessed resource
    * `opts` - Options:
      * `:task` - Description of current task
      * `:query` - The query that led to this access
      * `:tier` - The tier of the accessed item

  ## Returns

    :ok
  """
  @spec track_access(atom(), term(), keyword()) :: :ok
  def track_access(source_type, source_id, opts \\ []) do
    GenServer.cast(__MODULE__, {:track, source_type, source_id, opts})
  end

  @doc """
  Predict likely-needed resources based on current task/query.

  ## Parameters

    * `query` - Current task or query string

  ## Returns

    Map with predictions by source type
  """
  @spec predict(String.t()) :: map()
  def predict(query) do
    GenServer.call(__MODULE__, {:predict, query})
  catch
    :exit, _ -> default_predictions()
  end

  @doc """
  Get detected task type from a query string.
  """
  @spec detect_task_type(String.t()) :: atom()
  def detect_task_type(query) do
    Enum.find_value(@task_patterns, :general, fn {type, pattern} ->
      if Regex.match?(pattern, query), do: type
    end)
  end

  @doc """
  Get current access patterns for analysis.
  """
  @spec patterns() :: map()
  def patterns do
    GenServer.call(__MODULE__, :patterns)
  catch
    :exit, _ -> %{status: :unavailable}
  end

  @doc """
  Get statistics about pattern tracking.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  catch
    :exit, _ -> %{status: :unavailable}
  end

  @doc """
  Clear old patterns beyond retention period.
  """
  @spec cleanup() :: :ok
  def cleanup do
    GenServer.cast(__MODULE__, :cleanup)
  end

  # ==========================================================================
  # GenServer Callbacks
  # ==========================================================================

  @impl true
  def init(_opts) do
    schedule_flush()

    state = %{
      # Recent accesses by task type
      # %{task_type => [%{source_type, source_id, timestamp, tier}]}
      access_history: %{},
      # Sequence patterns: %{task_type => [[source_type]]}
      sequences: %{},
      # Co-occurrence patterns: %{{source_type1, source_type2} => count}
      co_occurrences: %{},
      # Total counts
      total_tracked: 0,
      session_start: System.monotonic_time(:second)
    }

    Logger.info("AccessPatternTracker initialized")
    {:ok, state}
  end

  @impl true
  def handle_cast({:track, source_type, source_id, opts}, state) do
    task = opts[:task] || opts[:query] || ""
    tier = opts[:tier]
    task_type = detect_task_type(task)
    timestamp = System.monotonic_time(:second)

    access = %{
      source_type: source_type,
      source_id: source_id,
      timestamp: timestamp,
      tier: tier
    }

    # Update access history for this task type
    history = Map.get(state.access_history, task_type, [])
    updated_history = [access | Enum.take(history, 99)]

    # Update co-occurrences if we have recent history
    co_occurrences =
      if length(history) > 0 do
        prev = hd(history)
        key = {min(prev.source_type, source_type), max(prev.source_type, source_type)}
        Map.update(state.co_occurrences, key, 1, &(&1 + 1))
      else
        state.co_occurrences
      end

    new_state = %{
      state
      | access_history: Map.put(state.access_history, task_type, updated_history),
        co_occurrences: co_occurrences,
        total_tracked: state.total_tracked + 1
    }

    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:cleanup, state) do
    cutoff = System.monotonic_time(:second) - @max_pattern_age_days * 86400

    # Clean old accesses from history
    cleaned_history =
      state.access_history
      |> Enum.map(fn {task_type, accesses} ->
        {task_type, Enum.filter(accesses, &(&1.timestamp > cutoff))}
      end)
      |> Enum.reject(fn {_, accesses} -> accesses == [] end)
      |> Map.new()

    {:noreply, %{state | access_history: cleaned_history}}
  end

  @impl true
  def handle_call({:predict, query}, _from, state) do
    predictions = generate_predictions(query, state)
    {:reply, predictions, state}
  end

  @impl true
  def handle_call(:patterns, _from, state) do
    patterns = %{
      task_types: Map.keys(state.access_history),
      access_counts: Enum.map(state.access_history, fn {k, v} -> {k, length(v)} end) |> Map.new(),
      co_occurrences: top_co_occurrences(state.co_occurrences, 10)
    }

    {:reply, patterns, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    uptime = System.monotonic_time(:second) - state.session_start

    stats = %{
      total_tracked: state.total_tracked,
      task_types_seen: map_size(state.access_history),
      co_occurrence_pairs: map_size(state.co_occurrences),
      uptime_seconds: uptime
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:flush, state) do
    # Periodic maintenance - could persist patterns to DB here
    schedule_flush()
    {:noreply, state}
  end

  # ==========================================================================
  # Private Implementation
  # ==========================================================================

  defp generate_predictions(query, state) do
    task_type = detect_task_type(query)

    # Get accesses for this task type
    history = Map.get(state.access_history, task_type, [])

    # Count source types in history
    source_counts =
      history
      |> Enum.map(& &1.source_type)
      |> Enum.frequencies()

    # Generate predictions based on frequency and weights
    predictions =
      source_counts
      |> Enum.map(fn {source_type, count} ->
        weight = Map.get(@source_weights, source_type, 0.1)
        score = count * weight / max(length(history), 1)
        {source_type, min(score, 1.0)}
      end)
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> Enum.take(5)
      |> Map.new()

    # Add co-occurrence based suggestions
    co_suggestions = suggest_from_co_occurrences(predictions, state.co_occurrences)

    %{
      task_type: task_type,
      source_predictions: predictions,
      co_occurrence_suggestions: co_suggestions,
      confidence: calculate_confidence(history, state.total_tracked),
      based_on_samples: length(history)
    }
  end

  defp suggest_from_co_occurrences(predictions, co_occurrences) do
    # Find types that co-occur with predicted types
    predicted_types = Map.keys(predictions)

    co_occurrences
    |> Enum.filter(fn {{type1, type2}, _count} ->
      type1 in predicted_types or type2 in predicted_types
    end)
    |> Enum.flat_map(fn {{type1, type2}, count} ->
      cond do
        type1 in predicted_types and type2 not in predicted_types -> [{type2, count}]
        type2 in predicted_types and type1 not in predicted_types -> [{type1, count}]
        true -> []
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {type, counts} -> {type, Enum.sum(counts)} end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(3)
    |> Map.new()
  end

  defp calculate_confidence(history, total) do
    sample_size = length(history)

    cond do
      sample_size >= 50 and total >= 100 -> 0.9
      sample_size >= 20 and total >= 50 -> 0.7
      sample_size >= 10 and total >= 20 -> 0.5
      sample_size >= 5 -> 0.3
      true -> 0.1
    end
  end

  defp top_co_occurrences(co_occurrences, n) do
    co_occurrences
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(n)
    |> Enum.map(fn {{type1, type2}, count} ->
      %{types: [type1, type2], count: count}
    end)
  end

  defp default_predictions do
    %{
      task_type: :general,
      source_predictions: %{memory: 0.5, code_symbol: 0.3},
      co_occurrence_suggestions: %{},
      confidence: 0.0,
      based_on_samples: 0
    }
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval)
  end
end
