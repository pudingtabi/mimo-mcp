defmodule Mimo.Brain.Emergence.UsageTracker do
  @moduledoc """
  IMPLEMENTATION_PLAN_Q1_2026 Phase 2: Pattern Usage Tracking.
  
  Tracks usage of promoted patterns to measure their impact on outcomes.
  This provides the feedback loop needed to validate that emerged patterns
  actually improve agent performance.
  
  ## Usage Flow
  
  1. Pattern is promoted (via Promoter)
  2. Pattern is suggested during tool selection (via suggest_patterns)
  3. Agent uses/ignores the pattern
  4. Outcome is tracked (success/failure)
  5. Impact metrics are calculated
  
  ## Metrics Tracked
  
  - Total uses of pattern
  - Success count
  - Failure count
  - Success rate
  - Time to first use
  - Use frequency
  
  ## A/B Testing Support
  
  Enables comparing outcomes when patterns are suggested vs not suggested,
  allowing statistical validation of pattern effectiveness.
  """
  
  use GenServer
  require Logger
  
  alias Mimo.Brain.Emergence.Pattern
  alias Mimo.Repo
  import Ecto.Query

  @usage_table :emergence_usage_tracking

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Track that a pattern was used in a tool call.
  
  ## Parameters
  
  - `pattern_id` - The ID of the pattern (from Pattern schema)
  - `outcome` - `:success` | `:failure` | `:unknown`
  - `context` - Optional map with additional context (tool, session, etc.)
  """
  @spec track_usage(String.t(), atom(), map()) :: :ok
  def track_usage(pattern_id, outcome \\ :unknown, context \\ %{})
      when outcome in [:success, :failure, :unknown] do
    GenServer.cast(__MODULE__, {:track_usage, pattern_id, outcome, context})
  end

  @doc """
  Track outcome for a previously recorded usage.
  
  Used when outcome becomes known after initial tracking.
  """
  @spec track_outcome(String.t(), atom()) :: :ok
  def track_outcome(pattern_id, outcome) when outcome in [:success, :failure] do
    GenServer.cast(__MODULE__, {:track_outcome, pattern_id, outcome})
  end

  @doc """
  Get impact metrics for a specific pattern.
  
  Returns usage statistics and impact assessment.
  """
  @spec get_impact(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_impact(pattern_id) do
    GenServer.call(__MODULE__, {:get_impact, pattern_id})
  end

  @doc """
  Get impact metrics for all tracked patterns.
  """
  @spec get_all_impacts() :: [map()]
  def get_all_impacts do
    GenServer.call(__MODULE__, :get_all_impacts)
  end

  @doc """
  Get patterns that have demonstrated positive impact.
  
  Returns patterns with success rate > threshold (default 0.7).
  """
  @spec get_high_impact_patterns(float()) :: [map()]
  def get_high_impact_patterns(threshold \\ 0.7) do
    GenServer.call(__MODULE__, {:get_high_impact, threshold})
  end

  @doc """
  Suggest patterns relevant to current context.
  
  Used by the A/B testing system to inject pattern suggestions.
  """
  @spec suggest_patterns(String.t(), map()) :: [map()]
  def suggest_patterns(tool_name, context \\ %{}) do
    GenServer.call(__MODULE__, {:suggest, tool_name, context})
  end

  @doc """
  Get usage tracking statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for tracking
    table = :ets.new(@usage_table, [:set, :public, :named_table])
    
    Logger.info("[Emergence.UsageTracker] Started pattern usage tracking")
    
    {:ok, %{table: table, ab_test_sessions: %{}}}
  end

  @impl true
  def handle_cast({:track_usage, pattern_id, outcome, context}, state) do
    now = DateTime.utc_now()
    
    # Get or create usage record
    case :ets.lookup(@usage_table, pattern_id) do
      [{^pattern_id, existing}] ->
        # Update existing record
        updated = %{existing |
          total_uses: existing.total_uses + 1,
          last_used_at: now,
          outcomes: update_outcomes(existing.outcomes, outcome),
          usage_history: [%{at: now, outcome: outcome, context: context} | Enum.take(existing.usage_history, 99)]
        }
        :ets.insert(@usage_table, {pattern_id, updated})
        
      [] ->
        # Create new record
        new_record = %{
          pattern_id: pattern_id,
          total_uses: 1,
          first_used_at: now,
          last_used_at: now,
          outcomes: %{success: 0, failure: 0, unknown: 0} |> Map.update!(outcome, &(&1 + 1)),
          usage_history: [%{at: now, outcome: outcome, context: context}]
        }
        :ets.insert(@usage_table, {pattern_id, new_record})
    end
    
    Logger.debug("[Emergence.UsageTracker] Tracked usage of pattern #{pattern_id}: #{outcome}")
    
    {:noreply, state}
  end

  @impl true
  def handle_cast({:track_outcome, pattern_id, outcome}, state) do
    case :ets.lookup(@usage_table, pattern_id) do
      [{^pattern_id, existing}] ->
        # Convert unknown to actual outcome in recent history
        updated_history = update_recent_unknown(existing.usage_history, outcome)
        
        # Update outcome counts
        updated_outcomes = existing.outcomes
        |> Map.update!(:unknown, &max(0, &1 - 1))
        |> Map.update!(outcome, &(&1 + 1))
        
        updated = %{existing |
          outcomes: updated_outcomes,
          usage_history: updated_history
        }
        :ets.insert(@usage_table, {pattern_id, updated})
        
      [] ->
        :ok
    end
    
    {:noreply, state}
  end

  @impl true
  def handle_call({:get_impact, pattern_id}, _from, state) do
    result = case :ets.lookup(@usage_table, pattern_id) do
      [{^pattern_id, record}] ->
        impact = calculate_impact(record)
        {:ok, Map.merge(record, %{impact: impact})}
      [] ->
        {:error, :not_found}
    end
    
    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_all_impacts, _from, state) do
    all = @usage_table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, record} ->
      impact = calculate_impact(record)
      Map.merge(record, %{impact: impact})
    end)
    |> Enum.sort_by(&(-&1.impact.success_rate))
    
    {:reply, all, state}
  end

  @impl true
  def handle_call({:get_high_impact, threshold}, _from, state) do
    high_impact = @usage_table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, record} -> calculate_impact(record) end)
    |> Enum.filter(fn impact ->
      impact.success_rate >= threshold and impact.total_uses >= 5
    end)
    |> Enum.sort_by(&(-&1.success_rate))
    
    {:reply, high_impact, state}
  end

  @impl true
  def handle_call({:suggest, tool_name, context}, _from, state) do
    # Query patterns relevant to this tool
    suggestions = Pattern
    |> where([p], p.status == :promoted)
    |> where([p], fragment("json_extract(?, '$.tool') = ?", p.metadata, ^tool_name) or
                  fragment("json_extract(?, '$.tools') LIKE ?", p.metadata, ^"%#{tool_name}%"))
    |> limit(5)
    |> Repo.all()
    |> Enum.map(fn pattern ->
      %{
        pattern_id: pattern.id,
        description: pattern.description,
        type: pattern.type,
        success_rate: pattern.success_rate,
        suggested_action: get_suggested_action(pattern, context)
      }
    end)
    
    {:reply, suggestions, state}
  rescue
    _ -> {:reply, [], state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    all_records = :ets.tab2list(@usage_table)
    
    stats = %{
      patterns_tracked: length(all_records),
      total_uses: Enum.sum(Enum.map(all_records, fn {_, r} -> r.total_uses end)),
      total_successes: Enum.sum(Enum.map(all_records, fn {_, r} -> r.outcomes.success end)),
      total_failures: Enum.sum(Enum.map(all_records, fn {_, r} -> r.outcomes.failure end)),
      average_success_rate: calculate_average_success_rate(all_records),
      patterns_with_positive_impact: count_high_impact(all_records, 0.5),
      patterns_with_strong_impact: count_high_impact(all_records, 0.7)
    }
    
    {:reply, stats, state}
  end

  # Private Functions

  defp update_outcomes(outcomes, outcome) do
    Map.update!(outcomes, outcome, &(&1 + 1))
  end

  defp update_recent_unknown(history, outcome) do
    # Update the most recent unknown outcome
    case Enum.split_while(history, fn h -> h.outcome != :unknown end) do
      {before, [%{outcome: :unknown} = unknown | after_]} ->
        before ++ [%{unknown | outcome: outcome} | after_]
      _ ->
        history
    end
  end

  defp calculate_impact(record) do
    total = record.outcomes.success + record.outcomes.failure
    success_rate = if total > 0, do: record.outcomes.success / total, else: 0.0
    
    %{
      pattern_id: record.pattern_id,
      total_uses: record.total_uses,
      total_evaluated: total,
      pending_evaluation: record.outcomes.unknown,
      success_count: record.outcomes.success,
      failure_count: record.outcomes.failure,
      success_rate: Float.round(success_rate, 3),
      interpretation: interpret_impact(success_rate, total),
      first_used_at: record.first_used_at,
      last_used_at: record.last_used_at
    }
  end

  defp interpret_impact(_success_rate, total) when total < 5 do
    "Insufficient data - need at least 5 uses to evaluate impact"
  end

  defp interpret_impact(success_rate, _total) do
    cond do
      success_rate >= 0.8 -> "High impact - pattern reliably improves outcomes"
      success_rate >= 0.6 -> "Moderate impact - pattern generally helpful"
      success_rate >= 0.4 -> "Uncertain impact - needs more evaluation"
      true -> "Low impact - pattern may not be effective"
    end
  end

  defp get_suggested_action(pattern, _context) do
    case pattern.type do
      :workflow -> "Consider following this workflow: #{pattern.description}"
      :heuristic -> "Apply this heuristic: #{pattern.description}"
      :inference -> "Consider this inference: #{pattern.description}"
      :skill -> "Use this skill: #{pattern.description}"
    end
  end

  defp calculate_average_success_rate(records) when records == [], do: 0.0
  defp calculate_average_success_rate(records) do
    rates = records
    |> Enum.map(fn {_, r} ->
      total = r.outcomes.success + r.outcomes.failure
      if total > 0, do: r.outcomes.success / total, else: nil
    end)
    |> Enum.reject(&is_nil/1)
    
    if length(rates) > 0 do
      Float.round(Enum.sum(rates) / length(rates), 3)
    else
      0.0
    end
  end

  defp count_high_impact(records, threshold) do
    Enum.count(records, fn {_, r} ->
      total = r.outcomes.success + r.outcomes.failure
      total >= 5 and r.outcomes.success / total >= threshold
    end)
  end
end
