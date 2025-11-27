defmodule Mimo.Skills.Cognition do
  @moduledoc """
  Cognitive functions for LLM reasoning (Think/Plan).
  Currently acts as a structured logger for Chain-of-Thought.
  """
  require Logger

  def think(thought) do
    Logger.info("[THINK] #{thought}")
    {:ok, "Thought recorded."}
  end

  def plan(steps) do
    Logger.info("[PLAN] Steps: #{inspect(steps)}")
    {:ok, "Plan recorded."}
  end
end
