defmodule Mimo.Cognitive.CapabilityBoundary do
  @moduledoc """
  SPEC-SELF Level 3: Capability Boundary Detection

  Learns from failures what Mimo CANNOT do, enabling honest "I don't know"
  responses. This is a critical component of genuine self-understanding.

  ## Architecture

  ```
  After Failure ──► record_boundary(context, reason) ──► Store pattern
                                                             │
  Before Task ──► can_handle?(query) ──► Check boundaries ──►│
                                              │              │
                                         {:ok, 0.8} or       │
                                         {:uncertain, "..."} │
                                         {:no, "..."}        │
  Query ──► limitations() ──► List known boundaries ─────────┘
  ```

  ## Example

      # Check if we can handle a task
      case CapabilityBoundary.can_handle?(%{query: "Deploy to AWS"}) do
        {:ok, confidence} ->
          # Proceed with task
        {:uncertain, reason} ->
          # Warn user, but try
        {:no, explanation} ->
          # Honestly decline: "I don't know how to do that"
      end
  """

  use GenServer
  require Logger

  # ETS table for boundary patterns
  @boundaries_table :mimo_capability_boundaries

  # Configuration
  @min_failures_for_boundary 3
  @boundary_confidence_threshold 0.6
  @max_boundaries 1_000

  ## Public API

  @doc """
  Checks if Mimo can handle a given query/task.

  Returns:
  - {:ok, confidence} - Can handle with given confidence
  - {:uncertain, reason} - Not sure, proceed with caution
  - {:no, explanation} - Known to be outside capabilities
  """
  @spec can_handle?(map()) :: {:ok, float()} | {:uncertain, String.t()} | {:no, String.t()}
  def can_handle?(context) do
    GenServer.call(__MODULE__, {:can_handle, context})
  end

  @doc """
  Records a capability boundary from a failure.

  Called after a task fails to learn what we can't do.

  ## Parameters
    - context: Map with :tool, :operation, :query, etc.
    - failure_reason: Description of why it failed
  """
  @spec record_boundary(map(), String.t()) :: :ok
  def record_boundary(context, failure_reason) do
    GenServer.cast(__MODULE__, {:record_boundary, context, failure_reason})
  end

  @doc """
  Returns list of known capability limitations.

  ## Options
    - limit: Max limitations to return (default: 50)
    - category: Filter by category (tool, domain, complexity, resource)
  """
  @spec limitations(keyword()) :: {:ok, list(map())}
  def limitations(opts \\ []) do
    GenServer.call(__MODULE__, {:limitations, opts})
  end

  @doc """
  Returns statistics about known boundaries.
  """
  @spec stats() :: {:ok, map()}
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  ## GenServer Implementation

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Create ETS table
    :ets.new(@boundaries_table, [:named_table, :set, :public, read_concurrency: true])

    # Load any persisted boundaries from memory
    spawn(fn -> load_persisted_boundaries() end)

    Logger.info("[CapabilityBoundary] Level 3 boundary detection initialized")

    {:ok,
     %{
       total_checks: 0,
       total_blocked: 0,
       total_uncertain: 0,
       started_at: System.system_time(:millisecond)
     }}
  end

  @impl true
  def handle_call({:can_handle, context}, _from, state) do
    {result, new_state} = check_boundaries(context, state)
    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:limitations, opts}, _from, state) do
    limits = list_limitations(opts)
    {:reply, {:ok, limits}, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = compute_stats(state)
    {:reply, {:ok, stats}, state}
  end

  @impl true
  def handle_cast({:record_boundary, context, failure_reason}, state) do
    do_record_boundary(context, failure_reason)
    {:noreply, state}
  end

  ## Private Functions

  defp check_boundaries(context, state) do
    tool = Map.get(context, :tool, "unknown")
    operation = Map.get(context, :operation, "unknown")
    query = Map.get(context, :query, "")

    # Check for matching boundaries
    boundaries = find_matching_boundaries(tool, operation, query)

    new_state = %{state | total_checks: state.total_checks + 1}

    if Enum.empty?(boundaries) do
      # No known boundaries - probably can handle it
      {{:ok, 0.85}, new_state}
    else
      # Found matching boundaries
      most_relevant = Enum.max_by(boundaries, & &1.failure_count)

      if most_relevant.failure_count >= @min_failures_for_boundary and
           most_relevant.confidence >= @boundary_confidence_threshold do
        # Strong boundary - can't handle
        explanation =
          "Known limitation: #{most_relevant.category} - #{most_relevant.description}. " <>
            "Failed #{most_relevant.failure_count} times before."

        {{:no, explanation}, %{new_state | total_blocked: new_state.total_blocked + 1}}
      else
        # Weak signal - uncertain
        reason =
          "Past failures with similar tasks (#{most_relevant.failure_count}x). " <>
            "Proceed with caution."

        {{:uncertain, reason}, %{new_state | total_uncertain: new_state.total_uncertain + 1}}
      end
    end
  end

  defp find_matching_boundaries(tool, operation, query) do
    :ets.tab2list(@boundaries_table)
    |> Enum.map(fn {_id, boundary} -> boundary end)
    |> Enum.filter(fn boundary ->
      tool_match = is_nil(boundary.tool) or boundary.tool == tool
      op_match = is_nil(boundary.operation) or boundary.operation == operation

      pattern_match =
        case boundary.pattern do
          nil -> true
          pattern when is_binary(pattern) -> String.contains?(query, pattern)
          %Regex{} = regex -> Regex.match?(regex, query)
        end

      tool_match and op_match and pattern_match
    end)
  end

  defp do_record_boundary(context, failure_reason) do
    tool = Map.get(context, :tool, "unknown")
    operation = Map.get(context, :operation, "unknown")
    query = Map.get(context, :query, "")

    # Generate boundary ID based on tool+operation
    hash = :erlang.phash2(query) |> Integer.to_string()
    boundary_id = "boundary_#{tool}_#{operation}_#{hash}"

    # Check if boundary already exists
    case :ets.lookup(@boundaries_table, boundary_id) do
      [{^boundary_id, existing}] ->
        # Increment failure count
        updated = %{
          existing
          | failure_count: existing.failure_count + 1,
            last_failure_at: System.system_time(:millisecond),
            confidence: min(1.0, existing.confidence + 0.1),
            failure_reasons: Enum.take([failure_reason | existing.failure_reasons], 5)
        }

        :ets.insert(@boundaries_table, {boundary_id, updated})

      [] ->
        # Create new boundary
        category = categorize_failure(tool, operation, failure_reason)
        description = extract_description(failure_reason)
        pattern = extract_pattern(query)

        boundary = %{
          id: boundary_id,
          tool: tool,
          operation: operation,
          pattern: pattern,
          category: category,
          description: description,
          failure_count: 1,
          confidence: 0.3,
          failure_reasons: [failure_reason],
          created_at: System.system_time(:millisecond),
          last_failure_at: System.system_time(:millisecond)
        }

        :ets.insert(@boundaries_table, {boundary_id, boundary})

        # Evict old boundaries if needed
        maybe_evict_old_boundaries()
    end

    :ok
  end

  defp categorize_failure(tool, _operation, failure_reason) do
    reason_lower = String.downcase(failure_reason)

    cond do
      String.contains?(reason_lower, ["timeout", "slow", "memory"]) ->
        :resource

      String.contains?(reason_lower, ["permission", "access", "auth"]) ->
        :permission

      String.contains?(reason_lower, ["not found", "missing", "unknown"]) ->
        :knowledge

      String.contains?(reason_lower, ["complex", "ambiguous", "unclear"]) ->
        :complexity

      tool in ["terminal", "file"] ->
        :execution

      true ->
        :general
    end
  end

  defp extract_description(failure_reason) do
    # Take first 100 chars of failure reason
    failure_reason
    |> String.slice(0, 100)
    |> String.trim()
  end

  defp extract_pattern(query) when is_binary(query) and byte_size(query) > 0 do
    # Extract key terms from query
    query
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, "")
    |> String.split()
    |> Enum.take(3)
    |> Enum.join(" ")
  end

  defp extract_pattern(_), do: nil

  defp list_limitations(opts) do
    limit = Keyword.get(opts, :limit, 50)
    category_filter = Keyword.get(opts, :category)

    :ets.tab2list(@boundaries_table)
    |> Enum.map(fn {_id, boundary} -> boundary end)
    |> Enum.filter(fn boundary ->
      is_nil(category_filter) or boundary.category == category_filter
    end)
    |> Enum.sort_by(& &1.failure_count, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn boundary ->
      %{
        tool: boundary.tool,
        operation: boundary.operation,
        category: boundary.category,
        description: boundary.description,
        failure_count: boundary.failure_count,
        confidence: boundary.confidence
      }
    end)
  end

  defp compute_stats(state) do
    boundary_count = :ets.info(@boundaries_table, :size)

    # Count by category
    by_category =
      :ets.tab2list(@boundaries_table)
      |> Enum.map(fn {_id, b} -> b.category end)
      |> Enum.frequencies()

    uptime_ms = System.system_time(:millisecond) - state.started_at

    %{
      total_boundaries: boundary_count,
      total_checks: state.total_checks,
      total_blocked: state.total_blocked,
      total_uncertain: state.total_uncertain,
      block_rate: safe_div(state.total_blocked, state.total_checks),
      by_category: by_category,
      uptime_hours: Float.round(uptime_ms / 3_600_000, 2)
    }
  end

  defp maybe_evict_old_boundaries do
    size = :ets.info(@boundaries_table, :size)

    if size > @max_boundaries do
      # Remove lowest confidence boundaries
      to_remove = size - @max_boundaries + 50

      :ets.tab2list(@boundaries_table)
      |> Enum.sort_by(fn {_id, b} -> b.confidence end)
      |> Enum.take(to_remove)
      |> Enum.each(fn {id, _} -> :ets.delete(@boundaries_table, id) end)
    end
  end

  defp load_persisted_boundaries do
    # Load boundaries from persistent memory (future implementation)
    # For now, boundaries are session-only
    :ok
  end

  defp safe_div(_, 0), do: 0.0
  defp safe_div(a, b), do: Float.round(a / b, 3)
end
