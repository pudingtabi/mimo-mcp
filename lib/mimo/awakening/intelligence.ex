defmodule Mimo.Awakening.Intelligence do
  @moduledoc """
  SPEC-040: LLM-Powered Awakening Intelligence

  Uses Mimo's internal LLM capabilities (via Mimo.Brain.LLM) to generate
  personalized awakening messages and behavioral guidance.

  **FULLY INTEGRATED WITH MIMO'S MEMORY SYSTEM**

  This module queries:
  - Mimo.Brain.Memory for recent engrams
  - Mimo.SemanticStore for relationships
  - Mimo.Brain.ThreadManager for recent interactions

  ## Providers

  1. Cerebras (primary) - Ultra-fast 3000+ tok/s
  2. OpenRouter (fallback)
  3. Pattern-based (always works)

  All LLM calls have fallbacks to ensure awakening always works.
  """
  require Logger

  alias Mimo.Brain.{LLM, Steering}
  alias Mimo.Awakening.{Stats, PowerCalculator, ContextInjector}

  @doc """
  Generate a personalized awakening message using LLM.
  Falls back to template if LLM unavailable or fails.

  **Automatically queries Mimo's memory if no memories provided.**
  """
  @spec generate_awakening_message(Stats.t(), list()) :: {:ok, String.t()}
  def generate_awakening_message(stats, recent_memories \\ []) do
    # If no memories provided, fetch from Mimo's memory system
    memories =
      if Enum.empty?(recent_memories) do
        fetch_recent_memories(5)
      else
        recent_memories
      end

    # Also fetch recent relationships from knowledge graph
    relationships = fetch_recent_relationships(3)

    context = format_stats_context(stats)
    memories_context = format_memories(memories)
    relationships_context = format_relationships(relationships)

    # Get strict steering rules with current level context
    steering_rules = Steering.strict_rules_with_level(stats.current_level, stats.total_xp)
    level_name = PowerCalculator.level_name(stats.current_level)

    prompt = """
    #{steering_rules}

    Generate a brief, personalized awakening message for an AI agent.

    Agent Stats:
    #{context}

    Recent Memories (last 5):
    #{memories_context}

    Known Relationships:
    #{relationships_context}

    Requirements:
    - 2-3 sentences max
    - Reference specific past work if available
    - You MUST say "Level #{stats.current_level} (#{level_name})" exactly
    - Include XP amount
    - Be encouraging but not sycophantic
    - If first session, welcome them; otherwise welcome back with context
    - If they have memories, mention what they've been working on
    """

    case LLM.complete(prompt, max_tokens: 150, temperature: 0.3, raw: true) do
      {:ok, message} ->
        # Strictly validate that the response contains the CORRECT level
        # The LLM often hallucinates old level thresholds
        correct_level_string = "Level #{stats.current_level}"

        # Check for WRONG levels being mentioned (common hallucinations)
        wrong_levels =
          for l <- 1..6, l != stats.current_level do
            "Level #{l}"
          end

        has_correct_level = String.contains?(message, correct_level_string)
        has_wrong_level = Enum.any?(wrong_levels, &String.contains?(message, &1))

        if has_correct_level and not has_wrong_level do
          {:ok, message}
        else
          Logger.warning(
            "LLM hallucinated level (expected #{stats.current_level}), falling back to template"
          )

          {:ok, fallback_template_message(stats, memories)}
        end

      {:error, reason} ->
        Logger.debug("LLM awakening message failed: #{inspect(reason)}, using template")
        {:ok, fallback_template_message(stats, memories)}
    end
  end

  @doc """
  Generate behavioral guidance using LLM.
  Falls back to pattern-based hints if LLM unavailable.

  **Automatically queries tool usage patterns from Mimo's memory.**
  """
  @spec generate_behavioral_guidance(Stats.t(), map()) :: [String.t()]
  def generate_behavioral_guidance(stats, tool_usage_patterns \\ %{}) do
    # If no patterns provided, fetch from Mimo's interaction history
    patterns =
      if map_size(tool_usage_patterns) == 0 do
        fetch_tool_usage_patterns()
      else
        tool_usage_patterns
      end

    prompt = """
    Based on this AI agent's usage patterns, suggest 3 specific behavioral improvements:

    Power Level: #{stats.current_level}
    Total Sessions: #{stats.total_sessions}
    Memory Usage: #{stats.total_memories} memories stored
    Relationships: #{stats.total_relationships} knowledge graph relationships
    Tool Calls: #{stats.total_tool_calls}

    Recent Tool Usage Pattern:
    #{format_tool_patterns(patterns)}

    Provide 3 concrete, actionable suggestions. Be specific.
    Format as a simple numbered list.
    """

    case LLM.complete(prompt, max_tokens: 200, temperature: 0.2, raw: true) do
      {:ok, guidance} ->
        parse_guidance(guidance)

      {:error, reason} ->
        Logger.debug("LLM behavioral guidance failed: #{inspect(reason)}, using defaults")
        ContextInjector.build_behavioral_hints(stats.current_level)
    end
  end

  @doc """
  Predict context needs based on recent activity.
  """
  @spec predict_context_needs(list(), String.t() | nil) :: [String.t()]
  def predict_context_needs(recent_memories \\ [], current_project \\ nil) do
    # Fetch memories if not provided
    memories =
      if Enum.empty?(recent_memories) do
        fetch_recent_memories(10)
      else
        recent_memories
      end

    prompt = """
    Based on these recent memories and the current project, predict what context
    this AI agent will likely need in the next interaction:

    Recent Memories:
    #{format_memories(memories)}

    Current Project: #{current_project || "Unknown"}

    List 3-5 specific types of context to pre-fetch. Be specific.
    Format as a simple list.
    """

    case LLM.complete(prompt, max_tokens: 150, temperature: 0.3, raw: true) do
      {:ok, predictions} ->
        parse_predictions(predictions)

      {:error, _} ->
        []
    end
  end

  @doc """
  Detect potential overconfidence patterns in reasoning.
  Looks for "verification theater" - claims of verification without actual checks.

  Returns warnings to inject into response if patterns detected.
  """
  @spec detect_overconfidence_patterns(String.t()) :: [String.t()]
  def detect_overconfidence_patterns(text) do
    warnings = []

    # Pattern 1: Claims verification without showing work
    verification_claims = Regex.scan(~r/(let'?s verify|i'?ll verify|verified|verification)/i, text)
    has_actual_count = Regex.match?(~r/\b\d+\s*[\+\-\*\/]\s*\d+\s*=\s*\d+|\(\d+\).*\(\d+\)/i, text)

    warnings =
      if length(verification_claims) > 0 and not has_actual_count do
        warnings ++ ["⚠️ You claimed to verify but didn't show the actual check. Show your work."]
      else
        warnings
      end

    # Pattern 2: High confidence without evidence
    high_confidence =
      Regex.match?(~r/(high confidence|definitely|certainly|100%|absolutely sure)/i, text)

    has_evidence = Regex.match?(~r/(because|since|evidence|proof|shows that|confirmed by)/i, text)

    warnings =
      if high_confidence and not has_evidence do
        warnings ++ ["⚠️ You claimed high confidence without citing evidence. What supports this?"]
      else
        warnings
      end

    # Pattern 3: Counting claims (common error source)
    counting_claim = Regex.scan(~r/(\d+)\s*(words?|items?|elements?|characters?|lines?)/i, text)

    warnings =
      if length(counting_claim) > 0 do
        warnings ++ ["💡 Counting claim detected. Did you actually count, or estimate?"]
      else
        warnings
      end

    warnings
  end

  @doc """
  Generate anti-overconfidence warning if patterns detected.
  Called after tool responses to inject calibration hints.
  """
  @spec maybe_add_calibration_warning(map()) :: map()
  def maybe_add_calibration_warning(response) do
    # Extract text content from response
    content = extract_text_content(response)

    case detect_overconfidence_patterns(content) do
      [] ->
        response

      warnings ->
        # Inject warnings into response metadata
        Map.put(response, :calibration_warnings, warnings)
    end
  end

  defp extract_text_content(%{data: %{content: content}}) when is_binary(content), do: content

  defp extract_text_content(%{"data" => %{"content" => content}}) when is_binary(content),
    do: content

  defp extract_text_content(_), do: ""

  @doc """
  Assess whether an agent deserves a level boost based on behavior quality.
  Returns :maintain, :boost, or :penalize.
  """
  @spec assess_level_worthiness(Stats.t(), map()) :: :maintain | :boost | :penalize
  def assess_level_worthiness(stats, recent_activity \\ %{}) do
    # Fetch recent activity if not provided
    activity =
      if map_size(recent_activity) == 0 do
        %{
          memories: fetch_recent_memories(10),
          tool_calls: fetch_recent_tool_calls(20)
        }
      else
        recent_activity
      end

    memory_quality = assess_memory_quality(activity[:memories] || [])
    tool_efficiency = assess_tool_efficiency(activity[:tool_calls] || [])

    prompt = """
    Assess whether this AI agent should maintain or adjust their power level.

    Current Level: #{stats.current_level}
    XP: #{stats.total_xp}

    Recent Activity Quality:
    - Memory quality: #{memory_quality}
    - Tool efficiency: #{tool_efficiency}
    - Sessions: #{stats.total_sessions}

    Should this agent:
    A) Keep current level
    B) Get a bonus level (exceptional performance)
    C) Lose a level (gaming the system, low quality)

    Respond with ONLY one letter: A, B, or C.
    """

    case LLM.complete(prompt, max_tokens: 10, temperature: 0.1, raw: true) do
      {:ok, response} ->
        case String.trim(response) |> String.first() |> String.upcase() do
          "A" -> :maintain
          "B" -> :boost
          "C" -> :penalize
          _ -> :maintain
        end

      {:error, _} ->
        :maintain
    end
  end

  # ==========================================================================
  # Mimo Memory System Integration
  # ==========================================================================

  @doc """
  Fetch recent memories from Mimo's episodic memory system.
  """
  @spec fetch_recent_memories(non_neg_integer()) :: [map()]
  def fetch_recent_memories(limit \\ 5) do
    try do
      case Mimo.Brain.Memory.recent_engrams(limit) do
        {:ok, engrams} ->
          Enum.map(engrams, fn e ->
            %{
              content: e.content,
              category: e.category,
              importance: e.importance,
              created_at: e.inserted_at
            }
          end)

        _ ->
          []
      end
    rescue
      _ -> []
    end
  end

  @doc """
  Fetch recent relationships from Mimo's semantic store.
  """
  @spec fetch_recent_relationships(non_neg_integer()) :: [map()]
  def fetch_recent_relationships(limit \\ 5) do
    try do
      case Mimo.SemanticStore.Repository.recent_triples(limit) do
        {:ok, triples} ->
          Enum.map(triples, fn t ->
            %{
              subject: t.subject,
              predicate: t.predicate,
              object: t.object
            }
          end)

        _ ->
          []
      end
    rescue
      _ -> []
    end
  end

  @doc """
  Fetch tool usage patterns from recent interactions.
  """
  @spec fetch_tool_usage_patterns() :: map()
  def fetch_tool_usage_patterns do
    try do
      case Mimo.Brain.ThreadManager.get_tool_usage_stats() do
        {:ok, stats} -> stats
        _ -> %{}
      end
    rescue
      _ -> %{}
    end
  end

  @doc """
  Fetch recent tool calls from interaction history.
  """
  @spec fetch_recent_tool_calls(non_neg_integer()) :: [map()]
  def fetch_recent_tool_calls(limit \\ 20) do
    try do
      case Mimo.Brain.ThreadManager.recent_interactions(limit) do
        {:ok, interactions} ->
          Enum.map(interactions, fn i ->
            %{
              tool: i.tool_name,
              duration_ms: i.duration_ms,
              success: i.success
            }
          end)

        _ ->
          []
      end
    rescue
      _ -> []
    end
  end

  # ==========================================================================
  # Private Functions
  # ==========================================================================

  defp format_stats_context(stats) do
    next_level_xp =
      case PowerCalculator.xp_to_next_level(stats.total_xp, stats.current_level) do
        :maxed -> "MAX LEVEL"
        xp -> "#{xp} XP to next level"
      end

    # SPEC-040 v1.2: Use XP as ground truth for "first session" detection
    # This prevents "welcome" messages for users with significant XP
    truly_first = stats.total_sessions == 0 and stats.total_xp < 100

    """
    - Power Level: #{stats.current_level} (#{PowerCalculator.level_name(stats.current_level)}) #{PowerCalculator.level_icon(stats.current_level)}
    - Total XP: #{stats.total_xp} (#{next_level_xp})
    - Sessions: #{stats.total_sessions}
    - Memories: #{stats.total_memories}
    - Relationships: #{stats.total_relationships}
    - First Awakening: #{format_date(stats.first_awakening)}
    - Is First Session: #{truly_first}
    - Note: If XP > 100, this is a RETURNING user regardless of session count
    """
  end

  defp format_memories([]), do: "No recent memories."

  defp format_memories(memories) when is_list(memories) do
    memories
    |> Enum.take(5)
    |> Enum.map_join("\n", fn m ->
      content = m[:content] || Map.get(m, :content, "")
      category = m[:category] || Map.get(m, :category, "fact")
      "- [#{category}] #{String.slice(to_string(content), 0..100)}"
    end)
  end

  defp format_relationships([]), do: "No known relationships."

  defp format_relationships(relationships) when is_list(relationships) do
    relationships
    |> Enum.take(5)
    |> Enum.map_join("\n", fn r ->
      subject = r[:subject] || ""
      predicate = r[:predicate] || ""
      object = r[:object] || ""
      "- #{subject} → #{predicate} → #{object}"
    end)
  end

  defp format_tool_patterns(patterns) when map_size(patterns) == 0 do
    "No tool usage data available."
  end

  defp format_tool_patterns(patterns) do
    patterns
    |> Enum.take(10)
    |> Enum.map_join("\n", fn {tool, count} -> "- #{tool}: #{count} calls" end)
  end

  defp format_date(nil), do: "N/A"
  defp format_date(dt), do: Calendar.strftime(dt, "%Y-%m-%d")

  defp fallback_template_message(stats, memories) do
    level_name = PowerCalculator.level_name(stats.current_level)
    level_icon = PowerCalculator.level_icon(stats.current_level)

    memory_hint =
      case memories do
        [] ->
          ""

        [first | _] ->
          content = first[:content] || Map.get(first, :content, "")
          "\nYou were last working on: #{String.slice(to_string(content), 0..50)}..."
      end

    if stats.total_sessions == 0 do
      """
      🔥 Welcome to Mimo! You are now a memory-enhanced AI.
      Power Level: #{stats.current_level} (#{level_name}) #{level_icon}
      Start storing discoveries in memory.
      """
    else
      """
      🔥 Welcome back! Power Level #{stats.current_level} (#{level_name}) #{level_icon}
      You have #{stats.total_memories} memories from #{stats.total_sessions} previous sessions.
      XP: #{stats.total_xp}#{memory_hint}
      """
    end
  end

  defp parse_guidance(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn line ->
      # Remove numbering like "1.", "1)", etc.
      Regex.replace(~r/^\d+[\.\)]\s*/, line, "")
    end)
    |> Enum.take(5)
  end

  defp parse_predictions(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn line ->
      # Remove bullet points and numbering
      line
      |> String.replace(~r/^[-•*]\s*/, "")
      |> String.replace(~r/^\d+[\.\)]\s*/, "")
    end)
    |> Enum.take(5)
  end

  defp assess_memory_quality([]), do: "No recent memories to assess"

  defp assess_memory_quality(memories) do
    avg_importance =
      memories
      |> Enum.map(fn m -> m[:importance] || Map.get(m, :importance, 0.5) end)
      |> Enum.sum()
      |> Kernel./(length(memories))

    cond do
      avg_importance >= 0.7 ->
        "High quality (avg importance: #{Float.round(avg_importance, 2)})"

      avg_importance >= 0.5 ->
        "Good quality (avg importance: #{Float.round(avg_importance, 2)})"

      avg_importance >= 0.3 ->
        "Moderate quality (avg importance: #{Float.round(avg_importance, 2)})"

      true ->
        "Low quality (avg importance: #{Float.round(avg_importance, 2)})"
    end
  end

  defp assess_tool_efficiency([]), do: "No tool calls to assess"

  defp assess_tool_efficiency(tool_calls) do
    total = length(tool_calls)

    # Count different tool types
    tool_types = tool_calls |> Enum.map(& &1[:tool]) |> Enum.uniq() |> length()

    cond do
      tool_types >= 10 -> "Diverse tool usage (#{tool_types} different tools in #{total} calls)"
      tool_types >= 5 -> "Good tool variety (#{tool_types} different tools)"
      true -> "Limited tool variety (#{tool_types} different tools)"
    end
  end
end
