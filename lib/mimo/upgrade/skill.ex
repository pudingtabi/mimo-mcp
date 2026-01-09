defmodule Mimo.Upgrade.Skill do
  @moduledoc """
  PAI-inspired Upgrade Skill: Self-monitoring and improvement recommendations.

  This module implements the "Upgrade Skill" concept from Daniel Miessler's
  Personal AI (PAI) framework. It monitors system performance, identifies
  improvement opportunities, and generates actionable recommendations.

  ## PAI Principle

  "An Upgrade Skill that's constantly monitoring your AI's performance
  and looking for ways to improve it."

  ## Recommendation Types

  - `:underused_tool` - Capable tools not being utilized
  - `:declining_pattern` - Patterns that are becoming less effective
  - `:performance_issue` - Tools with high latency or failure rates
  - `:workflow_optimization` - Opportunities to streamline workflows

  ## Integration Points

  - Called by BackgroundCognition as process 7
  - Surfaced in awakening_status response
  - Stored as memories for persistence
  """

  require Logger

  alias Mimo.Brain.{Interaction, Memory}
  alias Mimo.Brain.Emergence.Pattern

  @type recommendation :: %{
          type: atom(),
          priority: :high | :medium | :low,
          title: String.t(),
          description: String.t(),
          action: String.t(),
          metadata: map()
        }

  # Minimum usage percentage to not be considered "underused"
  @underused_threshold 0.02
  # Maximum acceptable average latency (ms)
  @high_latency_threshold_ms 5000
  # Minimum occurrences for pattern analysis
  @min_pattern_occurrences 3

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Analyze system performance and generate improvement recommendations.

  Returns a list of 0-5 prioritized recommendations based on:
  - Tool usage patterns (underused tools, performance issues)
  - Emergence patterns (declining patterns, improvement opportunities)
  - Workflow analysis (optimization opportunities)

  ## Options

  - `:days` - Analysis window in days (default: 14)
  - `:limit` - Max recommendations to return (default: 5)

  ## Examples

      iex> Mimo.Upgrade.Skill.analyze_and_recommend()
      {:ok, [
        %{type: :underused_tool, priority: :medium, title: "Consider using 'reason' tool", ...},
        %{type: :declining_pattern, priority: :high, title: "Pattern 'file-read-edit' declining", ...}
      ]}
  """
  @spec analyze_and_recommend(keyword()) :: {:ok, [recommendation()]} | {:error, term()}
  def analyze_and_recommend(opts \\ []) do
    days = Keyword.get(opts, :days, 14)
    limit = Keyword.get(opts, :limit, 5)

    Logger.debug("[Upgrade.Skill] Starting analysis (#{days} day window)")

    recommendations =
      []
      |> add_underused_tool_recommendations(days)
      |> add_performance_issue_recommendations(days)
      |> add_declining_pattern_recommendations()
      |> add_workflow_optimization_recommendations(days)
      |> prioritize_and_limit(limit)

    Logger.info("[Upgrade.Skill] Generated #{length(recommendations)} recommendations")

    {:ok, recommendations}
  rescue
    e ->
      Logger.error("[Upgrade.Skill] Analysis failed: #{Exception.message(e)}")
      {:error, e}
  end

  @doc """
  Get the most recent upgrade recommendations from memory.

  Returns cached recommendations if available and fresh (< 1 hour old).
  Otherwise returns empty list (caller should run analyze_and_recommend).
  """
  @spec get_cached_recommendations() :: [recommendation()]
  def get_cached_recommendations do
    case Memory.search_memories("upgrade recommendation", limit: 5, category: "plan") do
      recommendations when is_list(recommendations) ->
        recommendations
        |> Enum.filter(&recent_recommendation?/1)
        |> Enum.map(&parse_recommendation_from_memory/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  @doc """
  Store recommendations in memory for persistence and later retrieval.
  """
  @spec store_recommendations([recommendation()]) :: :ok
  def store_recommendations(recommendations) do
    Enum.each(recommendations, fn rec ->
      content = format_recommendation_for_storage(rec)
      importance = priority_to_importance(rec.priority)

      Memory.persist_memory(content, "plan", importance, [])
    end)

    :ok
  end

  # ============================================================================
  # Recommendation Generators
  # ============================================================================

  defp add_underused_tool_recommendations(recommendations, days) do
    case Interaction.tool_usage_stats(days: days, limit: 50) do
      %{rankings: rankings, summary: %{total_calls: total}} when total > 0 ->
        underused =
          rankings
          |> identify_valuable_underused_tools(total)
          |> Enum.map(&build_underused_tool_recommendation/1)

        recommendations ++ underused

      _ ->
        recommendations
    end
  end

  defp add_performance_issue_recommendations(recommendations, days) do
    case Interaction.tool_usage_stats(days: days) do
      %{performance: performance} when is_map(performance) ->
        slow_tools =
          performance
          |> Enum.filter(fn {_tool, stats} ->
            (stats[:avg_duration_ms] || 0) > @high_latency_threshold_ms
          end)
          |> Enum.map(&build_performance_recommendation/1)

        recommendations ++ slow_tools

      _ ->
        recommendations
    end
  end

  defp add_declining_pattern_recommendations(recommendations) do
    case Pattern.declining() do
      patterns when is_list(patterns) ->
        declining_recs =
          patterns
          |> Enum.filter(fn p -> p.occurrences >= @min_pattern_occurrences end)
          |> Enum.take(2)
          |> Enum.map(&build_declining_pattern_recommendation/1)

        recommendations ++ declining_recs

      _ ->
        recommendations
    end
  rescue
    _ -> recommendations
  end

  defp add_workflow_optimization_recommendations(recommendations, _days) do
    # Future: Analyze tool sequences for optimization opportunities
    # For now, return unchanged
    recommendations
  end

  # ============================================================================
  # Recommendation Builders
  # ============================================================================

  defp identify_valuable_underused_tools(rankings, total) do
    # Known valuable tools that should be used more
    valuable_tools = ~w(reason memory code meta)

    rankings
    |> Enum.filter(fn %{tool: tool, count: count} ->
      percentage = count / total

      tool in valuable_tools and percentage < @underused_threshold
    end)
    |> Enum.take(2)
  end

  defp build_underused_tool_recommendation(%{tool: tool, count: count, percentage: pct}) do
    %{
      type: :underused_tool,
      priority: :medium,
      title: "Consider using '#{tool}' tool more",
      description:
        "The '#{tool}' tool was only used #{count} times (#{Float.round(pct * 100, 1)}%). " <>
          "This tool can provide significant value for #{tool_benefit(tool)}.",
      action: "Try incorporating '#{tool}' into your workflow for relevant tasks.",
      metadata: %{tool: tool, usage_count: count, usage_percentage: pct}
    }
  end

  defp build_performance_recommendation({tool, stats}) do
    avg_ms = stats[:avg_duration_ms] || 0

    %{
      type: :performance_issue,
      priority: if(avg_ms > 10_000, do: :high, else: :medium),
      title: "Performance issue with '#{tool}'",
      description:
        "The '#{tool}' tool has high average latency (#{round(avg_ms)}ms). " <>
          "Consider optimizing or using alternative approaches.",
      action: "Review '#{tool}' usage patterns and consider caching or batching.",
      metadata: %{tool: tool, avg_latency_ms: avg_ms}
    }
  end

  defp build_declining_pattern_recommendation(pattern) do
    %{
      type: :declining_pattern,
      priority: :high,
      title: "Pattern '#{pattern.name}' is declining",
      description:
        "The pattern '#{pattern.name}' (#{pattern.type}) has declining effectiveness. " <>
          "Success rate: #{Float.round(pattern.success_rate * 100, 1)}%, " <>
          "occurrences: #{pattern.occurrences}.",
      action: "Review and potentially adapt the '#{pattern.name}' pattern.",
      metadata: %{
        pattern_name: pattern.name,
        pattern_type: pattern.type,
        success_rate: pattern.success_rate,
        occurrences: pattern.occurrences
      }
    }
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp prioritize_and_limit(recommendations, limit) do
    recommendations
    |> Enum.sort_by(fn rec ->
      priority_weight =
        case rec.priority do
          :high -> 0
          :medium -> 1
          :low -> 2
        end

      {priority_weight, rec.type}
    end)
    |> Enum.take(limit)
  end

  defp tool_benefit(tool) do
    case tool do
      "reason" -> "structured reasoning and complex decision-making"
      "memory" -> "context persistence and knowledge retrieval"
      "code" -> "code intelligence and symbol navigation"
      "meta" -> "composite operations and context gathering"
      _ -> "various tasks"
    end
  end

  defp priority_to_importance(:high), do: 0.9
  defp priority_to_importance(:medium), do: 0.7
  defp priority_to_importance(:low), do: 0.5

  defp format_recommendation_for_storage(rec) do
    "[Upgrade Recommendation] #{rec.title}: #{rec.description} Action: #{rec.action}"
  end

  defp recent_recommendation?(memory) do
    case memory[:inserted_at] do
      %DateTime{} = dt ->
        DateTime.diff(DateTime.utc_now(), dt, :hour) < 1

      _ ->
        false
    end
  end

  defp parse_recommendation_from_memory(memory) do
    content = memory[:content] || ""

    if String.starts_with?(content, "[Upgrade Recommendation]") do
      %{
        type: :cached,
        priority: importance_to_priority(memory[:importance] || 0.5),
        title: extract_title(content),
        description: content,
        action: "",
        metadata: %{from_memory: true, memory_id: memory[:id]}
      }
    else
      nil
    end
  end

  defp extract_title(content) do
    case Regex.run(~r/\[Upgrade Recommendation\] ([^:]+):/, content) do
      [_, title] -> title
      _ -> "Cached recommendation"
    end
  end

  defp importance_to_priority(imp) when imp >= 0.8, do: :high
  defp importance_to_priority(imp) when imp >= 0.6, do: :medium
  defp importance_to_priority(_), do: :low
end
