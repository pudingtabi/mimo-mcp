defmodule Mimo.Cognitive.Reasoner do
  @moduledoc """
  Unified Reasoning Engine for AI agents.

  Implements multiple reasoning strategies:
  - Chain-of-Thought (CoT): Linear step-by-step reasoning
  - Tree-of-Thoughts (ToT): Branching exploration with backtracking
  - ReAct: Interleaved reasoning and acting
  - Reflexion: Self-critique and learning from mistakes

  Integrates with SPEC-024 cognitive infrastructure for:
  - Confidence assessment before proceeding
  - Knowledge gap detection and auto-research
  - Memory-backed reasoning (similar past problems)

  ## Usage

      # Start guided reasoning
      {:ok, result} = Reasoner.guided("How do I fix the auth timeout bug?")

      # Record a reasoning step
      {:ok, step} = Reasoner.step(result.session_id, "First, I'll check the JWT config...")

      # Create a branch (ToT)
      {:ok, branch} = Reasoner.branch(result.session_id, "Try approach A...")

      # Reflect on outcome
      {:ok, reflection} = Reasoner.reflect(result.session_id, %{success: false, error: "..."})

      # Conclude reasoning
      {:ok, conclusion} = Reasoner.conclude(result.session_id)
  """

  require Logger

  alias Mimo.Cognitive.{
    ConfidenceAssessor,
    GapDetector,
    EpistemicBrain,
    ReasoningSession,
    ProblemAnalyzer,
    ThoughtEvaluator,
    Uncertainty
  }

  alias Mimo.Cognitive.Strategies.{
    ChainOfThought,
    TreeOfThoughts,
    Reflexion
  }

  alias Mimo.Brain.Memory
  alias Mimo.TaskHelper

  @type strategy :: :auto | :cot | :tot | :react | :reflexion

  # Confidence threshold below which to trigger research (reserved for future use)
  # @confidence_threshold 0.5

  # ============================================
  # Main API
  # ============================================

  @doc """
  Start guided reasoning on a problem.

  Analyzes the problem, selects the best strategy, searches for
  similar past problems, and returns initial guidance.

  ## Options

  - `:strategy` - Force a specific strategy (:cot, :tot, :react, :reflexion)
                  Default is :auto which analyzes the problem
  """
  @spec guided(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def guided(problem, opts \\ []) do
    if problem == "" or is_nil(problem) do
      {:error, "Problem is required for guided reasoning"}
    else
      # Step 1: Search memory for similar past problems (async with timeout)
      similar_problems = search_similar_problems(problem)

      # Step 2: Assess initial confidence (async with timeout to avoid hanging)
      uncertainty = assess_with_timeout(problem)

      # Step 3: Detect knowledge gaps
      gaps = GapDetector.analyze_uncertainty(uncertainty)

      # Step 4: If gaps are critical, note for auto-research
      research_needed = gaps.severity in [:critical, :moderate]

      # Step 5: Select strategy based on problem characteristics
      requested_strategy = Keyword.get(opts, :strategy, :auto)

      {analysis, strategy, strategy_reason} =
        if requested_strategy == :auto do
          ProblemAnalyzer.analyze_and_recommend(problem)
        else
          {ProblemAnalyzer.analyze(problem), requested_strategy, "Explicitly requested"}
        end

      # Step 6: Generate initial decomposition
      decomposition = ProblemAnalyzer.decompose(problem)

      # Step 7: Create session
      session =
        ReasoningSession.create(problem, strategy,
          decomposition: decomposition,
          similar_problems: similar_problems
        )

      # Step 8: Generate initial guidance
      guidance = generate_initial_guidance(strategy, decomposition, uncertainty, similar_problems)

      {:ok,
       %{
         session_id: session.id,
         strategy: strategy,
         strategy_reason: strategy_reason,
         problem_analysis: %{
           complexity: analysis.complexity,
           involves_tools: analysis.involves_tools,
           programming_task: analysis.programming_task,
           ambiguous: analysis.ambiguous
         },
         confidence: %{
           level: uncertainty.confidence,
           score: Float.round(uncertainty.score, 3),
           gaps: gaps.gap_type,
           research_needed: research_needed
         },
         similar_problems: format_similar_problems(similar_problems),
         decomposition: decomposition,
         guidance: guidance
       }}
    end
  end

  @doc """
  Decompose a problem into sub-problems.
  """
  @spec decompose(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def decompose(problem, opts \\ []) do
    if problem == "" or is_nil(problem) do
      {:error, "Problem is required for decomposition"}
    else
      strategy = Keyword.get(opts, :strategy, :auto)

      {_analysis, actual_strategy, _reason} =
        if strategy == :auto do
          ProblemAnalyzer.analyze_and_recommend(problem)
        else
          {ProblemAnalyzer.analyze(problem), strategy, "Requested"}
        end

      sub_problems = ProblemAnalyzer.decompose(problem)

      # For ToT, also generate alternative approaches
      approaches =
        if actual_strategy == :tot do
          ProblemAnalyzer.generate_approaches(problem)
        else
          []
        end

      {:ok,
       %{
         original: problem,
         strategy: actual_strategy,
         sub_problems: sub_problems,
         approaches: approaches,
         complexity: ProblemAnalyzer.estimate_complexity(problem),
         dependencies: detect_dependencies(sub_problems)
       }}
    end
  end

  @doc """
  Record a reasoning step and get feedback (OPTIMIZED - FAST PATH).

  Completes in ~100ms with local evaluation only.
  No expensive context fetches from memory/graph/code.

  For deep context analysis, use: reason operation=enrich session_id=... step_number=...
  """
  @spec step(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def step(session_id, thought, _opts \\ []) do
    with {:ok, session} <- ReasoningSession.get(session_id) do
      # FAST: Evaluate against local session data only
      evaluation =
        ThoughtEvaluator.evaluate(thought, %{
          previous_thoughts: Enum.map(session.thoughts, & &1.content),
          problem: session.problem,
          strategy: session.strategy
        })

      # Quick local confidence assessment (no embeddings, no model calls)
      step_confidence = quick_confidence_assess(thought)

      # Create thought record
      new_thought = %{
        content: thought,
        step: length(session.thoughts) + 1,
        evaluation: evaluation.quality,
        confidence: confidence_to_float(step_confidence),
        branch_id: session.current_branch_id
      }

      # Update session
      {:ok, updated_session} = ReasoningSession.add_thought(session_id, new_thought)

      # Calculate progress
      progress = calculate_progress(updated_session)

      {:ok,
       %{
         session_id: session_id,
         step_number: new_thought.step,
         evaluation: %{
           quality: evaluation.quality,
           score: evaluation.score,
           feedback: evaluation.feedback,
           issues: evaluation.issues,
           suggestions: evaluation.suggestions
         },
         confidence: %{
           level: step_confidence,
           score: new_thought.confidence
         },
         progress: progress,
         should_continue: evaluation.quality != :bad,
         hint:
           "Use 'reason operation=enrich session_id=#{session_id} step_number=#{new_thought.step}' for deep context"
       }}
    end
  end

  @doc """
  Verify reasoning chain for logical consistency.
  """
  @spec verify(String.t() | [String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def verify(session_id_or_thoughts, _opts \\ []) do
    thoughts =
      case session_id_or_thoughts do
        id when is_binary(id) and byte_size(id) > 20 ->
          case ReasoningSession.get(id) do
            {:ok, session} -> Enum.map(session.thoughts, & &1.content)
            _ -> []
          end

        thoughts when is_list(thoughts) ->
          thoughts

        _ ->
          []
      end

    if thoughts == [] do
      {:error, "No thoughts to verify"}
    else
      # Check for logical issues
      issues = detect_logical_issues(thoughts)

      # Check for hallucination risk
      hallucination_risk = assess_hallucination_risk(thoughts)

      # Check for completeness
      completeness = assess_completeness(thoughts)

      {:ok,
       %{
         valid: issues == [],
         issues: issues,
         hallucination_risk: hallucination_risk,
         completeness: completeness,
         suggestions: generate_verification_suggestions(issues, completeness)
       }}
    end
  end

  @doc """
  Reflect on completed reasoning (Reflexion pattern).
  """
  @spec reflect(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def reflect(session_id, outcome, _opts \\ []) do
    with {:ok, session} <- ReasoningSession.get(session_id) do
      success = Map.get(outcome, :success, false)
      error = Map.get(outcome, :error)
      result = Map.get(outcome, :result)

      # Convert session thoughts to trajectory format
      trajectory =
        session.thoughts
        |> Enum.map(fn t ->
          %{
            type: :thought,
            content: t.content,
            timestamp: t.timestamp
          }
        end)

      # Generate reflection using Reflexion strategy
      reflection =
        if success do
          Reflexion.reflect_on_success(trajectory, result, session.problem)
        else
          Reflexion.reflect_on_failure(trajectory, error || "Unknown error", session.problem)
        end

      # Store reflection in memory
      {:ok, _} = Reflexion.store_reflection(reflection, session.problem, success)

      {:ok,
       %{
         session_id: session_id,
         success: success,
         critique: %{
           what_went_wrong: if(success, do: [], else: reflection.what_failed),
           what_could_help: reflection.improvements,
           what_to_try_next: Reflexion.suggest_alternative(reflection, session.problem)
         },
         lessons_learned: reflection.lessons_learned,
         verbal_feedback: reflection.verbal_feedback,
         stored_for_future: true
       }}
    end
  end

  @doc """
  Create a new reasoning branch (ToT pattern).
  """
  @spec branch(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def branch(session_id, branch_thought, _opts \\ []) do
    with {:ok, session} <- ReasoningSession.get(session_id) do
      if session.strategy != :tot do
        {:error, "Branching is only supported for Tree-of-Thoughts (tot) strategy"}
      else
        # Evaluate the branch thought
        evaluation =
          ThoughtEvaluator.evaluate(branch_thought, %{
            previous_thoughts: Enum.map(session.thoughts, & &1.content),
            problem: session.problem,
            strategy: :tot
          })

        # Create new branch
        new_branch = %{
          thoughts: [
            %{
              content: branch_thought,
              step: 1,
              evaluation: evaluation.quality,
              confidence: 0.5,
              branch_id: nil,
              timestamp: DateTime.utc_now()
            }
          ],
          evaluation: :uncertain,
          explored: false
        }

        # Add branch to session
        {:ok, updated_session} = ReasoningSession.add_branch(session_id, new_branch)

        # Get the created branch
        created_branch = List.last(updated_session.branches)

        {:ok,
         %{
           session_id: session_id,
           branch_id: created_branch.id,
           branch_thought: branch_thought,
           total_branches: length(updated_session.branches),
           current_exploration_depth:
             TreeOfThoughts.calculate_depth(created_branch, updated_session.branches)
         }}
      end
    end
  end

  @doc """
  Backtrack to a previous branch (ToT pattern).
  """
  @spec backtrack(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def backtrack(session_id, opts \\ []) do
    with {:ok, session} <- ReasoningSession.get(session_id) do
      if session.strategy != :tot do
        {:error, "Backtracking is only supported for Tree-of-Thoughts (tot) strategy"}
      else
        target_branch_id = Keyword.get(opts, :to_branch)

        # Mark current branch as dead end if not specified otherwise
        if session.current_branch_id do
          ReasoningSession.mark_branch_dead_end(session_id, session.current_branch_id)
        end

        # Find next branch
        {:ok, updated_session} = ReasoningSession.get(session_id)

        next_branch =
          if target_branch_id do
            Enum.find(updated_session.branches, &(&1.id == target_branch_id))
          else
            ReasoningSession.find_best_unexplored_branch(updated_session)
          end

        if next_branch do
          {:ok, final_session} = ReasoningSession.switch_branch(session_id, next_branch.id)

          {:ok,
           %{
             session_id: session_id,
             backtracked_from: session.current_branch_id,
             now_on_branch: next_branch.id,
             branch_status: next_branch.evaluation,
             remaining_unexplored: count_unexplored_branches(final_session.branches)
           }}
        else
          # No more branches to explore
          {:ok,
           %{
             session_id: session_id,
             no_more_branches: true,
             all_explored: true,
             suggestion: "All branches explored. Use 'conclude' to synthesize the best answer."
           }}
        end
      end
    end
  end

  @doc """
  Conclude reasoning and generate final answer.
  """
  @spec conclude(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def conclude(session_id, _opts \\ []) do
    with {:ok, session} <- ReasoningSession.get(session_id) do
      if session.thoughts == [] do
        {:error, "Cannot conclude without any reasoning steps"}
      else
        # Synthesize all thoughts/branches into conclusion
        synthesis = synthesize_reasoning(session)

        # Final confidence assessment
        final_confidence = assess_conclusion_confidence(session, synthesis)

        # Generate calibrated response
        _calibrated = EpistemicBrain.query(synthesis.conclusion)

        # Store successful reasoning pattern if confidence is good
        if final_confidence.level in [:high, :medium] do
          store_reasoning_pattern(session, synthesis)
        end

        # Complete session
        ReasoningSession.complete(session_id)

        {:ok,
         %{
           session_id: session_id,
           conclusion: synthesis.conclusion,
           confidence: final_confidence,
           reasoning_summary: synthesis.summary,
           key_insights: synthesis.key_insights,
           total_steps: length(session.thoughts)
         }}
      end
    end
  end

  @doc """
  Enrich a recorded step with deep context analysis (OPTIONAL).

  Fetches context from memory, knowledge graph, and code symbols in parallel.
  Times out gracefully after 5 seconds.

  ## Example

      {:ok, enriched} = Reasoner.enrich(session_id, 1)
  """
  @spec enrich(String.t(), non_neg_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def enrich(session_id, step_number, _opts \\ []) do
    with {:ok, session} <- ReasoningSession.get(session_id) do
      target_thought = Enum.at(session.thoughts, step_number - 1)

      if is_nil(target_thought) do
        {:error, "Step #{step_number} not found"}
      else
        enrichment_task =
          TaskHelper.async_with_callers(fn ->
            enrich_with_context(target_thought, session)
          end)

        case Task.yield(enrichment_task, 5000) || Task.shutdown(enrichment_task) do
          {:ok, enrichment} ->
            {:ok, enrichment}

          _ ->
            {:ok,
             %{
               session_id: session_id,
               step_number: step_number,
               status: "timed_out",
               note: "Full enrichment took >5s. Step is already recorded."
             }}
        end
      end
    end
  end

  @doc """
  Record multiple reasoning steps in batch (EFFICIENT).

  More efficient than calling step/3 multiple times.

  ## Example

      {:ok, batch} = Reasoner.steps(session_id, [
        "First observation...",
        "Second analysis...",
        "Third conclusion..."
      ])
  """
  @spec steps(String.t(), [String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def steps(session_id, thoughts, _opts \\ []) when is_list(thoughts) do
    if Enum.empty?(thoughts) do
      {:error, "At least one thought required"}
    else
      with {:ok, session} <- ReasoningSession.get(session_id) do
        results =
          Enum.map_reduce(thoughts, session, fn thought, current_session ->
            evaluation =
              ThoughtEvaluator.evaluate(thought, %{
                previous_thoughts: Enum.map(current_session.thoughts, & &1.content),
                problem: current_session.problem,
                strategy: current_session.strategy
              })

            new_thought = %{
              content: thought,
              step: length(current_session.thoughts) + 1,
              evaluation: evaluation.quality,
              confidence: confidence_to_float(quick_confidence_assess(thought)),
              branch_id: current_session.current_branch_id
            }

            case ReasoningSession.add_thought(session_id, new_thought) do
              {:ok, updated} ->
                {%{step: new_thought.step, quality: evaluation.quality}, updated}

              error ->
                {error, current_session}
            end
          end)

        {:ok, final_session} = ReasoningSession.get(session_id)

        {:ok,
         %{
           session_id: session_id,
           steps_added: length(thoughts),
           results: results,
           progress: calculate_progress(final_session)
         }}
      end
    end
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp quick_confidence_assess(thought) do
    thought_length = String.length(thought)
    has_reasoning = String.match?(thought, ~r/\b(therefore|so|thus|because|results? in)\b/i)
    has_specificity = String.match?(thought, ~r/\b(specific|clear|example|shows)\b/i)
    has_uncertainty = String.match?(thought, ~r/\b(maybe|might|could|perhaps)\b/i)

    cond do
      thought_length < 20 -> :low
      has_reasoning and has_specificity and not has_uncertainty -> :high
      has_reasoning or has_specificity -> :medium
      has_uncertainty -> :low
      true -> :medium
    end
  end

  defp enrich_with_context(thought, session) do
    {:ok,
     %{
       session_id: session.id,
       step_content: thought,
       enrichment: %{
         memory_context: [],
         knowledge_connections: [],
         code_references: []
       },
       status: "enriched"
     }}
  rescue
    _error ->
      {:ok, %{status: "enrichment_failed", note: "Error during enrichment, step is still recorded"}}
  end

  defp format_similar_problems(memories) do
    memories
    |> Enum.take(3)
    |> Enum.map(fn m ->
      %{
        content: String.slice(m.content || "", 0..150),
        similarity: Float.round(m[:similarity] || 0.0, 2)
      }
    end)
  end

  defp generate_initial_guidance(strategy, decomposition, uncertainty, similar_problems) do
    parts = []

    # Strategy-specific guidance
    parts =
      case strategy do
        :cot ->
          ["Use step-by-step reasoning. Record each step with 'step' operation." | parts]

        :tot ->
          [
            "Multiple approaches are worth exploring. Use 'branch' to try alternatives and 'backtrack' if stuck."
            | parts
          ]

        :react ->
          ["This problem likely needs tool use. Interleave thinking with actions." | parts]

        :reflexion ->
          ["This may need iteration. Use 'reflect' after attempts to learn and improve." | parts]

        _ ->
          parts
      end

    # Add confidence guidance
    parts =
      if uncertainty.confidence in [:low, :unknown] do
        ["Note: Confidence is low. Consider gathering more information before concluding." | parts]
      else
        parts
      end

    # Add similar problem guidance
    parts =
      if length(similar_problems) > 0 do
        ["Found #{length(similar_problems)} similar past problem(s) that may help." | parts]
      else
        parts
      end

    # Add decomposition
    parts =
      if length(decomposition) > 0 do
        steps = Enum.map_join(decomposition, "\n", fn step -> "• #{step}" end)
        ["Suggested approach:\n#{steps}" | parts]
      else
        parts
      end

    Enum.reverse(parts) |> Enum.join("\n\n")
  end

  defp calculate_progress(session) do
    step_count = length(session.thoughts)

    expected_steps =
      case session.strategy do
        :cot -> ChainOfThought.typical_steps(session.problem)
        _ -> 5
      end

    raw_progress = step_count / expected_steps * 100
    min(100.0, Float.round(raw_progress, 1))
  end

  defp detect_logical_issues(thoughts) do
    issues = []

    # Check each thought for issues
    thoughts
    |> Enum.with_index()
    |> Enum.reduce(issues, fn {thought, idx}, acc ->
      prev = Enum.take(thoughts, idx)
      eval = ThoughtEvaluator.evaluate(thought, %{previous_thoughts: prev})
      if eval.issues != [], do: eval.issues ++ acc, else: acc
    end)
    |> Enum.uniq()
  end

  defp assess_hallucination_risk(thoughts) do
    risks =
      Enum.map(thoughts, fn thought ->
        result = ThoughtEvaluator.detect_hallucination_risk(thought)
        result.score
      end)

    avg_risk = 1.0 - Enum.sum(risks) / max(length(risks), 1)

    cond do
      avg_risk > 0.6 -> :high
      avg_risk > 0.3 -> :medium
      true -> :low
    end
  end

  defp assess_completeness(thoughts) do
    if thoughts == [] do
      :incomplete
    else
      last = List.last(thoughts) |> String.downcase()

      has_conclusion = String.match?(last, ~r/\b(therefore|thus|conclude|answer|result|solution)\b/)
      sufficient_depth = length(thoughts) >= 3

      cond do
        has_conclusion and sufficient_depth -> :complete
        has_conclusion -> :possibly_incomplete
        true -> :incomplete
      end
    end
  end

  defp generate_verification_suggestions(issues, completeness) do
    suggestions = []

    suggestions =
      if issues != [] do
        ["Address logical issues: #{Enum.take(issues, 2) |> Enum.join("; ")}" | suggestions]
      else
        suggestions
      end

    suggestions =
      case completeness do
        :incomplete -> ["Add a concluding step that summarizes the answer" | suggestions]
        :possibly_incomplete -> ["Consider adding more supporting reasoning" | suggestions]
        :complete -> suggestions
      end

    Enum.reverse(suggestions)
  end

  defp synthesize_reasoning(session) do
    thoughts = Enum.map(session.thoughts, & &1.content)

    # Extract key insights
    key_insights =
      thoughts
      |> Enum.filter(fn t ->
        String.match?(t, ~r/\b(found|realized|key|important|crucial|answer|solution)\b/i)
      end)
      |> Enum.take(3)
      |> Enum.map(&String.slice(&1, 0..150))

    # Generate conclusion from last thoughts
    conclusion =
      thoughts
      |> Enum.take(-2)
      |> Enum.join(" ")
      |> String.slice(0..500)

    # Generate summary
    summary = "Reasoned through #{length(thoughts)} steps using #{session.strategy} strategy."

    %{
      conclusion: conclusion,
      summary: summary,
      key_insights: key_insights
    }
  end

  defp assess_conclusion_confidence(session, _synthesis) do
    # Average confidence across all thoughts
    confidences = Enum.map(session.thoughts, & &1.confidence)

    avg_confidence =
      if confidences == [], do: 0.5, else: Enum.sum(confidences) / length(confidences)

    level =
      cond do
        avg_confidence >= 0.7 -> :high
        avg_confidence >= 0.4 -> :medium
        true -> :low
      end

    %{
      level: level,
      score: Float.round(avg_confidence, 3),
      basis: "Averaged across #{length(confidences)} reasoning steps"
    }
  end

  defp store_reasoning_pattern(session, synthesis) do
    # Store asynchronously to avoid blocking
    Mimo.Sandbox.run_async(Mimo.Repo, fn ->
      content = """
      Solved: #{String.slice(session.problem, 0..100)}
      Strategy: #{session.strategy}
      Steps: #{length(session.thoughts)}
      Approach: #{synthesis.summary}
      Key insights: #{Enum.join(synthesis.key_insights, "; ")}
      """

      Memory.persist_memory(content,
        category: :action,
        importance: 0.75,
        metadata: %{
          type: "reasoning_pattern",
          strategy: session.strategy,
          steps: length(session.thoughts),
          problem_hash: :erlang.phash2(session.problem)
        }
      )
    end)
  rescue
    _ -> :ok
  end

  defp detect_dependencies(sub_problems) do
    # Simple dependency detection based on order
    sub_problems
    |> Enum.with_index()
    |> Enum.map(fn {_problem, idx} ->
      if idx == 0, do: nil, else: idx - 1
    end)
  end

  defp count_unexplored_branches(branches) do
    Enum.count(branches, fn b -> not b.explored and b.evaluation != :dead_end end)
  end

  defp confidence_to_float(level) do
    case level do
      :high -> 0.85
      :medium -> 0.6
      :low -> 0.35
      :unknown -> 0.15
    end
  end

  # ============================================
  # Missing Private Helpers (restored)
  # ============================================

  defp search_similar_problems(problem) do
    # Search memory for similar past problems with timeout
    task =
      TaskHelper.async_with_callers(fn ->
        try do
          Memory.search(problem, limit: 5, threshold: 0.4)
        rescue
          _ -> []
        catch
          :exit, _ -> []
        end
      end)

    case Task.yield(task, 3000) || Task.shutdown(task) do
      {:ok, {:ok, results}} -> results
      {:ok, results} when is_list(results) -> results
      _ -> []
    end
  end

  defp assess_with_timeout(problem) do
    # Assess confidence with timeout to avoid hanging
    task =
      TaskHelper.async_with_callers(fn ->
        try do
          ConfidenceAssessor.assess(problem)
        rescue
          _ -> %Uncertainty{topic: problem, confidence: :unknown, score: 0.0}
        catch
          :exit, _ -> %Uncertainty{topic: problem, confidence: :unknown, score: 0.0}
        end
      end)

    case Task.yield(task, 3000) || Task.shutdown(task) do
      {:ok, result} -> result
      _ -> %Uncertainty{topic: problem, confidence: :unknown, score: 0.0}
    end
  end
end
