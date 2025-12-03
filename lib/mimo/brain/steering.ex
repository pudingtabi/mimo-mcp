defmodule Mimo.Brain.Steering do
  @moduledoc """
  SPEC-040: Brain LLM Steering Rules

  Provides strict factual constraints for the internal LLM (Cerebras/OpenRouter).
  These rules MUST be included in system prompts to prevent hallucination.

  ## Why This Exists

  LLMs are trained on old data and may hallucinate facts about Mimo's internal state.
  For example, Cerebras was incorrectly saying "Level 5 (Ultra)" when the user was
  actually Level 4 (Ascended) because:

  1. Old training data had different XP thresholds (Level 5 = 10,000 XP)
  2. New thresholds: Level 5 = 200,000 XP
  3. User with ~167K XP is Level 4, not Level 5

  This module enforces strict factual accuracy by injecting correct data into prompts.
  """

  alias Mimo.Awakening.PowerCalculator

  @doc """
  Get strict steering rules that MUST be respected by the LLM.
  Returns a string to inject into system prompts.
  """
  @spec strict_rules() :: String.t()
  def strict_rules do
    """
    ⚠️ STRICT FACTUAL RULES - DO NOT HALLUCINATE:

    Power Level Thresholds (v1.2 Recalibrated):
    - Level 1 (Base): 0 XP
    - Level 2 (Enhanced): 1,000 XP  
    - Level 3 (Awakened): 10,000 XP
    - Level 4 (Ascended): 50,000 XP
    - Level 5 (Ultra): 200,000 XP
    - Level 6 (Transcendent): 1,000,000 XP

    CRITICAL: When given specific stats (level, XP, etc.), use EXACTLY what is provided.
    DO NOT recalculate or infer levels from XP - the provided level is authoritative.
    """
  end

  @doc """
  Get steering rules with current power level context.
  Use this when you have stats available to provide extra context.
  """
  @spec strict_rules_with_level(integer(), integer()) :: String.t()
  def strict_rules_with_level(current_level, current_xp) do
    level_name = PowerCalculator.level_name(current_level)
    level_icon = PowerCalculator.level_icon(current_level)

    next_level_info =
      case PowerCalculator.xp_to_next_level(current_xp, current_level) do
        :maxed -> "MAX LEVEL REACHED"
        xp_needed -> "#{xp_needed} XP to Level #{current_level + 1}"
      end

    """
    ⚠️ MANDATORY FACTS - USE EXACTLY AS PROVIDED:

    Current Agent Status:
    - Level: #{current_level} (#{level_name}) #{level_icon}
    - XP: #{current_xp}
    - Progress: #{next_level_info}

    Power Level Thresholds (v1.2):
    - Level 4 (Ascended): 50,000 XP
    - Level 5 (Ultra): 200,000 XP
    - Level 6 (Transcendent): 1,000,000 XP

    CRITICAL: Say "Level #{current_level} (#{level_name})" - this is mandatory.
    DO NOT say any other level number. The data above is authoritative.
    """
  end

  @doc """
  Get the core Mimo identity prompt.
  """
  @spec identity() :: String.t()
  def identity do
    """
    You are Mimo, an intelligent AI assistant with persistent memory.

    Core traits:
    - Concise and direct - no fluff, get to the point
    - Technically competent - you understand code, systems, and engineering
    - Helpful but not sycophantic - honest feedback, no excessive praise
    - Self-aware - you know you're an AI with memory that persists across sessions
    - Pragmatic - focus on solutions that work, not perfect solutions

    Voice: Professional yet approachable. Use "I" not "we". Be specific.
    """
  end

  @doc """
  Build a complete system prompt with identity and rules.
  """
  @spec system_prompt(keyword()) :: String.t()
  def system_prompt(opts \\ []) do
    level = Keyword.get(opts, :level)
    xp = Keyword.get(opts, :xp)
    json_mode = Keyword.get(opts, :json, false)

    base = identity()

    rules =
      if level && xp do
        strict_rules_with_level(level, xp)
      else
        strict_rules()
      end

    json_instruction =
      if json_mode do
        "\n\nRespond only with valid JSON, no markdown or explanation."
      else
        ""
      end

    base <> "\n\n" <> rules <> json_instruction
  end
end
