defmodule Mimo.AdoptionMetrics do
  @moduledoc """
  Adoption and workflow health metrics tracking (Q1 2026 Phase 4 Extended).

  Tracks when `cognitive assess` is used as the first tool call in a session,
  and monitors overall workflow health across sessions.

  Implementation: Uses ETS for simplicity - metrics are session-based and don't
  need to persist across Mimo restarts.

  ## Metrics Tracked

  ### AUTO-REASONING Adoption
  - Total tool calls
  - Sessions where cognitive assess was first tool
  - Sessions where cognitive assess was NOT first tool
  - Breakdown by tool name for first tool calls

  ### Workflow Health (Q1 2026 Phase 4)
  - Context-first workflow compliance (memory/knowledge before file/terminal)
  - Learning phase completion (memory stores after discoveries)
  - Tool balance scores (correct distribution across phases)
  - Session completion quality

  ## Usage

      # Check metrics
      Mimo.AdoptionMetrics.get_stats()

      # Get workflow health
      Mimo.AdoptionMetrics.get_workflow_health()

      # Track workflow phase
      Mimo.AdoptionMetrics.track_workflow_phase(:context, "memory")

      # Reset metrics (for testing)
      Mimo.AdoptionMetrics.reset()
  """

  use GenServer
  require Logger

  @table_name :adoption_metrics
  @session_key :session_first_tool
  @workflow_key :workflow_phases

  # Workflow phase definitions
  @phase_tools %{
    context: ["memory", "ask_mimo", "knowledge", "prepare_context", "meta"],
    intelligence: ["code", "cognitive", "reason", "think"],
    action: ["file", "terminal", "web"],
    learning: ["memory", "knowledge"]
  }

  # Target percentages for healthy workflow
  @healthy_distribution %{
    # 15-20%
    context: {0.15, 0.20},
    # 15-20%
    intelligence: {0.15, 0.20},
    # 45-55%
    action: {0.45, 0.55},
    # 10-15%
    learning: {0.10, 0.15}
  }

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Track a tool call. Automatically detects if this is the first tool in a session.

  ## Parameters
  - `tool_name` - The name of the tool being called
  - `session_id` - Optional session identifier (defaults to self() PID)
  """
  def track_tool_call(tool_name, session_id \\ nil) do
    session = session_id || inspect(self())
    GenServer.cast(__MODULE__, {:track_tool, tool_name, session})
  end

  @doc """
  Track a workflow phase transition.

  ## Parameters
  - `phase` - One of :context, :intelligence, :action, :learning
  - `tool_name` - The tool being used
  - `session_id` - Optional session identifier
  """
  def track_workflow_phase(phase, tool_name, session_id \\ nil) do
    session = session_id || inspect(self())
    GenServer.cast(__MODULE__, {:track_phase, phase, tool_name, session})
  end

  @doc """
  Track a learning event (memory store after discovery).
  """
  def track_learning_event(event_type, session_id \\ nil) do
    session = session_id || inspect(self())
    GenServer.cast(__MODULE__, {:track_learning, event_type, session})
  end

  @doc """
  Get current adoption metrics.
  """
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @doc """
  Get workflow health metrics.
  """
  def get_workflow_health do
    GenServer.call(__MODULE__, :get_workflow_health)
  end

  @doc """
  Reset all metrics (useful for testing or periodic resets).
  """
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table_name, [:set, :public, :named_table])
    Logger.info("[AdoptionMetrics] Started tracking AUTO-REASONING adoption and workflow health")
    {:ok, %{table: table}}
  end

  @impl true
  def handle_cast({:track_tool, tool_name, session}, state) do
    case :ets.lookup(@table_name, {@session_key, session}) do
      [] ->
        :ets.insert(@table_name, {{@session_key, session}, tool_name})

        :ets.update_counter(
          @table_name,
          {:first_tool, tool_name},
          {2, 1},
          {{:first_tool, tool_name}, 0}
        )

        is_assess =
          tool_name == "cognitive" or
            (is_map(tool_name) and Map.get(tool_name, "operation") == "assess")

        if is_assess do
          Logger.debug("[AdoptionMetrics] ✓ Session #{session} started with cognitive assess")
        else
          Logger.debug("[AdoptionMetrics] ✗ Session #{session} started with #{inspect(tool_name)}")
        end

        phase = classify_tool_phase(tool_name)
        track_phase_internally(phase, tool_name, session)

      [_] ->
        :ets.update_counter(@table_name, :total_tool_calls, {2, 1}, {:total_tool_calls, 0})
        phase = classify_tool_phase(tool_name)
        track_phase_internally(phase, tool_name, session)
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:track_phase, phase, _tool_name, session}, state) do
    :ets.update_counter(@table_name, {:phase_count, phase}, {2, 1}, {{:phase_count, phase}, 0})

    case :ets.lookup(@table_name, {@workflow_key, session}) do
      [] -> :ets.insert(@table_name, {{@workflow_key, session}, [phase]})
      [{_, phases}] -> :ets.insert(@table_name, {{@workflow_key, session}, phases ++ [phase]})
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:track_learning, event_type, session}, state) do
    :ets.update_counter(
      @table_name,
      {:learning_events, event_type},
      {2, 1},
      {{:learning_events, event_type}, 0}
    )

    :ets.insert(@table_name, {{:session_has_learning, session}, true})
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    sessions = :ets.match(@table_name, {{@session_key, :"$1"}, :"$2"})
    total_sessions = length(sessions)

    assess_first_count =
      Enum.count(sessions, fn [_session, first_tool] ->
        first_tool == "cognitive" or
          (is_map(first_tool) and Map.get(first_tool, "operation") == "assess")
      end)

    first_tool_breakdown =
      :ets.match(@table_name, {{:first_tool, :"$1"}, :"$2"})
      |> Enum.map(fn [tool, count] -> {tool, count} end)
      |> Map.new()

    total_tool_calls =
      case :ets.lookup(@table_name, :total_tool_calls) do
        [{_, c}] -> c
        [] -> 0
      end

    stats = %{
      total_sessions: total_sessions,
      total_tool_calls: total_tool_calls,
      assess_first_count: assess_first_count,
      assess_first_rate: if(total_sessions > 0, do: assess_first_count / total_sessions, else: 0.0),
      other_first_count: total_sessions - assess_first_count,
      first_tool_breakdown: first_tool_breakdown
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:get_workflow_health, _from, state) do
    phase_counts =
      [:context, :intelligence, :action, :learning]
      |> Enum.map(fn phase ->
        case :ets.lookup(@table_name, {:phase_count, phase}) do
          [{_, count}] -> {phase, count}
          [] -> {phase, 0}
        end
      end)
      |> Map.new()

    total_phase_calls = Enum.sum(Map.values(phase_counts))

    phase_distribution =
      if total_phase_calls > 0 do
        phase_counts
        |> Enum.map(fn {phase, count} -> {phase, Float.round(count / total_phase_calls, 3)} end)
        |> Map.new()
      else
        %{context: 0.0, intelligence: 0.0, action: 0.0, learning: 0.0}
      end

    distribution_health =
      Enum.map(@healthy_distribution, fn {phase, {min, max}} ->
        actual = Map.get(phase_distribution, phase, 0.0)

        health =
          cond do
            actual >= min and actual <= max -> 1.0
            actual < min -> actual / min
            actual > max -> max / actual
          end

        {phase, Float.round(health, 2)}
      end)
      |> Map.new()

    overall_health =
      distribution_health |> Map.values() |> Enum.sum() |> Kernel./(4) |> Float.round(2)

    sessions = :ets.match(@table_name, {{@session_key, :"$1"}, :"$2"})

    context_first_count =
      Enum.count(sessions, fn [_, first_tool] ->
        classify_tool_phase(first_tool) == :context
      end)

    context_first_rate =
      if length(sessions) > 0, do: context_first_count / length(sessions), else: 0.0

    sessions_with_learning =
      :ets.match(@table_name, {{:session_has_learning, :"$1"}, true}) |> length()

    learning_completion_rate =
      if length(sessions) > 0, do: sessions_with_learning / length(sessions), else: 0.0

    recommendations =
      generate_recommendations(phase_distribution, context_first_rate, learning_completion_rate)

    health = %{
      phase_distribution: phase_distribution,
      distribution_health: distribution_health,
      overall_health: overall_health,
      context_first_rate: Float.round(context_first_rate, 2),
      learning_completion_rate: Float.round(learning_completion_rate, 2),
      phase_counts: phase_counts,
      recommendations: recommendations,
      status: classify_health_status(overall_health)
    }

    {:reply, health, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table_name)
    Logger.info("[AdoptionMetrics] Metrics reset")
    {:reply, :ok, state}
  end

  # Private helpers

  defp classify_tool_phase(tool_name) when is_binary(tool_name) do
    cond do
      tool_name in @phase_tools[:context] -> :context
      tool_name in @phase_tools[:intelligence] -> :intelligence
      tool_name in @phase_tools[:action] -> :action
      true -> :other
    end
  end

  defp classify_tool_phase(_), do: :other

  defp track_phase_internally(phase, _tool_name, session) do
    :ets.update_counter(@table_name, {:phase_count, phase}, {2, 1}, {{:phase_count, phase}, 0})

    case :ets.lookup(@table_name, {@workflow_key, session}) do
      [] -> :ets.insert(@table_name, {{@workflow_key, session}, [phase]})
      [{_, phases}] -> :ets.insert(@table_name, {{@workflow_key, session}, phases ++ [phase]})
    end
  end

  defp generate_recommendations(distribution, context_first_rate, learning_rate) do
    recommendations = []

    recommendations =
      if context_first_rate < 0.5 do
        [
          "Consider starting more sessions with context gathering (memory/ask_mimo)"
          | recommendations
        ]
      else
        recommendations
      end

    recommendations =
      if learning_rate < 0.5 do
        [
          "Increase learning phase usage - store discoveries with memory operation=store"
          | recommendations
        ]
      else
        recommendations
      end

    context = Map.get(distribution, :context, 0.0)
    intelligence = Map.get(distribution, :intelligence, 0.0)
    action = Map.get(distribution, :action, 0.0)

    recommendations =
      if context < 0.10 do
        [
          "Context gathering is low (#{Float.round(context * 100, 1)}%) - use memory/knowledge before file reads"
          | recommendations
        ]
      else
        recommendations
      end

    recommendations =
      if intelligence < 0.10 do
        [
          "Intelligence tools underused (#{Float.round(intelligence * 100, 1)}%) - use code/cognitive before action"
          | recommendations
        ]
      else
        recommendations
      end

    recommendations =
      if action > 0.70 do
        [
          "Action phase dominant (#{Float.round(action * 100, 1)}%) - balance with context and intelligence"
          | recommendations
        ]
      else
        recommendations
      end

    if Enum.empty?(recommendations) do
      ["Workflow health is good! Keep up the balanced approach."]
    else
      recommendations
    end
  end

  defp classify_health_status(overall_health) do
    cond do
      overall_health >= 0.8 -> :healthy
      overall_health >= 0.5 -> :needs_improvement
      true -> :unhealthy
    end
  end
end
