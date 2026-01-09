defmodule Mimo.Autonomous.GoalDecomposer do
  @moduledoc """
  Autonomous goal decomposition for complex tasks.

  Part of Phase 3: Emergent Capabilities - Autonomous Goal Decomposition.

  When a complex task is queued, this module:
  1. Analyzes the task description for complexity
  2. If complex, decomposes it into actionable sub-tasks
  3. Determines dependencies between sub-tasks
  4. Returns a task graph ready for ordered execution

  ## Integration

  Called automatically by TaskRunner.queue_task/1 when enabled.
  Decomposition only happens for tasks with complexity >= :moderate.

  ## Example

      GoalDecomposer.maybe_decompose(%{
        description: "Implement user authentication with OAuth2 and JWT"
      })
      # => {:decomposed, [sub_task1, sub_task2, ...], dependencies}

      GoalDecomposer.maybe_decompose(%{
        description: "Run tests"
      })
      # => {:simple, original_task}
  """

  require Logger

  alias Mimo.Brain.Memory
  alias Mimo.Cognitive.ProblemAnalyzer

  # Maximum sub-tasks to generate (prevent runaway decomposition)
  @max_sub_tasks 10

  @type task_spec :: map()
  @type sub_task :: %{
          id: String.t(),
          description: String.t(),
          type: String.t(),
          parent_id: String.t() | nil,
          depends_on: [String.t()]
        }
  @type decomposition_result ::
          {:simple, task_spec()}
          | {:decomposed, [sub_task()], %{String.t() => [String.t()]}}

  @doc """
  Analyze a task and decompose if complex enough.

  Returns:
  - `{:simple, task}` if task is simple enough to execute directly
  - `{:decomposed, sub_tasks, dependencies}` if task was decomposed

  ## Options

  - `:force` - Force decomposition regardless of complexity (default: false)
  - `:max_depth` - Maximum decomposition depth (default: 1)
  """
  @spec maybe_decompose(task_spec(), keyword()) :: decomposition_result()
  def maybe_decompose(task_spec, opts \\ []) do
    description = Map.get(task_spec, "description") || Map.get(task_spec, :description, "")
    force = Keyword.get(opts, :force, false)

    # Use our own task complexity detection (more suited for goal decomposition)
    should_decompose = force or task_is_complex?(description)

    if should_decompose do
      decompose_task(task_spec, description, :complex)
    else
      Logger.debug("[GoalDecomposer] Task is simple, no decomposition needed")
      {:simple, task_spec}
    end
  end

  # Detect if a task description suggests a complex multi-step goal
  defp task_is_complex?(description) when is_binary(description) do
    desc_lower = String.downcase(description)
    word_count = length(String.split(description))

    # Indicators of multi-component tasks
    multi_component_indicators = [
      # Conjunctions listing multiple things
      String.contains?(desc_lower, [" and ", ", and ", " with ", " plus "]),
      # Multiple comma-separated items
      String.split(description, ",") |> length() >= 3,
      # Multiple action verbs
      count_action_verbs(desc_lower) >= 2,
      # Long descriptions (likely complex)
      word_count >= 15,
      # Contains multiple feature keywords
      count_feature_keywords(desc_lower) >= 3,
      # System-level tasks
      String.contains?(desc_lower, ["system", "architecture", "infrastructure", "pipeline"]),
      # Multi-step keywords
      String.contains?(desc_lower, ["full", "complete", "comprehensive", "entire"])
    ]

    # Complex if 2+ indicators are true
    Enum.count(multi_component_indicators, & &1) >= 2
  end

  defp task_is_complex?(_), do: false

  defp count_action_verbs(text) do
    action_verbs =
      ~w(implement create build add develop design setup configure deploy test integrate refactor migrate)

    Enum.count(action_verbs, &String.contains?(text, &1))
  end

  defp count_feature_keywords(text) do
    feature_keywords =
      ~w(authentication authorization oauth jwt token session password api database cache logging monitoring notification email)

    Enum.count(feature_keywords, &String.contains?(text, &1))
  end

  @doc """
  Check if a task should be decomposed based on its description.
  """
  @spec should_decompose?(String.t()) :: boolean()
  def should_decompose?(description) when is_binary(description) do
    task_is_complex?(description)
  end

  def should_decompose?(_), do: false

  @doc """
  Get statistics about decomposition activity.
  """
  @spec stats() :: map()
  def stats do
    # Query memory for decomposition history
    case Memory.search("goal decomposition", limit: 50, category: :action) do
      {:ok, results} ->
        %{
          total_decompositions: length(results),
          recent_decompositions: Enum.take(results, 5)
        }

      _ ->
        %{total_decompositions: 0, recent_decompositions: []}
    end
  end

  defp decompose_task(task_spec, description, complexity) do
    Logger.info(
      "[GoalDecomposer] Decomposing #{complexity} task: #{String.slice(description, 0, 50)}..."
    )

    # Get sub-problems from ProblemAnalyzer
    sub_problems = ProblemAnalyzer.decompose(description)

    # Search for similar past decompositions
    hints = search_decomposition_hints(description)

    # Build sub-tasks with IDs and dependencies
    parent_id = generate_id()

    sub_tasks =
      sub_problems
      |> Enum.take(@max_sub_tasks)
      |> Enum.with_index()
      |> Enum.map(fn {sub_problem, index} ->
        build_sub_task(sub_problem, index, parent_id, task_spec, hints)
      end)

    # Detect dependencies between sub-tasks
    dependencies = detect_dependencies(sub_tasks)

    # Store decomposition in memory for learning
    store_decomposition(description, sub_tasks, complexity)

    Logger.info("[GoalDecomposer] Decomposed into #{length(sub_tasks)} sub-tasks")

    {:decomposed, sub_tasks, dependencies}
  end

  defp build_sub_task(sub_problem, index, parent_id, original_task, _hints) do
    sub_id = "#{parent_id}_#{index}"
    original_type = Map.get(original_task, "type") || Map.get(original_task, :type, "general")

    %{
      id: sub_id,
      description: sub_problem,
      type: infer_sub_task_type(sub_problem, original_type),
      parent_id: parent_id,
      depends_on: infer_initial_dependencies(index),
      sequence: index,
      generated_from: :goal_decomposer
    }
  end

  defp infer_sub_task_type(description, parent_type) do
    description_lower = String.downcase(description)

    cond do
      String.contains?(description_lower, ["test", "verify", "check", "validate"]) ->
        "test"

      String.contains?(description_lower, ["build", "compile", "bundle"]) ->
        "build"

      String.contains?(description_lower, ["deploy", "release", "publish"]) ->
        "deploy"

      String.contains?(description_lower, ["research", "analyze", "investigate"]) ->
        "research"

      String.contains?(description_lower, ["implement", "create", "add", "write"]) ->
        "implement"

      String.contains?(description_lower, ["fix", "debug", "resolve"]) ->
        "fix"

      true ->
        parent_type
    end
  end

  # Initially, each task depends on the previous one (sequential)
  # This can be refined by detect_dependencies
  defp infer_initial_dependencies(0), do: []
  defp infer_initial_dependencies(_index), do: [:previous]

  defp detect_dependencies(sub_tasks) do
    # Builds dependency map with sequential dependencies and parallelization hints.

    sub_tasks
    |> Enum.reduce(%{}, fn task, deps ->
      task_id = task.id

      # Analyze which other tasks this one might depend on
      dependent_ids =
        sub_tasks
        |> Enum.filter(fn other ->
          other.sequence < task.sequence and
            tasks_related?(other, task)
        end)
        |> Enum.map(& &1.id)

      # If no explicit dependencies found, depend on immediate predecessor
      final_deps =
        if dependent_ids == [] and task.sequence > 0 do
          prev_task = Enum.find(sub_tasks, &(&1.sequence == task.sequence - 1))
          if prev_task, do: [prev_task.id], else: []
        else
          dependent_ids
        end

      Map.put(deps, task_id, final_deps)
    end)
  end

  defp tasks_related?(task1, task2) do
    # Check if task2 might depend on task1 based on content
    desc1 = String.downcase(task1.description)
    desc2 = String.downcase(task2.description)

    # Extract key concepts from task1
    concepts = extract_concepts(desc1)

    # Check if any concept from task1 appears in task2
    Enum.any?(concepts, fn concept ->
      String.contains?(desc2, concept)
    end)
  end

  defp extract_concepts(description) do
    # Extract meaningful words (nouns, verbs) from description
    description
    |> String.split(~r/\s+/)
    |> Enum.filter(fn word ->
      String.length(word) > 3 and
        not String.match?(word, ~r/^(the|and|for|with|from|that|this|will|should|must|have|been)$/)
    end)
    |> Enum.take(5)
  end

  defp search_decomposition_hints(description) do
    # Search memory for similar past decompositions (with timeout to prevent blocking)
    task =
      Task.async(fn ->
        try do
          case Memory.search("decompose #{description}", limit: 3, category: :action) do
            {:ok, results} -> results
            _ -> []
          end
        rescue
          _ -> []
        end
      end)

    case Task.yield(task, 2000) || Task.shutdown(task) do
      {:ok, results} -> results
      _ -> []
    end
  end

  defp store_decomposition(description, sub_tasks, complexity) do
    # Store the decomposition in memory for future learning
    spawn(fn ->
      try do
        content = """
        Goal decomposition (#{complexity}): "#{String.slice(description, 0, 100)}..."
        Decomposed into #{length(sub_tasks)} sub-tasks:
        #{Enum.map_join(sub_tasks, "\n", fn t -> "- #{t.description}" end)}
        """

        Memory.store(%{content: content, category: :action, importance: 0.7})
      rescue
        _ -> :ok
      end
    end)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
