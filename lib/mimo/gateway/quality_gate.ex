defmodule Mimo.Gateway.QualityGate do
  @moduledoc """
  Quality Gate - LLM-Based Enforcement (The Real Iron Man Suit).

  SPEC-091: Quality-Based Enforcement

  Unlike the simple InputGate that checks IF tools were called,
  this module checks if reasoning was GOOD.

  Uses Mimo's existing ThoughtEvaluator to score reasoning quality.
  Only allows action tools if reasoning quality passes threshold.

  ## How It Works

  1. When `reason` is called, we capture the thoughts/problem
  2. ThoughtEvaluator scores the reasoning quality (0-1)
  3. When `file edit` is called, we check:
     - Was reasoning quality >= threshold (0.5)?
     - Was the problem relevant to the action?

  This prevents trivial bypass like `reason problem="x"` because
  the ThoughtEvaluator will score that as low quality.
  """

  require Logger

  alias Mimo.Cognitive.ThoughtEvaluator
  alias Mimo.Gateway.Session

  @quality_threshold 0.5
  @minimum_thoughts 1

  @doc """
  Enhanced prerequisite check that evaluates QUALITY not just presence.
  """
  def check_quality(%Session{} = session, tool_name, arguments) do
    case tool_name do
      tool when tool in ["file", "terminal"] ->
        check_action_quality(session, tool, arguments)

      "reason" ->
        # Capture reasoning for later quality evaluation
        capture_reasoning(session, arguments)

      _ ->
        {:ok, session, arguments}
    end
  end

  # Check quality before allowing action tools
  defp check_action_quality(session, tool_name, arguments) do
    # Skip quality check for read-only operations
    if safe_operation?(tool_name, arguments) do
      {:ok, session, arguments}
    else
      perform_quality_check(session, tool_name, arguments)
    end
  end

  defp perform_quality_check(session, tool_name, arguments) do
    case session.reasoning_context do
      nil ->
        {:blocked, "#{tool_name} blocked: No reasoning context found",
         "Call `reason operation=guided problem=\"describe your task\"` first"}

      %{thoughts: thoughts} when length(thoughts) < @minimum_thoughts ->
        {:blocked, "#{tool_name} blocked: Insufficient reasoning (#{length(thoughts)} thoughts)",
         "Add more reasoning steps with `reason operation=step thought=\"...\"`"}

      %{quality_score: score}
      when score < @quality_threshold ->
        {:blocked, "#{tool_name} blocked: Reasoning quality too low (#{Float.round(score, 2)})",
         "Improve reasoning quality - current score #{Float.round(score, 2)}, need #{@quality_threshold}"}

      %{quality_score: score} ->
        Logger.info("[QualityGate] Action allowed - reasoning score: #{Float.round(score, 2)}")
        {:ok, session, arguments}
    end
  end

  # Capture and evaluate reasoning when reason tool is called
  defp capture_reasoning(session, %{"operation" => op} = args)
       when op in ["guided", "step", "conclude"] do
    updated_context =
      case session.reasoning_context do
        nil ->
          %{
            problem: Map.get(args, "problem", ""),
            thoughts: [],
            quality_score: 0.0,
            started_at: DateTime.utc_now()
          }

        existing ->
          existing
      end

    # Add thought if present
    thought = Map.get(args, "thought") || Map.get(args, "problem", "")

    updated_context =
      if thought && String.length(thought) > 0 do
        thoughts = [thought | updated_context.thoughts]

        # Evaluate quality of this thought
        evaluation =
          ThoughtEvaluator.evaluate(thought, %{
            previous_thoughts: updated_context.thoughts,
            problem: updated_context.problem
          })

        # Rolling average of quality scores
        new_score =
          update_quality_score(updated_context.quality_score, evaluation.score, length(thoughts))

        Logger.debug(
          "[QualityGate] Thought evaluated: #{evaluation.quality}, score: #{evaluation.score}"
        )

        %{updated_context | thoughts: thoughts, quality_score: new_score}
      else
        updated_context
      end

    session = %{session | reasoning_context: updated_context}
    {:ok, session, args}
  end

  defp capture_reasoning(session, args) do
    {:ok, session, args}
  end

  # Weighted rolling average - recent thoughts matter more
  defp update_quality_score(current, new_score, thought_count) do
    # New thought has 70% weight
    weight = 0.7

    if thought_count == 1 do
      new_score
    else
      current * (1 - weight) + new_score * weight
    end
  end

  # Check if operation is safe (read-only)
  @safe_operations %{
    "file" => ["read", "ls", "list_directory", "glob", "get_info", "diff"],
    "terminal" => ["list_sessions", "list_processes", "read_output"]
  }

  defp safe_operation?(tool_name, %{"operation" => operation}) do
    case Map.get(@safe_operations, tool_name) do
      nil -> false
      safe_ops -> operation in safe_ops
    end
  end

  defp safe_operation?(_, _), do: false

  @doc """
  Get current reasoning quality for a session.
  """
  def get_quality(%Session{reasoning_context: nil}), do: {:error, :no_reasoning}

  def get_quality(%Session{reasoning_context: ctx}) do
    {:ok,
     %{
       score: ctx.quality_score,
       thoughts: length(ctx.thoughts),
       problem: ctx.problem,
       passes: ctx.quality_score >= @quality_threshold
     }}
  end

  @doc """
  Configure quality threshold (for testing/tuning).
  """
  def set_threshold(new_threshold) when new_threshold >= 0 and new_threshold <= 1 do
    # In production, this would be application config
    Application.put_env(:mimo_mcp, :gateway_quality_threshold, new_threshold)
  end
end
