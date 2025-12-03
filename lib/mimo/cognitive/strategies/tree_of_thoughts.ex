defmodule Mimo.Cognitive.Strategies.TreeOfThoughts do
  @moduledoc """
  Tree-of-Thoughts (ToT) reasoning strategy.

  Enables exploration of multiple reasoning paths with:
  - Branch creation and evaluation
  - BFS/DFS search algorithms
  - Backtracking when paths fail

  ## Reference

  Yao et al. (2023) - "Tree of Thoughts: Deliberate Problem Solving
  with Large Language Models"

  ## Best For

  - Problems with multiple valid approaches
  - Design decisions
  - Ambiguous problems requiring exploration
  - Situations where the first approach may fail
  """

  alias Mimo.Cognitive.{ReasoningSession, ThoughtEvaluator}

  @type branch :: ReasoningSession.branch()
  @type thought :: ReasoningSession.thought()

  @type branch_candidate :: %{
          thought: String.t(),
          rationale: String.t(),
          estimated_promise: :high | :medium | :low
        }

  @type branch_evaluation :: %{
          evaluation: :promising | :uncertain | :dead_end,
          confidence: float(),
          issues: [String.t()],
          continue: boolean()
        }

  @type search_strategy :: :bfs | :dfs | :best_first

  # Maximum branches to explore before forcing a conclusion
  @max_branches 5
  # Maximum depth per branch
  @max_branch_depth 7

  @doc """
  Generate candidate branches for exploration.

  ## Parameters

  - `current_state` - Current thought content or problem context
  - `problem` - The original problem
  - `opts` - Options:
    - `:num_branches` - Number of branches to generate (default: 3)
    - `:existing_branches` - Branches already explored (to avoid duplication)
  """
  @spec generate_branches(String.t(), String.t(), keyword()) :: [branch_candidate()]
  def generate_branches(current_state, problem, opts \\ []) do
    num_branches = Keyword.get(opts, :num_branches, 3)
    existing = Keyword.get(opts, :existing_branches, [])

    # Analyze problem to generate appropriate branches
    candidates = generate_approach_candidates(current_state, problem)

    # Filter out approaches similar to existing branches
    candidates
    |> Enum.reject(fn candidate ->
      Enum.any?(existing, fn branch ->
        similar_branch?(candidate, branch)
      end)
    end)
    |> Enum.take(num_branches)
  end

  @doc """
  Evaluate a branch's promise.

  Uses "sure/maybe/impossible" evaluation similar to the original ToT paper.
  """
  @spec evaluate_branch([String.t()], String.t()) :: branch_evaluation()
  def evaluate_branch(branch_thoughts, problem) do
    if branch_thoughts == [] do
      %{
        evaluation: :uncertain,
        confidence: 0.5,
        issues: ["Branch has no thoughts yet"],
        continue: true
      }
    else
      # Evaluate each thought in the branch
      evaluations =
        Enum.map(branch_thoughts, fn thought ->
          ThoughtEvaluator.evaluate(thought, %{
            previous_thoughts: [],
            problem: problem,
            strategy: :tot
          })
        end)

      # Calculate overall branch quality
      avg_score = evaluations |> Enum.map(& &1.score) |> Enum.sum() |> Kernel./(length(evaluations))
      all_issues = evaluations |> Enum.flat_map(& &1.issues) |> Enum.uniq()

      # Check for dead-end indicators
      is_dead_end = detect_dead_end(branch_thoughts, problem)

      # Check for promising signs
      is_promising = detect_promise(branch_thoughts, problem)

      {evaluation, continue} =
        cond do
          is_dead_end -> {:dead_end, false}
          avg_score < 0.3 -> {:dead_end, false}
          is_promising and avg_score >= 0.6 -> {:promising, true}
          avg_score >= 0.5 -> {:uncertain, true}
          true -> {:uncertain, length(branch_thoughts) < @max_branch_depth}
        end

      %{
        evaluation: evaluation,
        confidence: Float.round(avg_score, 3),
        issues: all_issues,
        continue: continue
      }
    end
  end

  @doc """
  Select the next branch to explore.

  ## Search Strategies

  - `:bfs` - Breadth-first: explore all branches at same depth before going deeper
  - `:dfs` - Depth-first: explore one branch fully before backtracking
  - `:best_first` - Always explore the most promising branch next
  """
  @spec select_next_branch([branch()], search_strategy()) :: branch() | nil
  def select_next_branch(branches, strategy \\ :best_first) do
    unexplored =
      Enum.filter(branches, fn b ->
        not b.explored and b.evaluation != :dead_end
      end)

    if unexplored == [] do
      nil
    else
      case strategy do
        :bfs ->
          # Select branch with fewest thoughts (shallowest)
          Enum.min_by(unexplored, fn b -> length(b.thoughts) end)

        :dfs ->
          # Select most recently created unexplored branch
          List.last(unexplored)

        :best_first ->
          # Select by evaluation, then by thought count (prefer more progress)
          Enum.sort_by(unexplored, fn b ->
            priority =
              case b.evaluation do
                :promising -> 0
                :uncertain -> 1
                _ -> 2
              end

            {priority, -length(b.thoughts)}
          end)
          |> List.first()
      end
    end
  end

  @doc """
  Mark a branch as a dead end.
  """
  @spec mark_dead_end(branch()) :: branch()
  def mark_dead_end(branch) do
    %{branch | evaluation: :dead_end, explored: true}
  end

  @doc """
  Find the best path through explored branches.
  """
  @spec find_best_path([branch()]) :: {:ok, branch()} | {:error, :no_viable_path}
  def find_best_path(branches) do
    # Filter to branches with some progress
    viable =
      Enum.filter(branches, fn b ->
        length(b.thoughts) > 0 and b.evaluation != :dead_end
      end)

    if viable == [] do
      {:error, :no_viable_path}
    else
      # Score each branch
      scored =
        Enum.map(viable, fn branch ->
          score = calculate_branch_score(branch)
          {branch, score}
        end)

      {best_branch, _score} = Enum.max_by(scored, fn {_b, s} -> s end)
      {:ok, best_branch}
    end
  end

  @doc """
  Check if maximum exploration has been reached.
  """
  @spec should_force_conclusion?([branch()]) :: boolean()
  def should_force_conclusion?(branches) do
    explored_count = Enum.count(branches, & &1.explored)
    dead_ends = Enum.count(branches, &(&1.evaluation == :dead_end))

    # Force conclusion if:
    # - All branches explored
    # - Too many dead ends
    # - Maximum branch count reached
    all_explored = explored_count == length(branches)
    too_many_dead_ends = dead_ends >= length(branches) - 1
    max_reached = length(branches) >= @max_branches

    all_explored or too_many_dead_ends or max_reached
  end

  @doc """
  Generate a summary of the exploration.
  """
  @spec summarize_exploration([branch()]) :: map()
  def summarize_exploration(branches) do
    %{
      total_branches: length(branches),
      explored: Enum.count(branches, & &1.explored),
      promising: Enum.count(branches, &(&1.evaluation == :promising)),
      uncertain: Enum.count(branches, &(&1.evaluation == :uncertain)),
      dead_ends: Enum.count(branches, &(&1.evaluation == :dead_end)),
      total_thoughts: branches |> Enum.flat_map(& &1.thoughts) |> length(),
      best_branch: find_best_path(branches) |> elem(1)
    }
  end

  @doc """
  Calculate the depth of a branch in the tree.
  """
  @spec calculate_depth(branch(), [branch()]) :: non_neg_integer()
  def calculate_depth(branch, all_branches) do
    count_ancestors(branch.parent_id, all_branches, 0)
  end

  # Private helpers

  defp generate_approach_candidates(_current_state, problem) do
    problem_lower = String.downcase(problem)

    base_candidates = [
      %{
        thought: "Direct approach: tackle the problem head-on",
        rationale: "Start with the most straightforward solution",
        estimated_promise: :medium
      },
      %{
        thought: "Simplify first: reduce the problem to its essence",
        rationale: "Removing complexity may reveal a clearer solution",
        estimated_promise: :medium
      },
      %{
        thought: "Analogous problem: find a similar solved problem",
        rationale: "Leverage existing solutions and patterns",
        estimated_promise: :medium
      }
    ]

    # Add domain-specific candidates
    additional =
      cond do
        String.contains?(problem_lower, ["design", "architect", "build"]) ->
          [
            %{
              thought: "Top-down design: start with high-level structure",
              rationale: "Define the big picture before details",
              estimated_promise: :high
            },
            %{
              thought: "Bottom-up construction: build small components first",
              rationale: "Solid foundations enable reliable systems",
              estimated_promise: :medium
            }
          ]

        String.contains?(problem_lower, ["choose", "decide", "select", "compare"]) ->
          [
            %{
              thought: "Weighted criteria: score each option systematically",
              rationale: "Objective comparison reduces bias",
              estimated_promise: :high
            },
            %{
              thought: "Elimination: rule out clearly inferior options first",
              rationale: "Narrowing the field simplifies the final decision",
              estimated_promise: :medium
            }
          ]

        String.contains?(problem_lower, ["debug", "fix", "error", "bug"]) ->
          [
            %{
              thought: "Binary search: narrow down the problem location",
              rationale: "Divide and conquer finds issues faster",
              estimated_promise: :high
            },
            %{
              thought: "Trace execution: follow the code path step by step",
              rationale: "Understanding flow reveals where things go wrong",
              estimated_promise: :medium
            }
          ]

        true ->
          []
      end

    base_candidates ++ additional
  end

  defp similar_branch?(candidate, branch) do
    # Simple similarity check based on key words
    candidate_words = extract_key_words(candidate.thought)

    branch_words =
      branch.thoughts
      |> Enum.take(1)
      |> Enum.flat_map(&extract_key_words/1)

    overlap =
      MapSet.intersection(
        MapSet.new(candidate_words),
        MapSet.new(branch_words)
      )
      |> MapSet.size()

    overlap >= 2
  end

  defp extract_key_words(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, "")
    |> String.split()
    |> Enum.reject(&(String.length(&1) < 4))
  end

  defp detect_dead_end(thoughts, _problem) do
    if thoughts == [] do
      false
    else
      last = List.last(thoughts) |> String.downcase()

      # Dead end indicators
      dead_end_patterns = [
        ~r/\b(impossible|cannot|won't work|dead end|doesn't work|failed|stuck)\b/i,
        ~r/\b(this approach|this path|this method)\s+(is|seems|appears)\s+(wrong|incorrect|flawed)\b/i,
        ~r/\b(abandon|give up|try different|go back)\b/i
      ]

      Enum.any?(dead_end_patterns, &String.match?(last, &1))
    end
  end

  defp detect_promise(thoughts, _problem) do
    if thoughts == [] do
      false
    else
      last = List.last(thoughts) |> String.downcase()

      # Promise indicators
      promise_patterns = [
        ~r/\b(promising|working|progress|getting closer|on track)\b/i,
        ~r/\b(found|discovered|identified|realized)\b.*\b(solution|answer|approach)\b/i,
        ~r/\b(this (works|helps|solves))\b/i
      ]

      Enum.any?(promise_patterns, &String.match?(last, &1))
    end
  end

  defp calculate_branch_score(branch) do
    base_score =
      case branch.evaluation do
        :promising -> 0.8
        :uncertain -> 0.5
        :dead_end -> 0.1
      end

    # Bonus for progress (more thoughts = more explored)
    progress_bonus = min(length(branch.thoughts) * 0.05, 0.2)

    base_score + progress_bonus
  end

  defp count_ancestors(nil, _branches, depth), do: depth

  defp count_ancestors(parent_id, branches, depth) do
    case Enum.find(branches, &(&1.id == parent_id)) do
      nil -> depth
      parent -> count_ancestors(parent.parent_id, branches, depth + 1)
    end
  end
end
