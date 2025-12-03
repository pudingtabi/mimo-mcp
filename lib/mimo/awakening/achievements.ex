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
      # Add achievements and bonus XP
      new_achievement_ids = Enum.map(newly_unlocked, & &1.id)
      all_achievements = (stats.achievements || []) ++ new_achievement_ids
      new_xp = stats.total_xp + bonus_xp
      new_level = Mimo.Awakening.PowerCalculator.calculate_level(new_xp)

      case stats
           |> Stats.changeset(%{
             achievements: all_achievements,
             total_xp: new_xp,
             current_level: new_level
           })
           |> Mimo.Repo.update() do
        {:ok, updated_stats} ->
          # Log the achievements
          Enum.each(newly_unlocked, fn a ->
            Logger.info("🏆 Achievement Unlocked: #{a.name} (+#{a.xp} XP)")
          end)

          {:ok, updated_stats, newly_unlocked}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  Get progress towards an achievement.
  Returns `{current, target, percentage}`.
  """
  @spec get_progress(String.t(), Stats.t()) :: {non_neg_integer(), non_neg_integer(), float()}
  def get_progress(achievement_id, stats) do
    case achievement_id do
      # Memory achievements
      "first_memory" -> progress_calc(stats.total_memories, 1)
      "memory_10" -> progress_calc(stats.total_memories, 10)
      "memory_100" -> progress_calc(stats.total_memories, 100)
      "memory_500" -> progress_calc(stats.total_memories, 500)
      "memory_1000" -> progress_calc(stats.total_memories, 1000)
      # Session achievements
      "first_session" -> progress_calc(stats.total_sessions, 1)
      "sessions_10" -> progress_calc(stats.total_sessions, 10)
      "sessions_50" -> progress_calc(stats.total_sessions, 50)
      "sessions_100" -> progress_calc(stats.total_sessions, 100)
      # Relationship achievements
      "first_relationship" -> progress_calc(stats.total_relationships, 1)
      "relationships_10" -> progress_calc(stats.total_relationships, 10)
      "relationships_50" -> progress_calc(stats.total_relationships, 50)
      "relationships_100" -> progress_calc(stats.total_relationships, 100)
      # Procedure achievements
      "first_procedure" -> progress_calc(stats.total_procedures, 1)
      "procedures_5" -> progress_calc(stats.total_procedures, 5)
      "procedures_10" -> progress_calc(stats.total_procedures, 10)
      # Tool achievements
      "tools_100" -> progress_calc(stats.total_tool_calls, 100)
      "tools_1000" -> progress_calc(stats.total_tool_calls, 1000)
      "tools_10000" -> progress_calc(stats.total_tool_calls, 10_000)
      # Level achievements
      "level_2" -> progress_calc(stats.current_level, 2)
      "level_3" -> progress_calc(stats.current_level, 3)
      "level_4" -> progress_calc(stats.current_level, 4)
      "level_5" -> progress_calc(stats.current_level, 5)
      # XP achievements
      "xp_100" -> progress_calc(stats.total_xp, 100)
      "xp_1000" -> progress_calc(stats.total_xp, 1000)
      "xp_5000" -> progress_calc(stats.total_xp, 5000)
      "xp_10000" -> progress_calc(stats.total_xp, 10_000)
      _ -> {0, 1, 0.0}
    end
  end

  # ==========================================================================
  # Private Functions
  # ==========================================================================

  defp achievement_unlocked?(id, stats, _event) do
    case id do
      # Memory achievements
      "first_memory" -> stats.total_memories >= 1
      "memory_10" -> stats.total_memories >= 10
      "memory_100" -> stats.total_memories >= 100
      "memory_500" -> stats.total_memories >= 500
      "memory_1000" -> stats.total_memories >= 1000
      # Session achievements
      "first_session" -> stats.total_sessions >= 1
      "sessions_10" -> stats.total_sessions >= 10
      "sessions_50" -> stats.total_sessions >= 50
      "sessions_100" -> stats.total_sessions >= 100
      # Relationship achievements
      "first_relationship" -> stats.total_relationships >= 1
      "relationships_10" -> stats.total_relationships >= 10
      "relationships_50" -> stats.total_relationships >= 50
      "relationships_100" -> stats.total_relationships >= 100
      # Procedure achievements
      "first_procedure" -> stats.total_procedures >= 1
      "procedures_5" -> stats.total_procedures >= 5
      "procedures_10" -> stats.total_procedures >= 10
      # Tool achievements
      "tools_100" -> stats.total_tool_calls >= 100
      "tools_1000" -> stats.total_tool_calls >= 1000
      "tools_10000" -> stats.total_tool_calls >= 10_000
      # Level achievements
      "level_2" -> stats.current_level >= 2
      "level_3" -> stats.current_level >= 3
      "level_4" -> stats.current_level >= 4
      "level_5" -> stats.current_level >= 5
      # XP achievements
      "xp_100" -> stats.total_xp >= 100
      "xp_1000" -> stats.total_xp >= 1000
      "xp_5000" -> stats.total_xp >= 5000
      "xp_10000" -> stats.total_xp >= 10_000
      _ -> false
    end
  end

  defp progress_calc(current, target) do
    current = current || 0
    percentage = min(100.0, Float.round(current / target * 100, 1))
    {current, target, percentage}
  end
end
