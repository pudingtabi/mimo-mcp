defmodule Mimo.Brain.WisdomInjector do
  @moduledoc """
  DEMAND 5: Automatic Wisdom Injection for Small Models

  When a small model is uncertain (low confidence), this module automatically
  surfaces relevant past failures, solutions, and patterns to prevent repeating mistakes.

  ## How It Works

  1. Tool calls are monitored for uncertainty signals
  2. When confidence is low (< 0.5), wisdom is injected
  3. Wisdom includes: past failures, successful patterns, relevant memories
  4. Injected context helps small models make better decisions

  ## Usage

      # Called automatically by prepare_context and cognitive tools
      WisdomInjector.inject_if_uncertain("Ecto pattern question", 0.3)
      # => {:inject, %{memories: [...], patterns: [...], warnings: [...]}}

      # Or check confidence first
      case WisdomInjector.should_inject?(confidence) do
        true -> WisdomInjector.gather_wisdom(query)
        false -> :skip
      end
  """

  require Logger

  alias Mimo.Brain.Memory
  alias Mimo.Brain.Emergence.Pattern

  @confidence_threshold 0.5
  @low_confidence_threshold 0.3

  @doc """
  Check if wisdom injection is needed based on confidence.
  """
  @spec should_inject?(float()) :: boolean()
  def should_inject?(confidence) when is_number(confidence) do
    confidence < @confidence_threshold
  end

  def should_inject?(_), do: false

  @doc """
  Inject wisdom if confidence is below threshold.
  Returns :skip if confidence is adequate, or {:inject, wisdom} if needed.
  """
  @spec inject_if_uncertain(String.t(), float()) :: :skip | {:inject, map()}
  def inject_if_uncertain(query, confidence) when is_binary(query) do
    if should_inject?(confidence) do
      wisdom = gather_wisdom(query, confidence)
      {:inject, wisdom}
    else
      :skip
    end
  end

  def inject_if_uncertain(_, _), do: :skip

  @doc """
  Gather wisdom for a query - past failures, patterns, and memories.
  """
  @spec gather_wisdom(String.t(), float()) :: map()
  def gather_wisdom(query, confidence \\ 0.5) do
    urgency = if confidence < @low_confidence_threshold, do: :high, else: :medium

    # Parallel gather wisdom sources with safe timeout handling
    tasks = [
      Task.async(fn -> {:failures, gather_past_failures(query)} end),
      Task.async(fn -> {:patterns, gather_relevant_patterns(query)} end),
      Task.async(fn -> {:memories, gather_relevant_memories(query)} end),
      Task.async(fn -> {:warnings, generate_warnings(query, confidence)} end)
    ]

    # Use yield_many instead of await_many to avoid crashing on timeout
    results =
      tasks
      |> Task.yield_many(5000)
      |> Enum.map(fn {task, result} ->
        case result do
          {:ok, value} ->
            value

          nil ->
            # Task timed out - shutdown and return empty
            Task.shutdown(task, :brutal_kill)
            Logger.warning("[WisdomInjector] Task timed out, returning empty result")
            {:unknown, []}

          {:exit, reason} ->
            Logger.warning("[WisdomInjector] Task exited: #{inspect(reason)}")
            {:unknown, []}
        end
      end)
      |> Enum.into(%{})

    %{
      urgency: urgency,
      confidence: confidence,
      threshold: @confidence_threshold,
      failures: results[:failures] || [],
      patterns: results[:patterns] || [],
      memories: results[:memories] || [],
      warnings: results[:warnings] || [],
      formatted: format_wisdom(results, urgency)
    }
  rescue
    e ->
      Logger.warning("[WisdomInjector] Error gathering wisdom: #{Exception.message(e)}")
      %{urgency: :low, failures: [], patterns: [], memories: [], warnings: [], formatted: ""}
  end

  # ==========================================================================
  # WISDOM SOURCES
  # ==========================================================================

  defp gather_past_failures(query) do
    # Search for memories tagged as failures or errors related to query
    failure_terms = ["failed", "error", "mistake", "wrong", "C+ grade", "cascade"]

    failure_terms
    |> Enum.flat_map(fn term ->
      search_query = "#{query} #{term}"

      case Memory.search_memories(search_query, limit: 3, min_similarity: 0.3) do
        memories when is_list(memories) ->
          memories
          |> Enum.filter(&failure_memory?/1)
          |> Enum.map(&format_failure/1)

        _ ->
          []
      end
    end)
    |> Enum.uniq_by(& &1.content)
    |> Enum.take(5)
  end

  defp gather_relevant_patterns(query) do
    # Search for emergence patterns that match the query
    case Pattern.search_by_description(query, limit: 5) do
      patterns when is_list(patterns) ->
        Enum.map(patterns, fn pattern ->
          %{
            id: pattern.id,
            type: pattern.type,
            description: pattern.description,
            success_rate: pattern.success_rate,
            occurrences: pattern.occurrences,
            recommendation: generate_pattern_recommendation(pattern)
          }
        end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp gather_relevant_memories(query) do
    # Get high-importance memories related to query
    case Memory.search_memories(query, limit: 5, min_similarity: 0.4) do
      memories when is_list(memories) ->
        memories
        |> Enum.filter(fn mem ->
          importance = Map.get(mem, :importance) || Map.get(mem, "importance") || 0.5
          importance >= 0.7
        end)
        |> Enum.map(fn mem ->
          %{
            content: Map.get(mem, :content) || Map.get(mem, "content"),
            category: Map.get(mem, :category) || Map.get(mem, "category"),
            importance: Map.get(mem, :importance) || Map.get(mem, "importance") || 0.5,
            score: Map.get(mem, :similarity) || Map.get(mem, :score) || 0.5
          }
        end)

      _ ->
        []
    end
  end

  defp generate_warnings(query, confidence) do
    warnings = []

    # Add confidence-based warnings
    warnings =
      if confidence < @low_confidence_threshold do
        [
          %{
            type: :low_confidence,
            message:
              "⚠️ Very low confidence (#{Float.round(confidence * 100, 1)}%). Consider using `reason operation=guided` before proceeding."
          }
          | warnings
        ]
      else
        warnings
      end

    # Add query-based heuristic warnings
    warnings = warnings ++ detect_risk_patterns(query)

    warnings
  end

  # ==========================================================================
  # RISK PATTERN DETECTION
  # ==========================================================================

  defp detect_risk_patterns(query) do
    query_lower = String.downcase(query)

    warnings = []

    # Cascade failure risk
    warnings =
      if String.contains?(query_lower, ["error", "fix", "debug", "broken"]) do
        [
          %{
            type: :cascade_risk,
            message: "⚠️ Debugging detected. Trace backward through cascades to find root cause."
          }
          | warnings
        ]
      else
        warnings
      end

    # Ecto/database patterns
    warnings =
      if String.contains?(query_lower, ["ecto", "database", "query", "repo"]) do
        [
          %{
            type: :ecto_pattern,
            message:
              "💡 Ecto detected. Use defensive Map.get instead of dot notation for struct access."
          }
          | warnings
        ]
      else
        warnings
      end

    # Verification discipline
    warnings =
      if String.contains?(query_lower, ["implement", "add", "create", "change"]) do
        [
          %{
            type: :verification_needed,
            message: "📋 Implementation detected. Mandatory: run `mix compile` after changes."
          }
          | warnings
        ]
      else
        warnings
      end

    warnings
  end

  # ==========================================================================
  # HELPERS
  # ==========================================================================

  defp failure_memory?(mem) do
    content = (Map.get(mem, :content) || Map.get(mem, "content") || "") |> String.downcase()
    category = Map.get(mem, :category) || Map.get(mem, "category")

    category == "action" or
      String.contains?(content, ["failed", "error", "mistake", "c+ grade", "wrong", "cascade"])
  end

  defp format_failure(mem) do
    %{
      content: Map.get(mem, :content) || Map.get(mem, "content"),
      category: Map.get(mem, :category) || Map.get(mem, "category"),
      lesson: extract_lesson(Map.get(mem, :content) || Map.get(mem, "content") || "")
    }
  end

  defp extract_lesson(content) do
    cond do
      String.contains?(content, "C+ grade") ->
        "Verification discipline needed - don't rush execution"

      String.contains?(content, "cascade") ->
        "Trace backward through cascades to find root cause"

      String.contains?(content, "Ecto") or String.contains?(content, "struct") ->
        "Use defensive Map.get for struct field access"

      true ->
        "Review this failure to avoid repeating"
    end
  end

  defp generate_pattern_recommendation(pattern) do
    case pattern.type do
      :workflow ->
        "Follow this workflow sequence (#{pattern.occurrences} successful uses)"

      :heuristic ->
        "Apply this heuristic (#{Float.round(pattern.success_rate * 100, 1)}% success rate)"

      :inference ->
        "Consider this inference pattern"

      :skill ->
        "Use this proven skill approach"

      _ ->
        "Review this pattern"
    end
  end

  defp format_wisdom(results, urgency) do
    sections = []

    # Format failures
    sections =
      if length(results[:failures] || []) > 0 do
        failure_lines =
          Enum.map(results[:failures], fn f ->
            "• #{f.lesson}: #{String.slice(f.content, 0, 100)}..."
          end)

        ["## ⚠️ Past Failures to Avoid\n" <> Enum.join(failure_lines, "\n") | sections]
      else
        sections
      end

    # Format patterns
    sections =
      if length(results[:patterns] || []) > 0 do
        pattern_lines =
          Enum.map(results[:patterns], fn p ->
            "• [#{p.type}] #{p.description} (#{Float.round((p.success_rate || 0) * 100, 1)}% success)"
          end)

        ["## 📚 Relevant Patterns\n" <> Enum.join(pattern_lines, "\n") | sections]
      else
        sections
      end

    # Format warnings
    sections =
      if length(results[:warnings] || []) > 0 do
        warning_lines = Enum.map(results[:warnings], fn w -> "• #{w.message}" end)
        ["## 🚨 Warnings (#{urgency} urgency)\n" <> Enum.join(warning_lines, "\n") | sections]
      else
        sections
      end

    Enum.reverse(sections) |> Enum.join("\n\n")
  end
end
