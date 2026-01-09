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

  alias Mimo.Brain.{Memory, WisdomInjector}

  alias Mimo.Cognitive.{
    ConfidenceAssessor,
    EpistemicBrain,
    FeedbackLoop,
    GapDetector,
    MetaTaskDetector,
    MetaTaskHandler,
    ProblemAnalyzer,
    ReasoningSession,
    ThoughtEvaluator,
    Uncertainty,
    VerificationTelemetry
  }

  alias Mimo.Cognitive.Strategies.{
    ChainOfThought,
    Reflexion,
    TreeOfThoughts
  }

  alias Mimo.TaskHelper
  alias Mimo.Tools.Dispatchers.PrepareContext

  @type strategy :: :auto | :cot | :tot | :react | :reflexion

  # Confidence threshold below which to trigger research (reserved for future use)
  # @confidence_threshold 0.5

  @doc """
  Start guided reasoning on a problem.

  Analyzes the problem, selects the best strategy, searches for
  similar past problems, and returns initial guidance.

  ## Options

  - `:strategy` - Force a specific strategy (:cot, :tot, :react, :reflexion)
                  Default is :auto which analyzes the problem

  ## SPEC-062 Meta-Task Detection

  Automatically detects meta-tasks (tasks requiring self-generated content)
  and enhances the problem with explicit guidance to prevent literal
  interpretation failures.
  """
  @spec guided(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def guided(problem, opts \\ []) do
    if problem == "" or is_nil(problem) do
      {:error, "Problem is required for guided reasoning"}
    else
      # Check if we're in a fallback from MetaTaskHandler (prevent recursive loop)
      skip_meta_handler = Keyword.get(opts, :skip_meta_handler, false)

      # SPEC-062: Check for meta-task FIRST
      {enhanced_problem, meta_task_info} = detect_and_enhance_meta_task(problem)

      # SPEC-063: If technique is specified or auto, use MetaTaskHandler for meta-tasks
      # BUT skip if we're already falling back from MetaTaskHandler to prevent infinite loop
      technique = Keyword.get(opts, :technique, :auto)
      requested_strategy = Keyword.get(opts, :strategy, :auto)
      use_advanced = technique != :none and meta_task_info != nil and not skip_meta_handler

      if use_advanced and requested_strategy == :auto and
           technique in [:auto, :self_discover, :rephrase, :self_ask, :combined] do
        # Use MetaTaskHandler for advanced techniques
        case MetaTaskHandler.handle(problem, strategy: technique) do
          {:ok, handler_result} ->
            {:ok,
             %{
               session_id: nil,
               strategy: technique,
               strategy_reason: "SPEC-063 advanced technique",
               meta_task: true,
               handler_result: handler_result
             }}

          {:error, _} ->
            # Fall through to standard reasoning if handler fails
            do_guided_reasoning(enhanced_problem, meta_task_info, opts)
        end
      else
        do_guided_reasoning(enhanced_problem, meta_task_info, opts)
      end
    end
  end

  # Standard guided reasoning logic (extracted for SPEC-063 fallback)
  defp do_guided_reasoning(enhanced_problem, meta_task_info, opts) do
    # Step 1: Search memory for similar past problems (async with timeout)
    similar_problems = search_similar_problems(enhanced_problem)

    # SPEC-074-ENHANCED: Search for similar past conclusions (cross-session transfer)
    similar_conclusions = search_similar_conclusions(enhanced_problem)

    # Step 2: Assess initial confidence (async with timeout to avoid hanging)
    # Boost confidence if we have relevant past conclusions
    base_uncertainty = assess_with_timeout(enhanced_problem)
    uncertainty = maybe_boost_from_conclusions(base_uncertainty, similar_conclusions)

    # Step 3: Detect knowledge gaps
    gaps = GapDetector.analyze_uncertainty(uncertainty)

    # Step 4: If gaps are critical, note for auto-research
    research_needed = gaps.severity in [:critical, :moderate]

    # Step 5: Select strategy based on problem characteristics
    requested_strategy = Keyword.get(opts, :strategy, :auto)

    {analysis, strategy, strategy_reason} =
      if requested_strategy == :auto do
        ProblemAnalyzer.analyze_and_recommend(enhanced_problem)
      else
        {ProblemAnalyzer.analyze(enhanced_problem), requested_strategy, "Explicitly requested"}
      end

    # Step 6: Generate initial decomposition
    decomposition = ProblemAnalyzer.decompose(enhanced_problem)

    # Step 7: Create session with meta-task context
    session =
      ReasoningSession.create(enhanced_problem, strategy,
        decomposition: decomposition,
        similar_problems: similar_problems,
        meta_task: meta_task_info
      )

    # Level 4: Record strategy decision for metacognitive monitoring
    Mimo.Cognitive.MetacognitiveMonitor.record_strategy_decision(session.id, strategy, %{
      problem_complexity: analysis.complexity,
      involves_tools: analysis.involves_tools,
      programming_task: analysis.programming_task,
      ambiguous: analysis.ambiguous,
      similar_problems_found: length(similar_problems),
      reason: strategy_reason,
      alternatives: [:cot, :tot, :react, :reflexion]
    })

    # Step 8: Generate initial guidance (enhanced for meta-tasks)
    guidance = generate_initial_guidance(strategy, decomposition, uncertainty, similar_problems)

    # SPEC-062: Add meta-task specific guidance if detected
    enhanced_guidance =
      if meta_task_info do
        guidance <>
          "\n\n⚠️ META-TASK DETECTED: " <>
          meta_task_info.instruction <>
          if(meta_task_info.example, do: "\nExample: #{meta_task_info.example}", else: "")
      else
        guidance
      end

    # Emit telemetry for meta-task integration
    if meta_task_info do
      VerificationTelemetry.emit_reasoner_meta_task(
        session.id,
        meta_task_info.type,
        meta_task_info
      )
    end

    {:ok,
     %{
       session_id: session.id,
       strategy: strategy,
       strategy_reason: strategy_reason,
       problem_analysis: %{
         complexity: analysis.complexity,
         involves_tools: analysis.involves_tools,
         programming_task: analysis.programming_task,
         ambiguous: analysis.ambiguous,
         meta_task: meta_task_info != nil,
         meta_task_type: if(meta_task_info, do: meta_task_info.type, else: nil)
       },
       confidence: %{
         level: uncertainty.confidence,
         score: Float.round(uncertainty.score, 3),
         gaps: gaps.gap_type,
         research_needed: research_needed
       },
       similar_problems: format_similar_problems(similar_problems),
       decomposition: decomposition,
       guidance: enhanced_guidance
     }}
  end

  # SPEC-062: Detect and enhance meta-tasks
  defp detect_and_enhance_meta_task(problem) do
    case MetaTaskDetector.detect(problem) do
      {:meta_task, guidance} ->
        Logger.info("[Reasoner] Meta-task detected: #{guidance.type}")

        enhanced = """
        #{problem}

        ⚠️ META-TASK (#{guidance.type}): #{guidance.instruction}
        """

        {enhanced, guidance}

      {:standard, _} ->
        {problem, nil}
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
      case ReasoningSession.add_thought(session_id, new_thought) do
        {:ok, updated_session} ->
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

        {:error, reason} ->
          {:error, "Failed to add thought: #{inspect(reason)}"}
      end
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
    case ReasoningSession.get(session_id) do
      {:ok, session} ->
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

        # Store reflection in memory (best-effort, don't crash if fails)
        _ = Reflexion.store_reflection(reflection, session.problem, success)

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

      {:error, :not_found} ->
        # Helpful error message - likely called after conclude
        {:error,
         "Session '#{session_id}' not found. If you called 'conclude' first, note that " <>
           "learnings are now auto-stored during conclude. Separate 'reflect' is optional. " <>
           "If you need explicit reflection, call it BEFORE conclude."}

      error ->
        error
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
        case ReasoningSession.add_branch(session_id, new_branch) do
          {:ok, updated_session} ->
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

          {:error, reason} ->
            {:error, "Failed to add branch: #{inspect(reason)}"}
        end
      end
    end
  end

  @doc """
  Backtrack to a previous branch (ToT pattern).
  """
  @spec backtrack(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def backtrack(session_id, opts \\ []) do
    with {:ok, session} <- ReasoningSession.get(session_id),
         :ok <- validate_tot_strategy(session) do
      do_backtrack(session_id, session, opts)
    end
  end

  defp validate_tot_strategy(%{strategy: :tot}), do: :ok

  defp validate_tot_strategy(_),
    do: {:error, "Backtracking is only supported for Tree-of-Thoughts (tot) strategy"}

  defp do_backtrack(session_id, session, opts) do
    target_branch_id = Keyword.get(opts, :to_branch)

    if session.current_branch_id do
      ReasoningSession.mark_branch_dead_end(session_id, session.current_branch_id)
    end

    case ReasoningSession.get(session_id) do
      {:ok, updated_session} ->
        find_and_switch_branch(session_id, session, updated_session, target_branch_id)

      {:error, reason} ->
        {:error, "Failed to get session: #{inspect(reason)}"}
    end
  end

  defp find_and_switch_branch(session_id, session, updated_session, target_branch_id) do
    next_branch =
      if target_branch_id do
        Enum.find(updated_session.branches, &(&1.id == target_branch_id))
      else
        ReasoningSession.find_best_unexplored_branch(updated_session)
      end

    switch_to_branch(session_id, session, next_branch)
  end

  defp switch_to_branch(session_id, _session, nil) do
    {:ok,
     %{
       session_id: session_id,
       no_more_branches: true,
       all_explored: true,
       suggestion: "All branches explored. Use 'conclude' to synthesize the best answer."
     }}
  end

  defp switch_to_branch(session_id, session, next_branch) do
    case ReasoningSession.switch_branch(session_id, next_branch.id) do
      {:ok, final_session} ->
        {:ok,
         %{
           session_id: session_id,
           backtracked_from: session.current_branch_id,
           now_on_branch: next_branch.id,
           branch_status: next_branch.evaluation,
           remaining_unexplored: count_unexplored_branches(final_session.branches)
         }}

      {:error, reason} ->
        {:error, "Failed to switch branch: #{inspect(reason)}"}
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

        # AUTO-REFLECTION: Store learnings before completing session
        # This eliminates the need for a separate reflect call (fixes conclude→reflect order issue)
        reflection_stored =
          try do
            trajectory =
              session.thoughts
              |> Enum.map(fn t ->
                %{type: :thought, content: t.content, timestamp: t.timestamp}
              end)

            reflection =
              Reflexion.reflect_on_success(trajectory, synthesis.conclusion, session.problem)

            Reflexion.store_reflection(reflection, session.problem, true)
            true
          rescue
            _ -> false
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
           total_steps: length(session.thoughts),
           reflection_stored: reflection_stored
         }}
      end
    end
  end

  @doc """
  Get aggregated reasoning statistics.

  Returns metrics from FeedbackLoop, session stats, strategy distribution,
  and verification rates for observability.
  """
  @spec stats() :: map()
  def stats do
    feedback_stats = safe_get_feedback_stats()
    session_stats = ReasoningSession.stats()

    %{
      feedback: feedback_stats,
      sessions: session_stats,
      strategies: compute_strategy_distribution(),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp safe_get_feedback_stats do
    try do
      FeedbackLoop.stats()
    rescue
      _ -> %{error: "FeedbackLoop not available"}
    end
  end

  defp compute_strategy_distribution do
    # Query recent sessions for strategy usage
    case ReasoningSession.list_recent(100) do
      {:ok, sessions} ->
        sessions
        |> Enum.frequencies_by(& &1.strategy)
        |> Enum.map(fn {strategy, count} -> {strategy, count} end)
        |> Map.new()

      _ ->
        %{}
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
        {results, _last_session} =
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

        final_session =
          case ReasoningSession.get(session_id) do
            {:ok, s} -> s
            {:error, _} -> session
          end

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
    content = Map.get(thought, :content, thought)

    # Gather context from various sources
    prepared_context = fetch_prepared_context(content)
    uncertainty = assess_with_timeout(content)
    merged_wisdom = build_merged_wisdom(prepared_context, content, uncertainty)

    # Build enrichment structure
    enrichment = build_enrichment(prepared_context, uncertainty, merged_wisdom)

    %{
      session_id: session.id,
      step_content: thought,
      enrichment: enrichment,
      status: "enriched"
    }
  rescue
    _error ->
      %{status: "enrichment_failed", note: "Error during enrichment, step is still recorded"}
  end

  defp fetch_prepared_context(content) do
    case PrepareContext.dispatch(%{"query" => content, "include_scores" => true}) do
      {:ok, prepared} -> prepared
      _ -> %{}
    end
  end

  defp build_merged_wisdom(prepared_context, content, uncertainty) do
    score = Map.get(uncertainty, :score, 0.0)

    wisdom_injection =
      case WisdomInjector.inject_if_uncertain(content, score) do
        {:inject, w} -> w
        :skip -> %{}
      end

    prepared_wisdom = get_in(prepared_context, [:context, :wisdom]) || %{}
    merge_wisdom(prepared_wisdom, wisdom_injection)
  end

  defp build_enrichment(prepared_context, uncertainty, merged_wisdom) do
    memory_context = get_in(prepared_context, [:context, :memory, :items]) || []

    knowledge_connections =
      (get_in(prepared_context, [:context, :knowledge, :relationships]) || []) ++
        (get_in(prepared_context, [:context, :knowledge, :nodes]) || [])

    code_references = get_in(prepared_context, [:context, :code, :items]) || []
    patterns = get_in(prepared_context, [:context, :patterns, :items]) || []
    formatted_context = prepared_context[:formatted_context] || ""

    sm_boost = Map.get(prepared_context, :small_model_boost, %{})
    wisdom_injected_flag = has_wisdom_injection?(merged_wisdom, sm_boost)

    %{
      memory_context: memory_context,
      knowledge_connections: knowledge_connections,
      code_references: code_references,
      patterns: patterns,
      wisdom: merged_wisdom,
      formatted_context: formatted_context,
      confidence: %{
        level: Map.get(uncertainty, :confidence),
        score: Map.get(uncertainty, :score, 0.0)
      },
      small_model_boost: %{
        patterns_matched: Map.get(sm_boost, :patterns_matched, false),
        wisdom_injected: wisdom_injected_flag
      }
    }
  end

  defp has_wisdom_injection?(merged_wisdom, sm_boost) do
    (merged_wisdom[:failures] || []) != [] or
      (merged_wisdom[:warnings] || []) != [] or
      Map.get(sm_boost, :wisdom_injected, false)
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
      if Enum.empty?(similar_problems) do
        parts
      else
        ["Found #{length(similar_problems)} similar past problem(s) that may help." | parts]
      end

    # Add decomposition
    parts =
      if Enum.empty?(decomposition) do
        parts
      else
        steps = Enum.map_join(decomposition, "\n", fn step -> "• #{step}" end)
        ["Suggested approach:\n#{steps}" | parts]
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

  defp merge_wisdom(prepared_wisdom, injected_wisdom) do
    prepared_wisdom = prepared_wisdom || %{}
    injected_wisdom = injected_wisdom || %{}

    failures = (prepared_wisdom[:failures] || []) ++ (injected_wisdom[:failures] || [])
    warnings = (prepared_wisdom[:warnings] || []) ++ (injected_wisdom[:warnings] || [])
    patterns = (prepared_wisdom[:patterns] || []) ++ (injected_wisdom[:patterns] || [])

    %{
      failures: Enum.uniq_by(failures, &(&1.content || inspect(&1))),
      warnings: Enum.uniq_by(warnings, &(&1.message || inspect(&1))),
      patterns: Enum.uniq_by(patterns, &(&1.id || inspect(&1))),
      formatted:
        Enum.reject(
          [
            prepared_wisdom[:formatted] || "",
            injected_wisdom[:formatted] || ""
          ],
          &(&1 == "")
        )
        |> Enum.join("\n\n")
    }
  end

  defp confidence_to_float(level) do
    case level do
      :high -> 0.85
      :medium -> 0.6
      :low -> 0.35
    end
  end

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

  # SPEC-074-ENHANCED: Boost confidence if we have relevant past conclusions
  defp maybe_boost_from_conclusions(uncertainty, []) do
    uncertainty
  end

  defp maybe_boost_from_conclusions(%Uncertainty{} = uncertainty, conclusions)
       when is_list(conclusions) do
    # Calculate boost based on number and quality of past conclusions
    high_conf_count =
      Enum.count(conclusions, fn c ->
        conf = c[:confidence] || 0
        is_number(conf) and conf >= 0.7
      end)

    boost =
      cond do
        high_conf_count >= 3 -> 0.2
        high_conf_count >= 1 -> 0.1
        length(conclusions) >= 2 -> 0.05
        true -> 0.0
      end

    new_score = min(uncertainty.score + boost, 1.0)

    new_level =
      cond do
        new_score >= 0.7 -> :high
        new_score >= 0.4 -> :medium
        new_score >= 0.2 -> :low
        true -> :unknown
      end

    %{uncertainty | score: new_score, confidence: new_level}
  end

  defp maybe_boost_from_conclusions(uncertainty, _), do: uncertainty

  @doc """
  SPEC-074-ENHANCED: Search for similar past conclusions.

  Retrieves past reasoning conclusions that are relevant to the current problem.
  These are stored with 'conclusion' metadata when sessions successfully complete.
  """
  @spec search_similar_conclusions(String.t()) :: [map()]
  def search_similar_conclusions(problem) do
    task =
      TaskHelper.async_with_callers(fn ->
        try do
          # Search for memories tagged as conclusions
          case Memory.search("conclusion: " <> problem, limit: 5, threshold: 0.5) do
            {:ok, results} ->
              results
              |> Enum.filter(&is_conclusion?/1)
              |> Enum.map(&format_conclusion/1)

            _ ->
              []
          end
        rescue
          _ -> []
        catch
          :exit, _ -> []
        end
      end)

    case Task.yield(task, 3000) || Task.shutdown(task) do
      {:ok, results} when is_list(results) -> results
      _ -> []
    end
  end

  defp is_conclusion?(memory) do
    metadata = memory[:metadata] || memory["metadata"] || %{}
    type = metadata[:type] || metadata["type"]
    type == "conclusion" or type == :conclusion
  end

  defp format_conclusion(memory) do
    content = memory[:content] || memory["content"] || ""
    metadata = memory[:metadata] || memory["metadata"] || %{}

    %{
      summary: String.slice(content, 0, 200),
      problem: metadata[:problem] || metadata["problem"],
      strategy: metadata[:strategy] || metadata["strategy"],
      confidence: metadata[:confidence] || metadata["confidence"],
      timestamp: memory[:inserted_at] || memory["inserted_at"]
    }
  end
end
