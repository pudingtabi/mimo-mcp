defmodule Mimo.Cognitive.Strategies.Reflexion do
  @moduledoc """
  Reflexion strategy for self-critique and learning from mistakes.

  Implements Actor → Evaluator → Self-Reflection loop:
  - Actor generates trajectory
  - Evaluator scores outcome
  - Self-Reflection generates verbal feedback
  - Memory stores lessons for future

  ## Reference

  Shinn et al. (2023) - "Reflexion: Language Agents with Verbal
  Reinforcement Learning"

  ## Best For

  - Trial-and-error tasks
  - Programming and debugging
  - Tasks where learning from failures helps
  - Iterative improvement scenarios
  """

  alias Mimo.Brain.Memory
  alias Mimo.Cognitive.ThoughtEvaluator
  alias Mimo.TaskHelper

  @type reflection :: %{
          problem: String.t(),
          trajectory_summary: String.t(),
          success: boolean(),
          what_worked: [String.t()],
          what_failed: [String.t()],
          lessons_learned: [String.t()],
          key_insight: String.t(),
          improvements: [String.t()],
          verbal_feedback: String.t()
        }

  @type outcome :: %{
          success: boolean(),
          result: term(),
          error: String.t() | nil,
          steps_taken: non_neg_integer()
        }

  @doc """
  Generate self-reflection on a failed attempt.

  ## Parameters

  - `trajectory` - List of reasoning steps taken
  - `error` - The error or failure that occurred
  - `problem` - The original problem statement
  """
  @spec reflect_on_failure([map()], String.t(), String.t()) :: reflection()
  def reflect_on_failure(trajectory, error, problem) do
    # Analyze trajectory to find where things went wrong
    failure_analysis = analyze_failure(trajectory, error)

    # Identify any partial successes
    partial_successes = identify_partial_successes(trajectory)

    # Generate lessons
    lessons = generate_lessons_from_failure(failure_analysis, error, problem)

    # Generate improvement suggestions
    improvements = suggest_improvements(failure_analysis, trajectory)

    # Generate verbal feedback
    verbal =
      generate_verbal_feedback(
        success: false,
        problem: problem,
        failure_point: failure_analysis.failure_point,
        lessons: lessons
      )

    %{
      problem: problem,
      trajectory_summary: summarize_trajectory(trajectory),
      success: false,
      what_worked: partial_successes,
      what_failed: failure_analysis.failures,
      lessons_learned: lessons,
      key_insight: List.first(lessons) || "Need to investigate further",
      improvements: improvements,
      verbal_feedback: verbal
    }
  end

  @doc """
  Generate self-reflection on a successful attempt.

  ## Parameters

  - `trajectory` - List of reasoning steps taken
  - `result` - The successful result
  - `problem` - The original problem statement
  """
  @spec reflect_on_success([map()], term(), String.t()) :: reflection()
  def reflect_on_success(trajectory, _result, problem) do
    # Analyze what contributed to success
    success_factors = analyze_success(trajectory)

    # Identify key decisions that helped
    _key_decisions = identify_key_decisions(trajectory)

    # Generate lessons from success
    lessons = generate_lessons_from_success(success_factors, trajectory)

    # Generate verbal feedback
    verbal =
      generate_verbal_feedback(
        success: true,
        problem: problem,
        success_factors: success_factors,
        lessons: lessons
      )

    %{
      problem: problem,
      trajectory_summary: summarize_trajectory(trajectory),
      success: true,
      what_worked: success_factors,
      what_failed: [],
      lessons_learned: lessons,
      key_insight: "Successful approach: #{summarize_approach(trajectory)}",
      improvements: ["Consider this approach for similar problems"],
      verbal_feedback: verbal
    }
  end

  @doc """
  Generate verbal reinforcement feedback.

  This is the core of Reflexion - converting analysis into
  natural language feedback that can be used in future attempts.
  """
  @spec generate_verbal_feedback(keyword()) :: String.t()
  def generate_verbal_feedback(opts) do
    success = Keyword.get(opts, :success, false)
    problem = Keyword.get(opts, :problem, "")
    lessons = Keyword.get(opts, :lessons, [])

    if success do
      success_factors = Keyword.get(opts, :success_factors, [])

      """
      In my previous attempt at "#{truncate(problem, 50)}", I succeeded.

      What worked well:
      #{format_list(success_factors)}

      Key lessons:
      #{format_list(lessons)}

      For similar problems, I should follow this successful pattern.
      """
    else
      failure_point = Keyword.get(opts, :failure_point, "unknown")

      """
      In my previous attempt at "#{truncate(problem, 50)}", I failed.

      The failure occurred at: #{failure_point}

      What I learned:
      #{format_list(lessons)}

      For my next attempt, I should:
      - Avoid the mistakes that led to failure
      - Try a different approach if the same method fails again
      - Verify intermediate results before proceeding
      """
    end
  end

  @doc """
  Store reflection in episodic memory for future retrieval.
  """
  @spec store_reflection(reflection(), String.t(), boolean()) :: {:ok, term()} | {:error, term()}
  def store_reflection(reflection, problem, success) do
    # Store asynchronously to avoid blocking
    Mimo.Sandbox.run_async(Mimo.Repo, fn ->
      importance = if success, do: 0.8, else: 0.7

      content = """
      Problem: #{truncate(problem, 100)}
      Outcome: #{if success, do: "Success", else: "Failed"}
      Key insight: #{reflection.key_insight}
      Lessons: #{Enum.join(reflection.lessons_learned, "; ")}
      """

      tags =
        [
          "reflexion",
          if(success, do: "success", else: "failure"),
          extract_problem_type(problem)
        ]
        |> Enum.reject(&is_nil/1)

      Memory.persist_memory(content,
        category: :action,
        importance: importance,
        metadata: %{
          type: "reflexion",
          success: success,
          problem_hash: :erlang.phash2(problem),
          lessons_count: length(reflection.lessons_learned),
          tags: tags
        }
      )
    end)

    {:ok, :stored_async}
  end

  @doc """
  Retrieve past reflections on similar problems.
  """
  @spec retrieve_past_reflections(String.t(), keyword()) :: [map()]
  def retrieve_past_reflections(problem, opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)

    # Search with timeout to avoid blocking
    task =
      TaskHelper.async_with_callers(fn ->
        search_query = "reflexion problem: #{problem}"

        case Memory.search_memories(search_query, limit: limit, min_similarity: 0.3) do
          memories when is_list(memories) ->
            memories
            |> Enum.filter(fn m ->
              meta = m[:metadata] || %{}
              meta[:type] == "reflexion"
            end)
            |> Enum.map(fn m ->
              %{
                content: m.content,
                success: get_in(m, [:metadata, :success]),
                similarity: m[:similarity] || 0.0
              }
            end)

          _ ->
            []
        end
      end)

    case Task.yield(task, 2000) || Task.shutdown(task) do
      {:ok, results} -> results
      _ -> []
    end
  end

  @doc """
  Generate a critique of the current approach.

  Used during reasoning to identify potential issues early.
  """
  @spec critique_approach([map()], String.t()) :: %{issues: [String.t()], suggestions: [String.t()]}
  def critique_approach(trajectory, problem) do
    issues = []
    suggestions = []

    # Check for common anti-patterns
    {issues, suggestions} = check_repetitive_actions(trajectory, issues, suggestions)
    {issues, suggestions} = check_lack_of_progress(trajectory, problem, issues, suggestions)
    {issues, suggestions} = check_ignored_information(trajectory, issues, suggestions)
    {issues, suggestions} = check_overconfidence(trajectory, issues, suggestions)

    %{issues: Enum.reverse(issues), suggestions: Enum.reverse(suggestions)}
  end

  @doc """
  Determine if an approach should be abandoned.
  """
  @spec should_abandon?([map()], String.t(), non_neg_integer()) :: boolean()
  def should_abandon?(trajectory, _problem, max_attempts \\ 3) do
    # Check for repeated failures
    recent_failures =
      trajectory
      |> Enum.take(-5)
      |> Enum.count(fn step ->
        step[:type] == :observation and
          String.match?(step[:content] || "", ~r/error|failed|exception/i)
      end)

    # Check for stuck in loop
    in_loop = detect_loop(trajectory)

    # Check attempt count for same action
    repeated_actions = count_repeated_actions(trajectory)

    recent_failures >= 3 or in_loop or repeated_actions >= max_attempts
  end

  @doc """
  Generate an alternative approach based on reflection.
  """
  @spec suggest_alternative(reflection(), String.t()) :: String.t()
  def suggest_alternative(reflection, _problem) do
    cond do
      # If specific failures identified, address them
      length(reflection.what_failed) > 0 ->
        failed_approach = List.first(reflection.what_failed)

        "Try a different approach. Avoid: #{failed_approach}. #{List.first(reflection.improvements) || "Consider breaking the problem into smaller steps."}"

      # If some things worked, build on them
      length(reflection.what_worked) > 0 ->
        worked = List.first(reflection.what_worked)
        "Build on what worked: #{worked}. Then try a new method for the failing parts."

      # Generic suggestion
      true ->
        "Take a step back and reconsider the problem from scratch. What assumptions might be wrong?"
    end
  end

  # Private analysis functions

  defp analyze_failure(trajectory, error) do
    # Find where things started going wrong
    failure_index = find_failure_point(trajectory, error)

    # Identify specific failures
    failures =
      trajectory
      |> Enum.drop(failure_index)
      |> Enum.filter(fn step ->
        step[:type] == :thought or step[:type] == :action
      end)
      |> Enum.map(fn step ->
        content = step[:content] || ""
        String.slice(content, 0..100)
      end)
      |> Enum.take(3)

    failure_point =
      if failure_index > 0 do
        step = Enum.at(trajectory, failure_index)
        "Step #{failure_index + 1}: #{truncate(step[:content] || "", 50)}"
      else
        "Early in the process"
      end

    %{
      failure_index: failure_index,
      failure_point: failure_point,
      failures: failures,
      total_steps: length(trajectory)
    }
  end

  defp find_failure_point(trajectory, error) do
    # Try to match error to a specific step
    error_lower = String.downcase(error)

    trajectory
    |> Enum.with_index()
    |> Enum.find_value(length(trajectory) - 1, fn {step, idx} ->
      content = String.downcase(step[:content] || "")

      if String.contains?(content, String.slice(error_lower, 0..20)) do
        idx
      end
    end)
  end

  defp identify_partial_successes(trajectory) do
    trajectory
    |> Enum.filter(fn step ->
      content = step[:content] || ""
      String.match?(content, ~r/\b(found|discovered|identified|completed|success)\b/i)
    end)
    |> Enum.map(fn step ->
      truncate(step[:content] || "", 80)
    end)
    |> Enum.take(3)
  end

  defp analyze_success(trajectory) do
    # Identify what contributed to success
    trajectory
    |> Enum.filter(fn step ->
      step[:type] == :thought or step[:type] == :action
    end)
    |> Enum.filter(fn step ->
      # Look for decisive steps
      content = step[:content] || ""
      evaluation = ThoughtEvaluator.evaluate(content, %{})
      evaluation.quality == :good
    end)
    |> Enum.map(fn step ->
      truncate(step[:content] || "", 80)
    end)
    |> Enum.take(5)
  end

  defp identify_key_decisions(trajectory) do
    # Find steps that led to significant progress
    trajectory
    |> Enum.filter(fn step ->
      step[:type] == :thought
    end)
    |> Enum.filter(fn step ->
      content = String.downcase(step[:content] || "")
      String.match?(content, ~r/\b(decided|realized|key insight|important|crucial)\b/)
    end)
  end

  defp generate_lessons_from_failure(analysis, error, _problem) do
    lessons = []

    # Lesson about the specific error
    lessons = ["Error '#{truncate(error, 50)}' indicates: verify this type of operation" | lessons]

    # Lesson about the approach
    lessons =
      if analysis.failure_index < 3 do
        ["Early failure suggests the initial approach may be wrong" | lessons]
      else
        ["Partial progress before failure - focus on the specific failing step" | lessons]
      end

    # General lessons
    lessons = ["Validate intermediate results before proceeding" | lessons]

    Enum.reverse(lessons) |> Enum.take(5)
  end

  defp generate_lessons_from_success(success_factors, trajectory) do
    lessons = []

    # Capture effective patterns
    lessons =
      if length(success_factors) > 0 do
        ["Pattern that worked: #{List.first(success_factors)}" | lessons]
      else
        lessons
      end

    # Note the approach used
    lessons =
      if length(trajectory) > 0 do
        ["Effective approach took #{length(trajectory)} steps" | lessons]
      else
        lessons
      end

    Enum.reverse(lessons)
  end

  defp suggest_improvements(analysis, trajectory) do
    improvements = []

    # Suggest based on failure point
    improvements =
      if analysis.failure_index < 3 do
        ["Start with a different approach" | improvements]
      else
        ["Review steps around the failure point" | improvements]
      end

    # Suggest verification
    improvements = ["Add verification steps before critical operations" | improvements]

    # Suggest breaking down
    improvements =
      if length(trajectory) > 5 do
        ["Consider breaking the problem into smaller parts" | improvements]
      else
        improvements
      end

    Enum.reverse(improvements) |> Enum.take(4)
  end

  defp check_repetitive_actions(trajectory, issues, suggestions) do
    # Check for repeated similar actions
    action_contents =
      trajectory
      |> Enum.filter(&(&1[:type] == :action))
      |> Enum.map(fn a -> truncate(a[:content] || "", 30) end)

    if length(action_contents) != length(Enum.uniq(action_contents)) do
      {["Repeated actions detected - may be stuck in a loop" | issues],
       ["Try a different tool or approach" | suggestions]}
    else
      {issues, suggestions}
    end
  end

  defp check_lack_of_progress(trajectory, _problem, issues, suggestions) do
    recent = Enum.take(trajectory, -5)
    thoughts = Enum.filter(recent, &(&1[:type] == :thought))

    # Check if recent thoughts show progress
    has_progress =
      Enum.any?(thoughts, fn t ->
        content = t[:content] || ""
        String.match?(content, ~r/\b(found|discovered|progress|closer|answer)\b/i)
      end)

    if length(thoughts) >= 3 and not has_progress do
      {["Recent reasoning shows no clear progress" | issues],
       ["Step back and reconsider the approach" | suggestions]}
    else
      {issues, suggestions}
    end
  end

  defp check_ignored_information(trajectory, issues, suggestions) do
    # Check if observations are being used
    observations = Enum.filter(trajectory, &(&1[:type] == :observation))
    thoughts_after = Enum.filter(trajectory, &(&1[:type] == :thought))

    if length(observations) > 2 and length(thoughts_after) > 0 do
      last_obs = List.last(observations)
      obs_content = last_obs[:content] || ""

      # Check if any thought references the observation
      referenced =
        Enum.any?(thoughts_after, fn t ->
          thought_content = t[:content] || ""
          # Simple check: shared significant words
          obs_words = extract_words(obs_content)
          thought_words = extract_words(thought_content)
          MapSet.intersection(obs_words, thought_words) |> MapSet.size() > 2
        end)

      if referenced do
        {issues, suggestions}
      else
        {["Recent observations may not be fully utilized" | issues],
         ["Review and incorporate information from tool outputs" | suggestions]}
      end
    else
      {issues, suggestions}
    end
  end

  defp check_overconfidence(trajectory, issues, suggestions) do
    # Check for premature conclusions
    thoughts = Enum.filter(trajectory, &(&1[:type] == :thought))

    early_conclusion =
      thoughts
      |> Enum.take(3)
      |> Enum.any?(fn t ->
        content = t[:content] || ""
        String.match?(content, ~r/\b(definitely|certainly|obviously|must be|the answer is)\b/i)
      end)

    if early_conclusion do
      {["May be reaching conclusions too quickly" | issues],
       ["Gather more evidence before concluding" | suggestions]}
    else
      {issues, suggestions}
    end
  end

  defp detect_loop(trajectory) do
    # Check if last 4 steps repeat a pattern
    if length(trajectory) < 6 do
      false
    else
      recent = trajectory |> Enum.take(-6) |> Enum.map(&(&1[:content] || ""))
      first_half = Enum.take(recent, 3) |> Enum.join("")
      second_half = Enum.drop(recent, 3) |> Enum.join("")

      similarity = calculate_similarity(first_half, second_half)
      similarity > 0.8
    end
  end

  defp count_repeated_actions(trajectory) do
    trajectory
    |> Enum.filter(&(&1[:type] == :action))
    |> Enum.group_by(fn a -> {a[:tool], a[:tool_args]} end)
    |> Enum.map(fn {_key, group} -> length(group) end)
    |> Enum.max(fn -> 0 end)
  end

  defp summarize_trajectory(trajectory) do
    step_count = length(trajectory)
    thoughts = Enum.count(trajectory, &(&1[:type] == :thought))
    actions = Enum.count(trajectory, &(&1[:type] == :action))

    "#{step_count} steps (#{thoughts} thoughts, #{actions} actions)"
  end

  defp summarize_approach(trajectory) do
    trajectory
    |> Enum.filter(&(&1[:type] == :thought))
    |> Enum.take(2)
    |> Enum.map_join(" → ", fn t -> truncate(t[:content] || "", 40) end)
  end

  defp extract_problem_type(problem) do
    problem_lower = String.downcase(problem)

    cond do
      String.match?(problem_lower, ~r/\b(debug|fix|error|bug)\b/) -> "debugging"
      String.match?(problem_lower, ~r/\b(implement|write|create|build)\b/) -> "implementation"
      String.match?(problem_lower, ~r/\b(explain|how|what|why)\b/) -> "explanation"
      String.match?(problem_lower, ~r/\b(design|architect|plan)\b/) -> "design"
      true -> "general"
    end
  end

  defp extract_words(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, "")
    |> String.split()
    |> Enum.reject(&(String.length(&1) < 4))
    |> MapSet.new()
  end

  defp calculate_similarity(text1, text2) do
    words1 = extract_words(text1)
    words2 = extract_words(text2)

    if MapSet.size(words1) == 0 or MapSet.size(words2) == 0 do
      0.0
    else
      intersection = MapSet.intersection(words1, words2) |> MapSet.size()
      union = MapSet.union(words1, words2) |> MapSet.size()
      intersection / union
    end
  end

  defp truncate(text, max_length) do
    if String.length(text) > max_length do
      String.slice(text, 0, max_length - 3) <> "..."
    else
      text
    end
  end

  defp format_list(items) when is_list(items) do
    items
    |> Enum.take(5)
    |> Enum.map_join("\n", fn item -> "- #{item}" end)
  end

  defp format_list(_), do: "- (none)"
end
