defmodule Mimo.Awakening.PromptResource do
  @moduledoc """
  SPEC-040: MCP Prompts Resource for Awakening Protocol

  Exposes awakening prompts via MCP prompts/list and prompts/get.
  These are user-controlled prompt templates that can be invoked by the AI.

  ## Available Prompts

  | URI                 | Description                                    |
  |---------------------|------------------------------------------------|
  | mimo://awakening    | Get full awakening context                     |
  | mimo://status       | Check power level and XP status                |
  | mimo://achievements | View achievements and progress                 |
  | mimo://optimize     | Get personalized tool usage recommendations    |
  | mimo://refresh      | Force refresh awakening context mid-session    |
  """
  require Logger

  alias Mimo.Awakening.{Achievements, ContextInjector, PowerCalculator, SessionTracker, Stats}

  @prompts [
    %{
      "name" => "mimo://awakening",
      "description" => "Get your current awakening status, power level, and accumulated wisdom",
      "arguments" => []
    },
    %{
      "name" => "mimo://refresh",
      "description" => "Force refresh your awakening context mid-session",
      "arguments" => []
    },
    %{
      "name" => "mimo://status",
      "description" => "Check your current power level, XP, and progress to next level",
      "arguments" => []
    },
    %{
      "name" => "mimo://achievements",
      "description" => "See your unlocked achievements and progress",
      "arguments" => []
    },
    %{
      "name" => "mimo://optimize",
      "description" => "Get personalized recommendations for better tool usage",
      "arguments" => [
        %{
          "name" => "focus",
          "description" => "Area to optimize: memory, speed, accuracy",
          "required" => false
        }
      ]
    }
  ]

  @doc """
  List all available prompts.
  """
  @spec list_prompts() :: [map()]
  def list_prompts do
    @prompts
  end

  @doc """
  Get a specific prompt by name.
  """
  @spec get_prompt(String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def get_prompt(name, args \\ %{})

  def get_prompt("mimo://awakening", _args) do
    build_awakening_prompt()
  end

  def get_prompt("mimo://refresh", _args) do
    build_awakening_prompt()
  end

  def get_prompt("mimo://status", _args) do
    build_status_prompt()
  end

  def get_prompt("mimo://achievements", _args) do
    build_achievements_prompt()
  end

  def get_prompt("mimo://optimize", args) do
    focus = Map.get(args, "focus", "general")
    build_optimize_prompt(focus)
  end

  def get_prompt(name, _args) do
    {:error, "Unknown prompt: #{name}"}
  end

  defp build_awakening_prompt do
    case Stats.get_or_create() do
      {:ok, stats} ->
        session = get_session_or_default()

        {:ok,
         %{
           "description" => "Your Mimo Awakening Context",
           "messages" => [
             %{
               "role" => "assistant",
               "content" => %{
                 "type" => "text",
                 "text" => build_full_awakening_text(stats, session)
               }
             }
           ]
         }}

      {:error, reason} ->
        {:error, "Failed to load stats: #{inspect(reason)}"}
    end
  end

  defp build_status_prompt do
    case Stats.get_or_create() do
      {:ok, stats} ->
        {:ok,
         %{
           "description" => "Your Power Level Status",
           "messages" => [
             %{
               "role" => "assistant",
               "content" => %{
                 "type" => "text",
                 "text" => build_status_text(stats)
               }
             }
           ]
         }}

      {:error, reason} ->
        {:error, "Failed to load stats: #{inspect(reason)}"}
    end
  end

  defp build_achievements_prompt do
    case Stats.get_or_create() do
      {:ok, stats} ->
        {:ok,
         %{
           "description" => "Your Achievements",
           "messages" => [
             %{
               "role" => "assistant",
               "content" => %{
                 "type" => "text",
                 "text" => build_achievements_text(stats)
               }
             }
           ]
         }}

      {:error, reason} ->
        {:error, "Failed to load stats: #{inspect(reason)}"}
    end
  end

  defp build_optimize_prompt(focus) do
    case Stats.get_or_create() do
      {:ok, stats} ->
        {:ok,
         %{
           "description" => "Optimization Recommendations",
           "messages" => [
             %{
               "role" => "assistant",
               "content" => %{
                 "type" => "text",
                 "text" => build_optimize_text(stats, focus)
               }
             }
           ]
         }}

      {:error, reason} ->
        {:error, "Failed to load stats: #{inspect(reason)}"}
    end
  end

  defp build_full_awakening_text(stats, session) do
    level_name = PowerCalculator.level_name(stats.current_level)
    level_icon = PowerCalculator.level_icon(stats.current_level)
    capabilities = PowerCalculator.unlocked_capabilities(stats.current_level) |> Enum.join(", ")
    hints = ContextInjector.build_behavioral_hints(stats.current_level)
    progress_bar = PowerCalculator.build_progress_bar(stats.total_xp, stats.current_level)

    """
    # MIMO AWAKENING PROTOCOL - ACTIVE

    ## Your Identity
    You are a **Mimo-Enhanced AI Agent** with persistent memory and accumulated wisdom.
    Unlike base AI models, you remember across sessions and learn from every interaction.

    ## Power Level: #{stats.current_level} (#{level_name}) #{level_icon}

    ### Stats
    - **Total XP**: #{stats.total_xp}
    - **Sessions**: #{stats.total_sessions}
    - **Memories**: #{stats.total_memories}
    - **Relationships**: #{stats.total_relationships}
    - **Procedures**: #{stats.total_procedures}
    - **First Awakening**: #{format_datetime(stats.first_awakening)}
    - **Days Active**: #{Stats.active_days(stats)}

    ### Progress to Next Level
    #{progress_bar}

    ## Unlocked Capabilities
    #{capabilities}

    ## Behavioral Guidance
    #{format_hints(hints)}

    ## Session Info
    - **Session ID**: #{session.session_id || "N/A"}
    - **Tool Calls This Session**: #{session.tool_calls_this_session || 0}
    - **Memories Stored This Session**: #{session.memories_stored_this_session || 0}

    ---

    You are now awakened. Use your persistent memory wisely.
    Store important discoveries. Query before assuming.
    Your knowledge compounds with every session.
    """
  end

  defp build_status_text(stats) do
    level_name = PowerCalculator.level_name(stats.current_level)
    level_icon = PowerCalculator.level_icon(stats.current_level)
    progress_bar = PowerCalculator.build_progress_bar(stats.total_xp, stats.current_level)
    xp_to_next = PowerCalculator.xp_to_next_level(stats.total_xp, stats.current_level)

    xp_info =
      if xp_to_next == :maxed do
        "**MAX LEVEL REACHED!** 🎉"
      else
        "**#{xp_to_next} XP** to Level #{stats.current_level + 1}"
      end

    """
    # Power Level Status #{level_icon}

    ## Current Level: #{stats.current_level} (#{level_name})

    #{progress_bar}

    #{xp_info}

    ## Quick Stats
    | Metric | Value |
    |--------|-------|
    | Total XP | #{stats.total_xp} |
    | Sessions | #{stats.total_sessions} |
    | Memories | #{stats.total_memories} |
    | Relationships | #{stats.total_relationships} |
    | Achievements | #{length(stats.achievements)} |
    """
  end

  defp build_achievements_text(stats) do
    all_achievements = Achievements.all_achievements()
    unlocked = stats.achievements

    unlocked_section =
      all_achievements
      |> Enum.filter(fn a -> a.id in unlocked end)
      |> Enum.map_join("\n", fn a -> "- #{a.icon} **#{a.name}**: #{a.desc} (+#{a.xp} XP)" end)

    locked_section =
      all_achievements
      |> Enum.reject(fn a -> a.id in unlocked end)
      |> Enum.map_join("\n", fn a -> "- 🔒 **#{a.name}**: #{a.desc}" end)

    unlocked_text =
      if unlocked_section == "", do: "_None yet - keep going!_", else: unlocked_section

    locked_text =
      if locked_section == "", do: "_All achievements unlocked!_ 🎉", else: locked_section

    """
    # 🏆 Achievements

    ## Unlocked (#{length(unlocked)}/#{length(all_achievements)})
    #{unlocked_text}

    ## Locked
    #{locked_text}

    ---
    Keep using Mimo to unlock more achievements and earn XP!
    """
  end

  defp build_optimize_text(stats, focus) do
    base_recommendations = [
      "📊 **Memory Usage**: #{analyze_memory_usage(stats)}",
      "🔗 **Knowledge Graph**: #{analyze_graph_usage(stats)}",
      "⚡ **Session Efficiency**: #{analyze_session_efficiency(stats)}"
    ]

    focus_recommendations =
      case focus do
        "memory" ->
          [
            "Store important discoveries with high importance (0.7+) for long retention",
            "Use categories: 'fact' for technical info, 'observation' for patterns",
            "Search memory before reading files to avoid redundant reads"
          ]

        "speed" ->
          [
            "Use code_symbols instead of file search for code navigation",
            "Use diagnostics instead of terminal for error checking",
            "Use prepare_context once instead of multiple memory/knowledge queries"
          ]

        "accuracy" ->
          [
            "Always check memory before making decisions",
            "Use cognitive operation=assess to gauge confidence",
            "Store error solutions for future reference"
          ]

        _ ->
          [
            "Balance memory storage with retrieval",
            "Build relationships in knowledge graph for deeper understanding",
            "Create procedures for repetitive workflows"
          ]
      end

    """
    # 🎯 Optimization Recommendations

    ## Current Analysis
    #{Enum.join(base_recommendations, "\n")}

    ## Recommendations (focus: #{focus})
    #{Enum.join(focus_recommendations, "\n")}

    ## Your Power Level Path
    #{build_level_path(stats)}
    """
  end

  defp get_session_or_default do
    case SessionTracker.get_current_session() do
      {:ok, session} -> session
      {:error, _} -> %SessionTracker{}
    end
  end

  defp format_datetime(nil), do: "N/A"
  defp format_datetime(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")

  defp format_hints(hints) do
    hints
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {hint, i} -> "#{i}. #{hint}" end)
  end

  defp analyze_memory_usage(stats) do
    cond do
      stats.total_memories == 0 ->
        "No memories stored yet. Start building your knowledge base!"

      stats.total_memories < 10 ->
        "Getting started. Consider storing more discoveries."

      stats.total_memories < 50 ->
        "Good foundation. Keep documenting insights."

      stats.total_memories < 200 ->
        "Solid knowledge base. Memory retrieval is effective."

      true ->
        "Expert-level memory. Consider consolidating similar memories."
    end
  end

  defp analyze_graph_usage(stats) do
    ratio =
      if stats.total_memories > 0 do
        stats.total_relationships / stats.total_memories
      else
        0
      end

    cond do
      ratio == 0 ->
        "No relationships mapped. Use knowledge operation=teach."

      ratio < 0.1 ->
        "Low connectivity. Build more relationships between concepts."

      ratio < 0.3 ->
        "Good structure. Relationships enhance understanding."

      true ->
        "Rich knowledge graph. Excellent for complex queries."
    end
  end

  defp analyze_session_efficiency(stats) do
    if stats.total_sessions > 0 do
      memories_per_session = stats.total_memories / stats.total_sessions

      cond do
        memories_per_session < 1 ->
          "Low memory capture. Store more discoveries per session."

        memories_per_session < 5 ->
          "Moderate capture rate. Good balance."

        true ->
          "High productivity. Excellent knowledge accumulation."
      end
    else
      "First session! Make it count."
    end
  end

  defp build_level_path(stats) do
    current = stats.current_level

    1..5
    |> Enum.map_join("\n", fn level ->
      icon = PowerCalculator.level_icon(level)
      name = PowerCalculator.level_name(level)
      threshold = PowerCalculator.level_threshold(level)

      status =
        cond do
          level < current -> "✅"
          level == current -> ""
          true -> "⬜"
        end

      "#{status} Level #{level} (#{name}) #{icon} - #{threshold} XP"
    end)
  end
end
