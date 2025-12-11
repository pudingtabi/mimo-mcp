defmodule Mimo.Brain.Emergence.ABTesting do
  @moduledoc """
  A/B Testing for Emergence Pattern Suggestions.

  Implements a simple A/B testing framework to measure the impact of
  injecting pattern suggestions into tool calls:

  - Control group: No pattern suggestions injected
  - Test group: Pattern suggestions from UsageTracker injected

  Uses process dictionary for session-level group assignment (sticky sessions).
  Assignment is 50/50 random split.

  ## Usage

  In Tools.dispatch, before executing a tool call:

      case ABTesting.get_suggestions(tool_name, arguments) do
        {:test, suggestions} -> 
          # Inject suggestions into result
          execute_with_suggestions(suggestions)
        {:control, nil} ->
          # Execute normally
          execute_normally()
      end

  After tool call completes:

      ABTesting.track_outcome(session_id, success?)
  """

  alias Mimo.Brain.Emergence.UsageTracker

  # Process dictionary key for session group assignment
  @session_group_key :mimo_ab_test_group
  @session_id_key :mimo_ab_session_id

  @doc """
  Get pattern suggestions if this session is in the test group.
  Returns {:test, suggestions} or {:control, nil}.

  Also assigns session to a group if not already assigned.
  """
  def get_suggestions(tool_name, context) when is_binary(tool_name) do
    session_id = get_or_create_session_id()
    group = get_or_assign_group()

    case group do
      :test ->
        # Get pattern suggestions from UsageTracker
        case UsageTracker.suggest_patterns(tool_name, limit: 3) do
          {:ok, suggestions} when suggestions != [] ->
            # Track that we're using these patterns
            track_pattern_suggestions(session_id, suggestions, context)
            {:test, format_suggestions(suggestions)}

          _ ->
            # No suggestions available
            {:test, []}
        end

      :control ->
        {:control, nil}
    end
  end

  @doc """
  Track the outcome of a tool call for A/B testing.
  """
  def track_outcome(success?) when is_boolean(success?) do
    session_id = get_session_id()
    
    if session_id do
      # Track outcome for any patterns that were suggested this session
      track_session_outcome(session_id, success?)
    end
    
    :ok
  end

  @doc """
  Get the current session's test group.
  Returns :test, :control, or nil if not assigned.
  """
  def current_group do
    Process.get(@session_group_key)
  end

  @doc """
  Get the current session ID.
  """
  def get_session_id do
    Process.get(@session_id_key)
  end

  @doc """
  Force-set a session to a specific group (for testing).
  """
  def set_group(group) when group in [:test, :control] do
    Process.put(@session_group_key, group)
    :ok
  end

  @doc """
  Reset the session (clears group assignment).
  """
  def reset_session do
    Process.delete(@session_group_key)
    Process.delete(@session_id_key)
    :ok
  end

  @doc """
  Get A/B testing statistics.
  """
  def stats do
    # Get stats from ETS tracking table
    case :ets.info(:emergence_ab_testing) do
      :undefined ->
        %{
          test_sessions: 0,
          control_sessions: 0,
          test_successes: 0,
          test_failures: 0,
          control_successes: 0,
          control_failures: 0,
          test_success_rate: 0.0,
          control_success_rate: 0.0,
          lift: 0.0
        }

      _ ->
        compute_stats()
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp get_or_create_session_id do
    case Process.get(@session_id_key) do
      nil ->
        session_id = generate_session_id()
        Process.put(@session_id_key, session_id)
        session_id

      session_id ->
        session_id
    end
  end

  defp get_or_assign_group do
    case Process.get(@session_group_key) do
      nil ->
        # Random 50/50 assignment
        group = if :rand.uniform() < 0.5, do: :test, else: :control
        Process.put(@session_group_key, group)
        
        # Track assignment
        track_group_assignment(get_or_create_session_id(), group)
        
        group

      group ->
        group
    end
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp track_pattern_suggestions(session_id, suggestions, context) do
    ensure_ets_table()
    
    # Store which patterns were suggested for this session
    pattern_ids = Enum.map(suggestions, & &1.pattern_id)
    
    :ets.insert(:emergence_ab_testing, {
      {:session_patterns, session_id},
      %{
        pattern_ids: pattern_ids,
        context: context,
        suggested_at: DateTime.utc_now()
      }
    })

    # Track usage for each pattern
    Enum.each(pattern_ids, fn pattern_id ->
      UsageTracker.track_usage(pattern_id, context, session_id: session_id)
    end)
  end

  defp track_session_outcome(session_id, success?) do
    ensure_ets_table()
    
    # Get patterns that were suggested for this session
    case :ets.lookup(:emergence_ab_testing, {:session_patterns, session_id}) do
      [{_, %{pattern_ids: pattern_ids}}] ->
        # Track outcome for each pattern
        Enum.each(pattern_ids, fn pattern_id ->
          UsageTracker.track_outcome(pattern_id, success?)
        end)

      [] ->
        :ok
    end

    # Track session-level outcome
    group = current_group() || :unknown
    outcome_key = {:outcome, group, success?}
    
    :ets.update_counter(:emergence_ab_testing, outcome_key, {2, 1}, {outcome_key, 0})
  end

  defp track_group_assignment(session_id, group) do
    ensure_ets_table()
    
    :ets.insert(:emergence_ab_testing, {
      {:assignment, session_id},
      %{group: group, assigned_at: DateTime.utc_now()}
    })

    # Increment group counter
    :ets.update_counter(:emergence_ab_testing, {:group_count, group}, {2, 1}, {{:group_count, group}, 0})
  end

  defp ensure_ets_table do
    case :ets.info(:emergence_ab_testing) do
      :undefined ->
        :ets.new(:emergence_ab_testing, [:named_table, :public, :set])

      _ ->
        :ok
    end
  end

  defp format_suggestions(suggestions) do
    Enum.map(suggestions, fn suggestion ->
      %{
        pattern_id: suggestion.pattern_id,
        description: suggestion.description,
        relevance: suggestion.relevance,
        hint: "💡 This pattern has shown #{format_success_rate(suggestion.success_rate)} success rate"
      }
    end)
  end

  defp format_success_rate(rate) when is_float(rate) do
    "#{Float.round(rate * 100, 1)}%"
  end
  defp format_success_rate(_), do: "unknown"

  defp compute_stats do
    test_sessions = get_counter({:group_count, :test})
    control_sessions = get_counter({:group_count, :control})
    
    test_successes = get_counter({:outcome, :test, true})
    test_failures = get_counter({:outcome, :test, false})
    control_successes = get_counter({:outcome, :control, true})
    control_failures = get_counter({:outcome, :control, false})

    test_total = test_successes + test_failures
    control_total = control_successes + control_failures

    test_rate = if test_total > 0, do: test_successes / test_total, else: 0.0
    control_rate = if control_total > 0, do: control_successes / control_total, else: 0.0

    lift = if control_rate > 0, do: (test_rate - control_rate) / control_rate * 100, else: 0.0

    %{
      test_sessions: test_sessions,
      control_sessions: control_sessions,
      test_successes: test_successes,
      test_failures: test_failures,
      control_successes: control_successes,
      control_failures: control_failures,
      test_success_rate: Float.round(test_rate * 100, 2),
      control_success_rate: Float.round(control_rate * 100, 2),
      lift: Float.round(lift, 2)
    }
  end

  defp get_counter(key) do
    case :ets.lookup(:emergence_ab_testing, key) do
      [{^key, count}] -> count
      [] -> 0
    end
  end
end
