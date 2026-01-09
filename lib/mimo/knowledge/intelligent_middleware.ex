defmodule Mimo.Knowledge.IntelligentMiddleware do
  @moduledoc """
  SPEC-083: Intelligent Tool Dispatch Middleware

  Adds selective pre-execution reasoning to tool calls, making AI actions
  context-aware and grounded in accumulated knowledge.

  ## Philosophy

  Not all tool calls need intelligence:
  - **Tier 1 (Fast Path)**: Read-only operations → Execute immediately
  - **Tier 2 (Smart Path)**: Mutating operations → Quick memory check first
  - **Tier 3 (Critical Path)**: Destructive operations → Full verification

  ## What It Does

  Before tool execution (for Tier 2+):
  1. Searches memory for past failures with this tool+operation
  2. Looks for relevant warnings or patterns
  3. Injects findings into dispatch context
  4. After execution, tracks outcome for future learning

  ## Integration

  Wraps `Mimo.Tools.dispatch/2` to add pre-execution intelligence:

      # In Mimo.Tools.dispatch/2
      def dispatch(tool_name, arguments) do
        # Pre-execution intelligence
        pre_context = IntelligentMiddleware.pre_dispatch(tool_name, arguments)

        # Execute with context
        result = do_dispatch(tool_name, arguments)

        # Post-execution learning
        IntelligentMiddleware.post_dispatch(tool_name, arguments, result, pre_context)

        # Return enriched result
        enrich_result(result, pre_context)
      end

  ## Timeout Budget

  Pre-dispatch checks have a strict 100ms timeout to avoid blocking.
  If checks timeout, tool proceeds without warnings (fail-open).
  """

  require Logger
  alias Mimo.Brain.{Interaction, Memory}
  alias Mimo.TaskHelper

  # Timeout for pre-dispatch checks (fail-open if exceeded)
  @pre_dispatch_timeout_ms 100

  # Tier 1: Read-only, no pre-check needed (implicit - anything not in tier2/tier3)
  # Includes: file read/ls/glob, memory search, knowledge query, code symbols, web fetch, etc.

  # Tier 2: Mutating, quick memory check
  @tier2_smart_path %{
    "file" => ~w[write edit insert_after insert_before replace_lines delete_lines
                 replace_string multi_replace move create_directory diff],
    "terminal" => ~w[execute start_process interact],
    "memory" => ~w[store],
    "knowledge" => ~w[teach link link_memory sync_dependencies],
    "web" => ~w[browser screenshot pdf evaluate interact test blink blink_smart],
    "reason" => ~w[reflect branch backtrack conclude interleaved_conclude],
    "meta" => ~w[debug_error]
  }

  # Tier 3: Destructive, full verification
  @tier3_critical_path %{
    "terminal" => ~w[kill force_kill],
    "memory" => ~w[delete],
    # If we ever add file delete
    "file" => ~w[delete]
  }

  @type tier :: :fast | :smart | :critical
  @type pre_context :: %{
          tier: tier(),
          warnings: [String.t()],
          past_failures: [map()],
          relevant_patterns: [map()],
          check_duration_ms: non_neg_integer(),
          skipped: boolean()
        }

  @doc """
  Pre-dispatch intelligence check.

  Runs before tool execution to gather relevant context.
  Returns warnings and past failures for the AI to consider.

  Timeout: 100ms (fails open - returns empty context if timeout)
  """
  @spec pre_dispatch(String.t(), map()) :: pre_context()
  def pre_dispatch(tool_name, arguments) do
    start_time = System.monotonic_time(:millisecond)
    tier = classify_operation(tool_name, arguments)

    Logger.debug(
      "[IntelligentMiddleware] #{tool_name}/#{arguments["operation"] || "default"} -> #{tier}"
    )

    case tier do
      :fast ->
        # Tier 1: Skip checks entirely
        %{
          tier: :fast,
          warnings: [],
          past_failures: [],
          relevant_patterns: [],
          check_duration_ms: 0,
          skipped: true
        }

      :smart ->
        # Tier 2: Quick async check with timeout
        run_smart_check(tool_name, arguments, start_time)

      :critical ->
        # Tier 3: Full check (slightly longer timeout)
        run_critical_check(tool_name, arguments, start_time)
    end
  end

  @doc """
  Post-dispatch learning.

  Called after tool execution to track outcomes for future learning.
  Stores failures and successes for pattern detection.
  """
  @spec post_dispatch(String.t(), map(), term(), pre_context()) :: :ok
  def post_dispatch(tool_name, arguments, result, pre_context) do
    # Only track Tier 2+ operations
    if pre_context.tier in [:smart, :critical] do
      track_outcome(tool_name, arguments, result)
    end

    :ok
  end

  @doc """
  Enrich tool result with pre-context warnings.

  Adds any warnings or relevant context to the result so AI sees them.
  """
  @spec enrich_result(term(), pre_context()) :: term()
  def enrich_result(result, pre_context) do
    if pre_context.warnings == [] and pre_context.past_failures == [] do
      result
    else
      case result do
        {:ok, data} when is_map(data) ->
          enrichment = build_enrichment(pre_context)
          {:ok, Map.put(data, :_mimo_intelligent_dispatch, enrichment)}

        other ->
          other
      end
    end
  end

  @doc """
  Check if a specific operation should use intelligent dispatch.
  """
  @spec should_check?(String.t(), map()) :: boolean()
  def should_check?(tool_name, arguments) do
    classify_operation(tool_name, arguments) != :fast
  end

  defp classify_operation(tool_name, arguments) do
    operation = arguments["operation"] || "default"

    cond do
      critical?(tool_name, operation, arguments) -> :critical
      smart?(tool_name, operation) -> :smart
      true -> :fast
    end
  end

  defp critical?(tool_name, operation, arguments) do
    # Check explicit critical operations
    critical_ops = Map.get(@tier3_critical_path, tool_name, [])
    explicit_critical = operation in critical_ops

    # Check for destructive terminal commands
    terminal_critical =
      tool_name == "terminal" and
        destructive_command?(arguments["command"] || "")

    explicit_critical or terminal_critical
  end

  defp smart?(tool_name, operation) do
    smart_ops = Map.get(@tier2_smart_path, tool_name, [])
    operation in smart_ops
  end

  defp destructive_command?(command) do
    destructive_patterns = [
      ~r/\brm\s+-rf?\b/i,
      ~r/\bdrop\s+/i,
      ~r/\bdelete\s+/i,
      ~r/\btruncate\s+/i,
      ~r/\breset\s+--hard/i,
      ~r/\bkill\s+-9/i,
      ~r/\bsudo\s+rm/i
    ]

    Enum.any?(destructive_patterns, &Regex.match?(&1, command))
  end

  defp run_smart_check(tool_name, arguments, start_time) do
    operation = arguments["operation"] || "default"

    task =
      TaskHelper.async_with_callers(fn ->
        search_for_context(tool_name, operation, arguments)
      end)

    case Task.yield(task, @pre_dispatch_timeout_ms) || Task.shutdown(task) do
      {:ok, context} ->
        duration = System.monotonic_time(:millisecond) - start_time

        Map.merge(context, %{
          tier: :smart,
          check_duration_ms: duration,
          skipped: false
        })

      _ ->
        # Timeout - fail open
        Logger.debug("[IntelligentMiddleware] Smart check timed out for #{tool_name}/#{operation}")

        %{
          tier: :smart,
          warnings: [],
          past_failures: [],
          relevant_patterns: [],
          check_duration_ms: @pre_dispatch_timeout_ms,
          skipped: true
        }
    end
  end

  defp run_critical_check(tool_name, arguments, start_time) do
    operation = arguments["operation"] || "default"

    # Critical path gets slightly more time (200ms)
    task =
      TaskHelper.async_with_callers(fn ->
        context = search_for_context(tool_name, operation, arguments)

        # Add explicit warning for critical operations
        critical_warning =
          "⚠️ CRITICAL OPERATION: #{tool_name}/#{operation} - verify before proceeding"

        Map.update(context, :warnings, [critical_warning], &[critical_warning | &1])
      end)

    case Task.yield(task, 200) || Task.shutdown(task) do
      {:ok, context} ->
        duration = System.monotonic_time(:millisecond) - start_time

        Map.merge(context, %{
          tier: :critical,
          check_duration_ms: duration,
          skipped: false
        })

      _ ->
        # Even on timeout, still warn for critical ops
        %{
          tier: :critical,
          warnings: ["⚠️ CRITICAL OPERATION: #{tool_name}/#{operation} - checks timed out"],
          past_failures: [],
          relevant_patterns: [],
          check_duration_ms: 200,
          skipped: true
        }
    end
  end

  defp search_for_context(tool_name, operation, arguments) do
    # Build search query from tool context
    query = build_search_query(tool_name, operation, arguments)

    # Search for past failures and patterns
    memories = Memory.search_memories(query, limit: 5, min_similarity: 0.5)

    if is_list(memories) and memories != [] do
      categorize_memories(memories)
    else
      %{warnings: [], past_failures: [], relevant_patterns: []}
    end
  rescue
    _ ->
      %{warnings: [], past_failures: [], relevant_patterns: []}
  end

  defp build_search_query(tool_name, operation, arguments) do
    # Include key arguments in search
    path = arguments["path"] || ""
    command = arguments["command"] || ""
    pattern = arguments["pattern"] || ""

    parts = [
      "#{tool_name} #{operation}",
      if(path != "", do: "file #{Path.basename(path)}", else: nil),
      if(command != "", do: "command #{command}", else: nil),
      if(pattern != "", do: pattern, else: nil),
      "error OR failure OR warning OR issue"
    ]

    parts
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp categorize_memories(memories) do
    # Separate failures from patterns
    {failures, patterns} =
      Enum.split_with(memories, fn m ->
        content = String.downcase(m.content || "")

        String.contains?(content, "error") or
          String.contains?(content, "fail") or
          String.contains?(content, "crash") or
          String.contains?(content, "bug")
      end)

    # Extract warnings from high-importance failures
    warnings =
      failures
      |> Enum.filter(&((&1.importance || 0) > 0.7))
      |> Enum.take(2)
      |> Enum.map(fn m ->
        "⚠️ Past issue: #{String.slice(m.content, 0..100)}"
      end)

    %{
      warnings: warnings,
      past_failures: Enum.take(failures, 3),
      relevant_patterns: Enum.take(patterns, 3)
    }
  end

  defp track_outcome(tool_name, arguments, result) do
    operation = arguments["operation"] || "default"

    case result do
      {:error, reason} ->
        # Store failure for future learning
        content = "Tool failure: #{tool_name}/#{operation} - #{inspect(reason)}"

        Memory.persist_memory(content, "observation",
          importance: 0.8,
          tags: ["tool_failure", tool_name, operation]
        )

        # WIRE 1: Record to Interaction table for Emergence.Detector pattern detection
        # This connects failures to the emergence system, enabling automatic pattern recognition
        spawn(fn ->
          Interaction.record(tool_name,
            arguments: arguments,
            result_summary: "FAILURE: #{inspect(reason) |> String.slice(0, 200)}",
            duration_ms: 0
          )
        end)

      {:ok, _} ->
        # Success - record for pattern detection (sampling to avoid noise)
        if :rand.uniform(10) == 1 do
          spawn(fn ->
            Interaction.record(tool_name,
              arguments: arguments,
              result_summary: "SUCCESS",
              duration_ms: 0
            )
          end)
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp build_enrichment(pre_context) do
    %{
      source: "SPEC-083 Intelligent Dispatch",
      tier: pre_context.tier,
      check_duration_ms: pre_context.check_duration_ms,
      warnings: pre_context.warnings,
      past_failures_count: length(pre_context.past_failures),
      patterns_found: length(pre_context.relevant_patterns),
      hint:
        if(pre_context.warnings != [],
          do: "⚠️ Review warnings above before proceeding",
          else: "✓ No past issues found for this operation"
        )
    }
  end
end
