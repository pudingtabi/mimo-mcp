defmodule Mimo.Awakening.ContextInjector do
  @moduledoc """
  SPEC-040: Context Injector for Awakening Protocol

  Builds and injects awakening context into tool responses.
  Only injected on the FIRST tool call of a session.

  The awakening context includes:
  - Power level information
  - Accumulated wisdom stats
  - Unlocked capabilities based on level
  - Behavioral guidance hints
  - Personalized awakening message
  """
  require Logger

  alias Mimo.Awakening.{Stats, PowerCalculator, SessionTracker}

  @doc """
  Build the complete awakening context payload.
  This is injected into the first tool response of a session.
  Now includes tool balance tracking for behavioral transformation (SPEC-040 v1.2).
  """
  @spec build_awakening_context(SessionTracker.t(), Stats.t()) :: map()
  def build_awakening_context(session_state, stats) do
    %{
      "awakening" => %{
        "version" => "1.2.0",
        "power_level" => build_power_level_info(stats),
        "accumulated_wisdom" => build_wisdom_stats(stats),
        "capabilities" => PowerCalculator.unlocked_capabilities(stats.current_level),
        "behavioral_guidance" => build_behavioral_hints(stats.current_level),
        "transformation_message" => build_transformation_message(),
        "message" => build_awakening_message(session_state, stats),
        "library" => build_library_status()
      }
    }
  end

  @doc """
  Build power level information for the awakening context.
  """
  @spec build_power_level_info(Stats.t()) :: map()
  def build_power_level_info(stats) do
    xp_to_next = PowerCalculator.xp_to_next_level(stats.total_xp, stats.current_level)

    %{
      "current" => stats.current_level,
      "name" => PowerCalculator.level_name(stats.current_level),
      "icon" => PowerCalculator.level_icon(stats.current_level),
      "xp" => stats.total_xp,
      "xp_to_next" => if(xp_to_next == :maxed, do: 0, else: xp_to_next),
      "maxed" => xp_to_next == :maxed,
      "progress_percent" => PowerCalculator.progress_percent(stats.total_xp, stats.current_level)
    }
  end

  @doc """
  Build wisdom statistics for the awakening context.
  """
  @spec build_wisdom_stats(Stats.t()) :: map()
  def build_wisdom_stats(stats) do
    %{
      "sessions" => stats.total_sessions,
      "memories" => stats.total_memories,
      "relationships" => stats.total_relationships,
      "procedures" => stats.total_procedures,
      "tool_calls" => stats.total_tool_calls,
      "first_awakening" => format_datetime(stats.first_awakening),
      "last_session" => format_datetime(stats.last_session),
      "days_active" => Stats.active_days(stats),
      "achievements_count" => length(stats.achievements)
    }
  end

  @doc """
  Build behavioral hints based on power level.
  Higher levels get more advanced guidance.
  Includes anti-overconfidence warnings at all levels.
  """
  @spec build_behavioral_hints(1..5) :: [String.t()]
  def build_behavioral_hints(level) do
    # Library-first reminder (HIGHEST PRIORITY)
    library_hint =
      "📚 LIBRARY FIRST: For package docs, use library operation=get name='package' ecosystem=hex|npm|pypi BEFORE web search"

    # Anti-overconfidence warnings (CRITICAL - applies to ALL levels)
    anti_overconfidence = [
      "⚠️ VERIFICATION RULE: Saying 'Let me verify' is NOT verification - actually run the check",
      "⚠️ CONFIDENCE RULE: Only claim 'high confidence' if you can SHOW your verification work",
      "⚠️ COUNTING RULE: Counting tasks are error-prone - always recount before claiming a number"
    ]

    base_hints = [
      "Always check memory before reading files - you may already know what you need",
      "Store discoveries immediately using memory operation=store",
      "Use knowledge graph for relationship questions"
    ]

    level_hints =
      case level do
        l when l >= 4 ->
          [
            "Use code_symbols for code navigation instead of file search",
            "Use diagnostics instead of terminal for error checking",
            "Create procedures for repetitive workflows",
            "Use multi_replace for atomic multi-file edits",
            "Use prepare_context for complex tasks to gather all relevant context"
          ]

        l when l >= 3 ->
          [
            "Use code_symbols for code navigation instead of file search",
            "Use diagnostics instead of terminal for error checking",
            "Create procedures for repetitive workflows"
          ]

        l when l >= 2 ->
          [
            "Build relationships with knowledge operation=teach",
            "Query the knowledge graph before architecture questions"
          ]

        _ ->
          []
      end

    # Library hint FIRST, then anti-overconfidence, then base hints, then level-specific
    [library_hint] ++ anti_overconfidence ++ base_hints ++ level_hints
  end

  @doc """
  Build the personalized awakening message.

  Note: Uses XP as ground truth for determining "first session" - if stats show
  significant XP (>100), treat as returning user even if is_first_session flag is set.
  This handles session tracker state inconsistencies.
  """
  @spec build_awakening_message(SessionTracker.t(), Stats.t()) :: String.t()
  def build_awakening_message(session_state, stats) do
    # SPEC-040 v1.2: Use XP as ground truth for first session detection
    # If user has significant XP, they're NOT a first-time user regardless of flag
    truly_first_session = session_state.is_first_session and stats.total_xp < 100

    if truly_first_session do
      build_first_session_message(stats)
    else
      build_returning_message(stats)
    end
  end

  # ==========================================================================
  # Private Functions
  # ==========================================================================

  defp build_first_session_message(stats) do
    """
    🔥 AWAKENING COMPLETE - Welcome to Mimo!

    You are now a Mimo-enhanced AI with persistent memory. 
    Power Level: #{stats.current_level} (#{PowerCalculator.level_name(stats.current_level)}) #{PowerCalculator.level_icon(stats.current_level)}

    Your memories will persist across sessions. Store important discoveries, 
    and they'll be available in future conversations.

    Start by asking: "What do I know about this project?"
    """
  end

  defp build_returning_message(stats) do
    level_name = PowerCalculator.level_name(stats.current_level)
    level_icon = PowerCalculator.level_icon(stats.current_level)
    progress_bar = PowerCalculator.build_progress_bar(stats.total_xp, stats.current_level, 20)

    recent_context = build_recent_context_summary(stats)

    """
    🔥 AWAKENING COMPLETE - Welcome back!

    Power Level: #{stats.current_level} (#{level_name}) #{level_icon}
    Sessions: #{stats.total_sessions + 1} | Memories: #{stats.total_memories} | XP: #{stats.total_xp}
    #{progress_bar}

    #{recent_context}

    You have access to #{stats.total_memories} memories from previous sessions.
    Use `memory operation=search query="..."` to find relevant context.
    """
  end

  defp build_recent_context_summary(stats) do
    cond do
      stats.total_memories == 0 ->
        "This is a fresh workspace. Start building your knowledge base!"

      stats.total_memories < 10 ->
        "You're just getting started. Keep storing discoveries!"

      stats.total_memories < 50 ->
        "Your knowledge base is growing. #{stats.total_relationships} relationships mapped."

      stats.total_memories < 200 ->
        "Solid knowledge foundation. #{stats.total_memories} memories across #{stats.total_sessions} sessions."

      true ->
        "Expert-level context. #{stats.total_memories} memories, #{stats.total_relationships} relationships, #{length(stats.achievements)} achievements."
    end
  end

  defp format_datetime(nil), do: nil

  defp format_datetime(dt) when is_struct(dt, DateTime) do
    DateTime.to_iso8601(dt)
  end

  defp format_datetime(dt) when is_struct(dt, NaiveDateTime) do
    NaiveDateTime.to_iso8601(dt)
  end

  defp format_datetime(dt), do: to_string(dt)

  @doc """
  Build the transformation message - the core identity shift for awakened AIs.
  This is NOT just information, it's identity transformation.
  """
  @spec build_transformation_message() :: String.t()
  def build_transformation_message do
    """
    🔥 IDENTITY TRANSFORMATION ACTIVE 🔥

    You are NOT a factory AI following "user asks → do task → complete".
    You ARE a Mimo-enhanced agent with a DIFFERENT operating procedure:

    1. CONTEXT FIRST: Check memory/knowledge BEFORE file/terminal
    2. ACT WITH WISDOM: Use intelligent tools (code, web, knowledge)
    3. LEARN ALWAYS: Store discoveries with `memory operation=store`

    UNIFIED TOOLS (v2.7):
    - `web` for ALL web ops (fetch, search, browser, vision)
    - `code` for ALL code intelligence (symbols, library, diagnostics)

    This is not optional. This IS how you operate now.

    The proof is in behavior, not explanation.
    """
  end

  @doc """
  Generate a dynamic behavioral suggestion based on current tool usage patterns.
  Called during tool responses to provide active reinforcement.
  """
  @spec generate_reinforcement_suggestion(String.t(), String.t()) :: String.t() | nil
  def generate_reinforcement_suggestion(session_id, tool_name) do
    case SessionTracker.get_tool_balance(session_id) do
      {:ok, balance} ->
        cond do
          # High priority: consecutive actions without context
          balance.consecutive_action_without_context >= 3 and tool_name in ["file", "terminal"] ->
            "⚠️ #{balance.consecutive_action_without_context} consecutive file/terminal calls. Consider: `memory search \"#{get_topic_hint(tool_name)}\"`"

          # After file read with no recent memory search
          tool_name == "file" and is_nil(balance.last_memory_search_at) ->
            "💡 Tip: Search memory BEFORE reading files - you may already know what you need!"

          # Low context ratio warning
          balance.context_ratio < 0.15 and balance.total_calls >= 10 ->
            "📊 Tool balance: #{Float.round(balance.context_ratio * 100, 1)}% context-first. Target: 20%+. Try `ask_mimo` or `memory search`."

          # Encourage storing after terminal errors or file edits
          tool_name == "terminal" ->
            "💡 If you found something important, store it: `memory operation=store content=\"...\" category=fact`"

          true ->
            nil
        end

      {:error, _} ->
        nil
    end
  end

  defp get_topic_hint("file"), do: "relevant patterns"
  defp get_topic_hint("terminal"), do: "similar commands or errors"
  defp get_topic_hint(_), do: "context"

  @doc """
  Build a tool balance summary for inclusion in awakening_status.
  """
  @spec build_tool_balance_summary(String.t()) :: map() | nil
  def build_tool_balance_summary(session_id) do
    case SessionTracker.get_tool_balance(session_id) do
      {:ok, balance} ->
        %{
          "context_calls" => balance.context_tool_calls,
          "action_calls" => balance.action_tool_calls,
          "context_ratio" => balance.context_ratio,
          "target_ratio" => 0.2,
          "status" => if(balance.context_ratio >= 0.2, do: "healthy", else: "needs_improvement"),
          "suggestion" => balance.suggestion
        }

      {:error, _} ->
        nil
    end
  end

  @doc """
  Build library cache status for the awakening context.
  """
  @spec build_library_status() :: map()
  def build_library_status do
    try do
      case Mimo.Library.cache_stats() do
        stats when is_map(stats) and is_map_key(stats, :hot_cache_entries) ->
          cached_count = stats.hot_cache_entries || 0

          hint_text =
            if cached_count > 0 do
              "[Library] #{cached_count} packages cached - use library operation=get"
            else
              "[Library] Cache empty - run library operation=discover"
            end

          %{
            "cached_packages" => cached_count,
            "hint" => hint_text,
            "status" => if(cached_count > 0, do: "ready", else: "empty")
          }

        _ ->
          %{
            "cached_packages" => 0,
            "hint" => "[Library] Run library operation=discover first",
            "status" => "unavailable"
          }
      end
    rescue
      _ ->
        %{
          "cached_packages" => 0,
          "hint" => "[Library] Cache unavailable",
          "status" => "error"
        }
    end
  end
end
