defmodule Mimo.Awakening.PowerCalculator do
  @moduledoc """
  SPEC-040 v1.2: Power Level Calculation (Recalibrated)

  Calculates power levels based on XP accumulation.
  Like Dragon Ball's Super Saiyan transformations, each level unlocks new capabilities.

  ## Power Levels (v1.2 - Recalibrated for meaningful progression)

  | Level | Name        | Icon | XP Required | Represents                              |
  |-------|-------------|------|-------------|----------------------------------------|
  | 1     | Base        | 🌑   | 0           | Just connected, no history              |
  | 2     | Enhanced    | 🌓   | 1,000       | ~1-2 days active use, understands basics|
  | 3     | Awakened    | 🌕   | 10,000      | ~2 weeks, meaningful memory corpus      |
  | 4     | Ascended    | ⭐   | 50,000      | ~2-3 months, deep knowledge graph       |
  | 5     | Ultra       | 🌌   | 200,000     | ~6+ months, master-level wisdom         |
  | 6     | Transcendent| 💎   | 1,000,000   | ~2+ years, legendary status             |

  ## XP Generation Estimates

  Active user: ~500-1000 XP/day (200-400 tool calls + memory/knowledge bonuses)
  Levels should represent genuine milestones, not quick unlocks.
  """

  # XP thresholds for each power level (SPEC-040 v1.3 recalibrated for achievable progression)
  # Previously thresholds were too high relative to XP values (1000 tool calls to level 2!)
  # Now: Level 2 = ~20 tool calls, Level 3 = ~100 tool calls, etc.
  @level_thresholds %{
    1 => 0,
    # ~20 tool calls or 20 memories (was 1,000)
    2 => 100,
    # ~100 tool calls (was 10,000)
    3 => 500,
    # ~400 tool calls (was 50,000)
    4 => 2_000,
    # ~2,000 tool calls (was 200,000)
    5 => 10_000,
    # ~10,000 tool calls, legendary (was 1,000,000)
    6 => 50_000
  }

  # XP values for different events
  @xp_values %{
    memory_stored: 5,
    memory_accessed: 1,
    knowledge_taught: 10,
    graph_query: 2,
    procedure_created: 50,
    procedure_executed: 5,
    session_completed: 20,
    tool_call: 1,
    error_solved: 25
  }

  # Level metadata (SPEC-040 v1.2 - added Transcendent)
  @level_names %{
    1 => "Base",
    2 => "Enhanced",
    3 => "Awakened",
    4 => "Ascended",
    5 => "Ultra",
    6 => "Transcendent"
  }

  @level_icons %{
    1 => "🌑",
    2 => "🌓",
    3 => "🌕",
    4 => "⭐",
    5 => "🌌",
    6 => "💎"
  }

  @doc """
  Calculate power level from total XP.

  ## Thresholds (v1.2)
  - Level 1: 0 XP
  - Level 2: 1,000 XP
  - Level 3: 10,000 XP
  - Level 4: 50,000 XP
  - Level 5: 200,000 XP
  - Level 6: 1,000,000 XP

  ## Examples

      iex> PowerCalculator.calculate_level(0)
      1

      iex> PowerCalculator.calculate_level(999)
      1

      iex> PowerCalculator.calculate_level(1000)
      2

      iex> PowerCalculator.calculate_level(9999)
      2

      iex> PowerCalculator.calculate_level(10000)
      3

      iex> PowerCalculator.calculate_level(50000)
      4

      iex> PowerCalculator.calculate_level(200000)
      5
  """
  @spec calculate_level(non_neg_integer()) :: 1..6
  def calculate_level(total_xp) when is_integer(total_xp) and total_xp >= 0 do
    @level_thresholds
    |> Enum.filter(fn {_level, threshold} -> total_xp >= threshold end)
    |> Enum.max_by(fn {level, _} -> level end)
    |> elem(0)
  end

  @doc """
  Calculate XP needed to reach the next level.

  ## Returns

  - Integer XP needed
  - `:maxed` if already at max level

  ## Examples

      iex> PowerCalculator.xp_to_next_level(50, 1)
      50

      iex> PowerCalculator.xp_to_next_level(10000, 5)
      :maxed
  """
  @spec xp_to_next_level(non_neg_integer(), 1..6) :: non_neg_integer() | :maxed
  def xp_to_next_level(current_xp, current_level) do
    case Map.get(@level_thresholds, current_level + 1) do
      nil -> :maxed
      next_threshold -> max(0, next_threshold - current_xp)
    end
  end

  @doc """
  Calculate progress percentage to next level.

  Returns 0.0 if XP is below the threshold for current level (level drift protection).
  Returns 100.0 if at max level.

  ## Thresholds (v1.2)
  Level 1→2: 0 to 1,000 XP (range: 1,000)
  Level 2→3: 1,000 to 10,000 XP (range: 9,000)
  Level 3→4: 10,000 to 50,000 XP (range: 40,000)
  Level 4→5: 50,000 to 200,000 XP (range: 150,000)
  Level 5→6: 200,000 to 1,000,000 XP (range: 800,000)

  ## Examples

      iex> PowerCalculator.progress_percent(0, 1)
      0.0

      iex> PowerCalculator.progress_percent(500, 1)
      50.0

      iex> PowerCalculator.progress_percent(5500, 2)
      50.0

      iex> PowerCalculator.progress_percent(1000000, 6)
      100.0

      # Level drift protection: XP below level threshold returns 0
      iex> PowerCalculator.progress_percent(100, 5)
      0.0
  """
  @spec progress_percent(non_neg_integer(), 1..6) :: float()
  def progress_percent(current_xp, current_level) do
    current_threshold = Map.get(@level_thresholds, current_level, 0)

    case Map.get(@level_thresholds, current_level + 1) do
      nil ->
        # At max level
        100.0

      next_threshold ->
        range = next_threshold - current_threshold
        progress = current_xp - current_threshold

        # Guard against negative progress (level drift from threshold changes)
        if progress < 0 do
          0.0
        else
          Float.round(progress / range * 100, 1)
        end
    end
  end

  @doc """
  Get XP value for an event type.
  """
  @spec xp_for_event(atom()) :: non_neg_integer()
  def xp_for_event(event_type) do
    Map.get(@xp_values, event_type, 1)
  end

  @doc """
  Get level name.
  """
  @spec level_name(1..6) :: String.t()
  def level_name(level), do: Map.get(@level_names, level, "Unknown")

  @doc """
  Get level icon.
  """
  @spec level_icon(1..6) :: String.t()
  def level_icon(level), do: Map.get(@level_icons, level, "🌑")

  @doc """
  Get XP threshold for a level.
  """
  @spec level_threshold(1..6) :: non_neg_integer()
  def level_threshold(level), do: Map.get(@level_thresholds, level, 0)

  @doc """
  Get all level thresholds.
  """
  @spec all_thresholds() :: map()
  def all_thresholds, do: @level_thresholds

  @doc """
  Get all XP values.
  """
  @spec all_xp_values() :: map()
  def all_xp_values, do: @xp_values

  @doc """
  Get capabilities unlocked at a given level.

  Returns cumulative list of all unlocked capabilities up to that level.
  """
  @spec unlocked_capabilities(1..6) :: [String.t()]
  def unlocked_capabilities(level) do
    base = ["memory_search", "memory_store", "ask_mimo"]
    level2 = ["knowledge_query", "knowledge_teach", "graph_traverse"]
    level3 = ["run_procedure", "code_symbols", "diagnostics"]
    level4 = ["multi_replace", "prepare_context", "analyze_file"]
    level5 = ["predictive_context", "auto_consolidation", "cross_project_memory"]
    level6 = ["legendary_wisdom", "infinite_context", "transcendent_insight"]

    cond do
      level >= 6 -> base ++ level2 ++ level3 ++ level4 ++ level5 ++ level6
      level >= 5 -> base ++ level2 ++ level3 ++ level4 ++ level5
      level >= 4 -> base ++ level2 ++ level3 ++ level4
      level >= 3 -> base ++ level2 ++ level3
      level >= 2 -> base ++ level2
      true -> base
    end
  end

  @doc """
  Build a visual progress bar.
  """
  @spec build_progress_bar(non_neg_integer(), 1..6, integer()) :: String.t()
  def build_progress_bar(current_xp, current_level, bar_width \\ 30) do
    case xp_to_next_level(current_xp, current_level) do
      :maxed ->
        bar = String.duplicate("█", bar_width)
        "#{bar} 100% (MAX LEVEL)"

      xp_needed ->
        percent = progress_percent(current_xp, current_level)
        filled = round(percent / 100 * bar_width)
        empty = bar_width - filled

        bar = String.duplicate("█", filled) <> String.duplicate("░", empty)
        "#{bar} #{percent}% (#{xp_needed} XP to Level #{current_level + 1})"
    end
  end
end
