defmodule Mimo.Awakening.Achievements do
  @moduledoc """
  SPEC-040: Achievement System for Awakening Protocol

  Gamification layer that rewards progress and encourages engagement.
  Achievements are unlocked by reaching milestones and grant bonus XP.

  ## Achievement Categories

  - **Memory**: Building the knowledge base
  - **Sessions**: Consistent usage
  - **Knowledge Graph**: Relationship building
  - **Procedures**: Automation mastery
  - **Special**: Meta-achievements
  """
  require Logger

  alias Mimo.Awakening.Stats

  @type achievement :: %{
          id: String.t(),
          name: String.t(),
          desc: String.t(),
          xp: non_neg_integer(),
          icon: String.t(),
          category: atom()
        }

  # All achievement definitions
  @achievements [
    # Memory Achievements
    %{
      id: "first_memory",
      name: "First Memory",
      desc: "Store your first memory",
      xp: 10,
      icon: "🧠",
      category: :memory
    },
    %{
      id: "memory_10",
      name: "Growing Mind",
      desc: "Store 10 memories",
      xp: 25,
      icon: "📚",
      category: :memory
    },
    %{
      id: "memory_100",
      name: "Librarian",
      desc: "Store 100 memories",
      xp: 100,
      icon: "📖",
      category: :memory
    },
    %{
      id: "memory_500",
      name: "Archivist",
      desc: "Store 500 memories",
      xp: 250,
      icon: "🏛️",
      category: :memory
    },
    %{
      id: "memory_1000",
      name: "Memory Palace",
      desc: "Store 1000 memories",
      xp: 500,
      icon: "🏰",
      category: :memory
    },

    # Session Achievements
    %{
      id: "first_session",
      name: "Awakened",
      desc: "Complete first session",
      xp: 20,
      icon: "⚡",
      category: :session
    },
    %{
      id: "sessions_10",
      name: "Regular",
      desc: "Complete 10 sessions",
      xp: 50,
      icon: "🔄",
      category: :session
    },
    %{
      id: "sessions_50",
      name: "Dedicated",
      desc: "Complete 50 sessions",
      xp: 150,
      icon: "💪",
      category: :session
    },
    %{
      id: "sessions_100",
      name: "Veteran",
      desc: "Complete 100 sessions",
      xp: 250,
      icon: "🎖️",
      category: :session
    },

    # Knowledge Graph Achievements
    %{
      id: "first_relationship",
      name: "Connected",
      desc: "Create first relationship",
      xp: 15,
      icon: "🔗",
      category: :graph
    },
    %{
      id: "relationships_10",
      name: "Networker",
      desc: "Create 10 relationships",
      xp: 30,
      icon: "🕸️",
      category: :graph
    },
    %{
      id: "relationships_50",
      name: "Web Weaver",
      desc: "Create 50 relationships",
      xp: 100,
      icon: "🌐",
      category: :graph
    },
    %{
      id: "relationships_100",
      name: "Graph Master",
      desc: "Create 100 relationships",
      xp: 200,
      icon: "🗺️",
      category: :graph
    },

    # Procedure Achievements
    %{
      id: "first_procedure",
      name: "Automator",
      desc: "Create first procedure",
      xp: 50,
      icon: "⚙️",
      category: :procedure
    },
    %{
      id: "procedures_5",
      name: "Workflow Builder",
      desc: "Create 5 procedures",
      xp: 100,
      icon: "🔧",
      category: :procedure
    },
    %{
      id: "procedures_10",
      name: "Automation Expert",
      desc: "Create 10 procedures",
      xp: 200,
      icon: "🤖",
      category: :procedure
    },

    # Tool Usage Achievements
    %{
      id: "tools_100",
      name: "Tool User",
      desc: "Make 100 tool calls",
      xp: 25,
      icon: "🔨",
      category: :tools
    },
    %{
      id: "tools_1000",
      name: "Power User",
      desc: "Make 1000 tool calls",
      xp: 100,
      icon: "⚒️",
      category: :tools
    },
    %{
      id: "tools_10_000",
      name: "Tool Master",
      desc: "Make 10000 tool calls",
      xp: 500,
      icon: "🛠️",
      category: :tools
    },

    # Special Achievements
    %{
      id: "level_2",
      name: "Enhanced",
      desc: "Reach Power Level 2",
      xp: 50,
      icon: "🌓",
      category: :special
    },
    %{
      id: "level_3",
      name: "Awakened",
      desc: "Reach Power Level 3",
      xp: 100,
      icon: "🌕",
      category: :special
    },
    %{
      id: "level_4",
      name: "Ascended",
      desc: "Reach Power Level 4",
      xp: 200,
      icon: "⭐",
      category: :special
    },
    %{
      id: "level_5",
      name: "Ultra Instinct",
      desc: "Reach Power Level 5",
      xp: 1000,
      icon: "🌌",
      category: :special
    },

    # XP Milestones
    %{id: "xp_100", name: "Century", desc: "Earn 100 total XP", xp: 10, icon: "💯", category: :xp},
    %{
      id: "xp_1000",
      name: "Thousand",
      desc: "Earn 1000 total XP",
      xp: 50,
      icon: "🎯",
      category: :xp
    },
    %{
      id: "xp_5000",
      name: "Five Thousand",
      desc: "Earn 5000 total XP",
      xp: 100,
      icon: "🏆",
      category: :xp
    },
    %{
      id: "xp_10000",
      name: "Ten Thousand",
      desc: "Earn 10000 total XP",
      xp: 500,
      icon: "👑",
      category: :xp
    }
  ]

  # ==========================================================================
  # Public API
  # ==========================================================================

  @doc """
  Get all achievement definitions.
  """
  @spec all_achievements() :: [achievement()]
  def all_achievements, do: @achievements

  @doc """
  Get a specific achievement by ID.
  """
  @spec get_achievement(String.t()) :: achievement() | nil
  def get_achievement(id) do
    Enum.find(@achievements, fn a -> a.id == id end)
  end

  @doc """
  Get achievements by category.
  """
  @spec get_by_category(atom()) :: [achievement()]
  def get_by_category(category) do
    Enum.filter(@achievements, fn a -> a.category == category end)
  end

  @doc """
  Check for newly unlocked achievements and award XP.

  Returns `{newly_unlocked, total_xp_earned}`.
  """
  @spec check_and_award(Stats.t(), atom()) :: {[achievement()], non_neg_integer()}
  def check_and_award(stats, event \\ nil) do
    already_unlocked = stats.achievements || []

    newly_unlocked =
      @achievements
      |> Enum.reject(fn a -> a.id in already_unlocked end)
      |> Enum.filter(fn a -> achievement_unlocked?(a.id, stats, event) end)

    total_xp = Enum.sum(Enum.map(newly_unlocked, & &1.xp))

    {newly_unlocked, total_xp}
  end

  @doc """
  Process achievements for stats and update if any are newly unlocked.
  Returns updated stats with achievements added.
  """
  @spec process_achievements(Stats.t()) :: {:ok, Stats.t(), [achievement()]} | {:error, term()}
  def process_achievements(stats) do
    {newly_unlocked, bonus_xp} = check_and_award(stats)

    if Enum.empty?(newly_unlocked) do
      {:ok, stats, []}
    else
      update_stats_with_achievements(stats, newly_unlocked, bonus_xp)
    end
  end

  defp update_stats_with_achievements(stats, newly_unlocked, bonus_xp) do
    new_achievement_ids = Enum.map(newly_unlocked, & &1.id)
    all_achievements = (stats.achievements || []) ++ new_achievement_ids
    new_xp = stats.total_xp + bonus_xp
    new_level = Mimo.Awakening.PowerCalculator.calculate_level(new_xp)

    changeset =
      Stats.changeset(stats, %{
        achievements: all_achievements,
        total_xp: new_xp,
        current_level: new_level
      })

    case Mimo.Repo.update(changeset) do
      {:ok, updated_stats} ->
        log_unlocked_achievements(newly_unlocked)
        {:ok, updated_stats, newly_unlocked}

      {:error, _} = error ->
        error
    end
  end

  defp log_unlocked_achievements(achievements) do
    Enum.each(achievements, fn a ->
      Logger.info("🏆 Achievement Unlocked: #{a.name} (+#{a.xp} XP)")
    end)
  end

  @doc """
  Get progress towards an achievement.
  Returns `{current, target, percentage}`.
  """
  @spec get_progress(String.t(), Stats.t()) :: {non_neg_integer(), non_neg_integer(), float()}
  def get_progress(achievement_id, stats) do
    do_get_progress(achievement_id, stats)
  end

  # Memory achievements
  defp do_get_progress("first_memory", s), do: progress_calc(s.total_memories, 1)
  defp do_get_progress("memory_10", s), do: progress_calc(s.total_memories, 10)
  defp do_get_progress("memory_100", s), do: progress_calc(s.total_memories, 100)
  defp do_get_progress("memory_500", s), do: progress_calc(s.total_memories, 500)
  defp do_get_progress("memory_1000", s), do: progress_calc(s.total_memories, 1000)

  # Session achievements
  defp do_get_progress("first_session", s), do: progress_calc(s.total_sessions, 1)
  defp do_get_progress("sessions_10", s), do: progress_calc(s.total_sessions, 10)
  defp do_get_progress("sessions_50", s), do: progress_calc(s.total_sessions, 50)
  defp do_get_progress("sessions_100", s), do: progress_calc(s.total_sessions, 100)

  # Relationship achievements
  defp do_get_progress("first_relationship", s), do: progress_calc(s.total_relationships, 1)
  defp do_get_progress("relationships_10", s), do: progress_calc(s.total_relationships, 10)
  defp do_get_progress("relationships_50", s), do: progress_calc(s.total_relationships, 50)
  defp do_get_progress("relationships_100", s), do: progress_calc(s.total_relationships, 100)

  # Procedure achievements
  defp do_get_progress("first_procedure", s), do: progress_calc(s.total_procedures, 1)
  defp do_get_progress("procedures_5", s), do: progress_calc(s.total_procedures, 5)
  defp do_get_progress("procedures_10", s), do: progress_calc(s.total_procedures, 10)

  # Tool achievements
  defp do_get_progress("tools_100", s), do: progress_calc(s.total_tool_calls, 100)
  defp do_get_progress("tools_1000", s), do: progress_calc(s.total_tool_calls, 1000)
  defp do_get_progress("tools_10000", s), do: progress_calc(s.total_tool_calls, 10_000)

  # Level achievements
  defp do_get_progress("level_2", s), do: progress_calc(s.current_level, 2)
  defp do_get_progress("level_3", s), do: progress_calc(s.current_level, 3)
  defp do_get_progress("level_4", s), do: progress_calc(s.current_level, 4)
  defp do_get_progress("level_5", s), do: progress_calc(s.current_level, 5)

  # XP achievements
  defp do_get_progress("xp_100", s), do: progress_calc(s.total_xp, 100)
  defp do_get_progress("xp_1000", s), do: progress_calc(s.total_xp, 1000)
  defp do_get_progress("xp_5000", s), do: progress_calc(s.total_xp, 5000)
  defp do_get_progress("xp_10000", s), do: progress_calc(s.total_xp, 10_000)

  # Unknown
  defp do_get_progress(_, _), do: {0, 1, 0.0}

  # ==========================================================================
  # Private Functions
  # ==========================================================================

  defp achievement_unlocked?(id, stats, _event), do: do_achievement_unlocked(id, stats)

  # Memory achievements
  defp do_achievement_unlocked("first_memory", s), do: s.total_memories >= 1
  defp do_achievement_unlocked("memory_10", s), do: s.total_memories >= 10
  defp do_achievement_unlocked("memory_100", s), do: s.total_memories >= 100
  defp do_achievement_unlocked("memory_500", s), do: s.total_memories >= 500
  defp do_achievement_unlocked("memory_1000", s), do: s.total_memories >= 1000

  # Session achievements
  defp do_achievement_unlocked("first_session", s), do: s.total_sessions >= 1
  defp do_achievement_unlocked("sessions_10", s), do: s.total_sessions >= 10
  defp do_achievement_unlocked("sessions_50", s), do: s.total_sessions >= 50
  defp do_achievement_unlocked("sessions_100", s), do: s.total_sessions >= 100

  # Relationship achievements
  defp do_achievement_unlocked("first_relationship", s), do: s.total_relationships >= 1
  defp do_achievement_unlocked("relationships_10", s), do: s.total_relationships >= 10
  defp do_achievement_unlocked("relationships_50", s), do: s.total_relationships >= 50
  defp do_achievement_unlocked("relationships_100", s), do: s.total_relationships >= 100

  # Procedure achievements
  defp do_achievement_unlocked("first_procedure", s), do: s.total_procedures >= 1
  defp do_achievement_unlocked("procedures_5", s), do: s.total_procedures >= 5
  defp do_achievement_unlocked("procedures_10", s), do: s.total_procedures >= 10

  # Tool achievements
  defp do_achievement_unlocked("tools_100", s), do: s.total_tool_calls >= 100
  defp do_achievement_unlocked("tools_1000", s), do: s.total_tool_calls >= 1000
  defp do_achievement_unlocked("tools_10000", s), do: s.total_tool_calls >= 10_000

  # Level achievements
  defp do_achievement_unlocked("level_2", s), do: s.current_level >= 2
  defp do_achievement_unlocked("level_3", s), do: s.current_level >= 3
  defp do_achievement_unlocked("level_4", s), do: s.current_level >= 4
  defp do_achievement_unlocked("level_5", s), do: s.current_level >= 5

  # XP achievements
  defp do_achievement_unlocked("xp_100", s), do: s.total_xp >= 100
  defp do_achievement_unlocked("xp_1000", s), do: s.total_xp >= 1000
  defp do_achievement_unlocked("xp_5000", s), do: s.total_xp >= 5000
  defp do_achievement_unlocked("xp_10000", s), do: s.total_xp >= 10_000

  # Unknown
  defp do_achievement_unlocked(_, _), do: false

  defp progress_calc(current, target) do
    current = current || 0
    percentage = min(100.0, Float.round(current / target * 100, 1))
    {current, target, percentage}
  end
end
