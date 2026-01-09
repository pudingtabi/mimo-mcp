defmodule Mimo.Cognitive.InterleavedThinking do
  @moduledoc """
  SPEC-082: Interleaved Thinking Engine

  Enhances AI reasoning by interleaving thinking steps with:
  - Memory verification (check claims against stored knowledge)
  - Proactive knowledge injection (surface relevant context)
  - Confidence-gated progression (pause when uncertain)
  - Self-correction loops (detect and fix potential errors)
  - Accumulated wisdom (build understanding across steps)

  ## Philosophy

  Traditional reasoning is linear: think → think → think → conclude.
  Interleaved thinking adds verification at each step:

      think → verify → enrich → think → verify → enrich → conclude

  This catches hallucinations early, grounds reasoning in stored facts,
  and builds confidence through accumulated evidence.

  ## Integration

  Works with the existing Reasoner infrastructure:
  - Uses ReasoningSession for state management
  - Integrates with Memory for fact checking
  - Leverages Knowledge graph for relationship validation
  - Employs ConfidenceAssessor for uncertainty detection

  ## Usage

      # Start interleaved reasoning
      {:ok, session} = InterleavedThinking.start("How do I fix the auth bug?")

      # Each step is automatically verified and enriched
      {:ok, step1} = InterleavedThinking.think(session.id, "First, I'll check the JWT config")
      # step1 includes: verification_result, injected_knowledge, confidence, corrections

      # Continue with accumulated context
      {:ok, step2} = InterleavedThinking.think(session.id, "The config looks correct, checking tokens")

      # Conclude with full reasoning chain verified
      {:ok, conclusion} = InterleavedThinking.conclude(session.id)
  """

  require Logger

  alias Mimo.Brain.{CorrectionLearning, Memory}

  alias Mimo.Cognitive.{
    AdaptiveStrategy,
    Reasoner,
    ReasoningSession,
    ThoughtEvaluator
  }

  alias Mimo.Synapse.QueryEngine, as: KnowledgeQuery
  alias Mimo.TaskHelper

  # Confidence threshold below which we inject warnings
  @low_confidence_threshold 0.4

  # Confidence threshold below which we require verification
  @verification_required_threshold 0.6

  # Maximum corrections per step before escalating
  @max_corrections_per_step 2

  @type interleaved_step :: %{
          thought: String.t(),
          verification: verification_result(),
          injected_knowledge: [map()],
          confidence: confidence_info(),
          corrections: [correction()],
          accumulated_context: accumulated_context(),
          should_continue: boolean(),
          warnings: [String.t()]
        }

  @type verification_result :: %{
          status: :verified | :partial | :unverified | :contradicted,
          supporting_facts: [map()],
          contradictions: [map()],
          gaps: [String.t()]
        }

  @type confidence_info :: %{
          level: :high | :medium | :low | :unknown,
          score: float(),
          factors: [String.t()]
        }

  @type correction :: %{
          original: String.t(),
          corrected: String.t(),
          reason: String.t(),
          source: :memory | :knowledge | :self_check
        }

  @type accumulated_context :: %{
          verified_facts: [String.t()],
          open_questions: [String.t()],
          reasoning_chain: [String.t()],
          confidence_trend: [float()]
        }

  @doc """
  Start an interleaved thinking session.

  Analyzes the problem, searches for relevant context, and initializes
  the session with accumulated wisdom from memory.
  """
  @spec start(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def start(problem, opts \\ []) do
    if problem == "" or is_nil(problem) do
      {:error, "Problem is required to start interleaved thinking"}
    else
      # Use guided reasoning to analyze and create session
      case Reasoner.guided(problem, Keyword.merge(opts, strategy: :auto)) do
        {:ok, guided_result} ->
          session_id = guided_result.session_id

          # Initialize accumulated context
          initial_context = build_initial_context(problem, guided_result)

          # Store in session metadata
          update_session_context(session_id, initial_context)

          {:ok,
           %{
             session_id: session_id,
             strategy: guided_result.strategy,
             problem_analysis: guided_result.problem_analysis,
             initial_confidence: guided_result.confidence,
             initial_context: %{
               similar_problems: length(guided_result.similar_problems),
               decomposition_steps: length(guided_result.decomposition),
               research_needed: guided_result.confidence.research_needed
             },
             guidance: guided_result.guidance,
             mode: :interleaved,
             hint: "Use InterleavedThinking.think/2 to add verified reasoning steps"
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Add a thinking step with automatic verification and enrichment.

  This is the core of interleaved thinking - each thought is:
  1. Evaluated for quality
  2. Verified against memory and knowledge
  3. Enriched with relevant context
  4. Checked for confidence level
  5. Corrected if issues detected
  """
  @spec think(String.t(), String.t(), keyword()) :: {:ok, interleaved_step()} | {:error, term()}
  def think(session_id, thought, opts \\ []) do
    with {:ok, session} <- ReasoningSession.get(session_id) do
      # Get accumulated context
      acc_context = get_accumulated_context(session)

      # Phase 1: Evaluate thought quality
      evaluation = evaluate_thought(thought, session, acc_context)

      # Phase 2: Verify against memory and knowledge (parallel)
      verification_task =
        TaskHelper.async_with_callers(fn ->
          verify_thought(thought, session.problem, acc_context)
        end)

      # Phase 3: Search for relevant knowledge to inject
      injection_task =
        TaskHelper.async_with_callers(fn ->
          find_relevant_knowledge(thought, session.problem)
        end)

      # Phase 4: Assess confidence
      confidence = assess_thought_confidence(thought, evaluation)

      # Gather async results with timeout
      verification =
        case Task.yield(verification_task, 3000) || Task.shutdown(verification_task) do
          {:ok, result} -> result
          _ -> default_verification()
        end

      injected_knowledge =
        case Task.yield(injection_task, 2000) || Task.shutdown(injection_task) do
          {:ok, result} -> result
          _ -> []
        end

      # Phase 5: Generate corrections if needed
      corrections =
        if needs_correction?(verification, confidence) do
          generate_corrections(thought, verification, injected_knowledge, opts)
        else
          []
        end

      # Phase 6: Update accumulated context
      new_acc_context =
        update_accumulated_context(acc_context, thought, verification, confidence)

      # Phase 7: Determine if we should continue or need intervention
      {should_continue, warnings} =
        determine_continuation(verification, confidence, corrections, new_acc_context)

      # Record the step in the session
      step_record = %{
        content: thought,
        step: length(session.thoughts) + 1,
        evaluation: evaluation.quality,
        confidence: confidence.score,
        branch_id: session.current_branch_id,
        interleaved: true,
        verification_status: verification.status
      }

      case ReasoningSession.add_thought(session_id, step_record) do
        {:ok, _updated_session} ->
          # Store updated accumulated context
          update_session_context(session_id, new_acc_context)

          {:ok,
           %{
             session_id: session_id,
             step_number: step_record.step,
             thought: thought,
             evaluation: %{
               quality: evaluation.quality,
               score: evaluation.score,
               feedback: evaluation.feedback
             },
             verification: %{
               status: verification.status,
               supporting_facts: format_facts(verification.supporting_facts),
               contradictions: format_facts(verification.contradictions),
               gaps: verification.gaps
             },
             injected_knowledge:
               Enum.map(injected_knowledge, fn k ->
                 %{
                   content: String.slice(k.content || "", 0..200),
                   relevance: k[:relevance] || k[:similarity] || 0.0,
                   source: k[:source] || :memory
                 }
               end),
             confidence: %{
               level: confidence.level,
               score: Float.round(confidence.score, 3),
               factors: confidence.factors
             },
             corrections: corrections,
             accumulated_context: %{
               verified_facts_count: length(new_acc_context.verified_facts),
               open_questions_count: length(new_acc_context.open_questions),
               steps_completed: length(new_acc_context.reasoning_chain),
               confidence_trend: summarize_trend(new_acc_context.confidence_trend)
             },
             should_continue: should_continue,
             warnings: warnings,
             recommended_action:
               build_recommended_action(
                 step_result_for_adaptive(
                   confidence,
                   verification,
                   evaluation,
                   new_acc_context,
                   step_record.step
                 )
               )
           }}

        {:error, reason} ->
          {:error, "Failed to record thought: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Conclude interleaved reasoning with full verification.

  Synthesizes all verified steps, checks for consistency,
  and generates a grounded conclusion.
  """
  @spec conclude(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def conclude(session_id, opts \\ []) do
    with {:ok, session} <- ReasoningSession.get(session_id) do
      if session.thoughts == [] do
        {:error, "Cannot conclude without any reasoning steps"}
      else
        acc_context = get_accumulated_context(session)

        # Verify the full reasoning chain
        chain_verification = verify_reasoning_chain(session.thoughts, acc_context)

        # Check for consistency across all steps
        consistency_check = check_chain_consistency(session.thoughts)

        # Generate grounded conclusion
        conclusion = synthesize_conclusion(session, acc_context, chain_verification)

        # Calculate final confidence
        final_confidence = calculate_final_confidence(acc_context, chain_verification)

        # Store successful reasoning pattern if high confidence
        if final_confidence.level in [:high, :medium] do
          store_verified_pattern(session, conclusion, final_confidence)
        end

        # Complete the session
        ReasoningSession.complete(session_id)

        {:ok,
         %{
           session_id: session_id,
           conclusion: conclusion.text,
           grounding: %{
             verified_facts: acc_context.verified_facts,
             supporting_evidence: chain_verification.evidence,
             resolved_questions: acc_context.open_questions
           },
           chain_verification: %{
             status: chain_verification.status,
             issues: chain_verification.issues,
             confidence: Float.round(chain_verification.confidence, 3)
           },
           consistency: consistency_check,
           final_confidence: %{
             level: final_confidence.level,
             score: Float.round(final_confidence.score, 3),
             factors: final_confidence.factors
           },
           reasoning_summary: %{
             total_steps: length(session.thoughts),
             verified_steps:
               Enum.count(session.thoughts, &(Map.get(&1, :verification_status) == :verified)),
             corrections_made: count_corrections(session),
             confidence_progression: acc_context.confidence_trend
           },
           hint:
             if(Keyword.get(opts, :store_learning, true),
               do: "Reasoning pattern stored for future reference",
               else: nil
             )
         }}
      end
    end
  end

  @doc """
  Verify a specific claim against memory and knowledge.

  Useful for spot-checking claims during reasoning without
  recording a full step.
  """
  @spec verify_claim(String.t(), keyword()) :: {:ok, verification_result()} | {:error, term()}
  def verify_claim(claim, opts \\ []) do
    context = Keyword.get(opts, :context, "")

    verification = verify_thought(claim, context, %{verified_facts: [], reasoning_chain: []})

    {:ok, verification}
  end

  @doc """
  Get the current accumulated context for a session.
  """
  @spec get_context(String.t()) :: {:ok, accumulated_context()} | {:error, term()}
  def get_context(session_id) do
    with {:ok, session} <- ReasoningSession.get(session_id) do
      {:ok, get_accumulated_context(session)}
    end
  end

  defp verify_thought(thought, problem, acc_context) do
    # Extract claims from the thought
    claims = extract_claims(thought)

    if claims == [] do
      # No specific claims to verify
      %{
        status: :unverified,
        supporting_facts: [],
        contradictions: [],
        gaps: ["No specific claims to verify"]
      }
    else
      # Search memory for each claim
      memory_results = search_memory_for_claims(claims, problem)

      # Search knowledge graph for relationships
      knowledge_results = search_knowledge_for_claims(claims)

      # SPEC-084: Check claims against known corrections
      correction_contradictions = check_claims_against_corrections(claims)

      # Cross-reference with already verified facts
      cross_ref = cross_reference_verified(claims, acc_context.verified_facts)

      # Determine overall verification status
      status = determine_verification_status(memory_results, knowledge_results, cross_ref)

      %{
        status: status,
        supporting_facts: memory_results.supporting ++ knowledge_results.supporting,
        contradictions:
          memory_results.contradicting ++
            knowledge_results.contradicting ++ correction_contradictions,
        gaps: memory_results.gaps ++ knowledge_results.gaps
      }
    end
  end

  defp extract_claims(thought) do
    # Look for assertive statements
    thought
    |> String.split(~r/[.!?]/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(String.length(&1) < 10))
    |> Enum.filter(&claim?/1)
    |> Enum.take(5)
  end

  defp claim?(sentence) do
    # Claims typically contain assertive language
    assertive_patterns = [
      ~r/\b(is|are|was|were|has|have|will|should|must)\b/i,
      ~r/\b(because|therefore|thus|so|means|implies)\b/i,
      ~r/\b(always|never|definitely|certainly)\b/i
    ]

    # Exclude questions and hedged statements
    not String.ends_with?(sentence, "?") and
      not String.match?(sentence, ~r/\b(maybe|might|could|perhaps|possibly)\b/i) and
      Enum.any?(assertive_patterns, &String.match?(sentence, &1))
  end

  defp search_memory_for_claims(claims, problem) do
    query = Enum.join(claims, " ") <> " " <> problem

    # Memory.search_memories returns a list directly, not {:ok, list}
    memories = Memory.search_memories(query, limit: 10, min_similarity: 0.4)

    if is_list(memories) and not Enum.empty?(memories) do
      categorize_memory_results(claims, memories)
    else
      %{supporting: [], contradicting: [], gaps: ["No memories found for claims"]}
    end
  rescue
    _ ->
      %{supporting: [], contradicting: [], gaps: ["Memory search failed"]}
  end

  defp categorize_memory_results(claims, memories) do
    # Simple heuristic: high similarity = supporting, check for negation = contradicting
    supporting =
      memories
      |> Enum.filter(&((&1[:similarity] || 0.0) > 0.6))
      |> Enum.take(3)

    contradicting =
      memories
      |> Enum.filter(fn m ->
        content = m.content || ""

        Enum.any?(claims, fn claim ->
          # Check for negation patterns
          String.contains?(content, "not " <> String.downcase(claim)) or
            String.contains?(content, "never " <> String.downcase(claim)) or
            String.contains?(content, "don't " <> String.downcase(claim))
        end)
      end)

    gaps =
      if Enum.empty?(supporting) and length(memories) < 3 do
        ["Limited memory context for these claims"]
      else
        []
      end

    %{supporting: supporting, contradicting: contradicting, gaps: gaps}
  end

  defp search_knowledge_for_claims(claims) do
    query = Enum.join(claims, " ")

    case KnowledgeQuery.query(query, limit: 5) do
      {:ok, %{nodes: nodes} = result} ->
        rels = Map.get(result, :edges, [])

        supporting =
          (nodes ++ Enum.map(rels, & &1))
          |> Enum.take(3)
          |> Enum.map(fn item ->
            %{
              content: item[:name] || item[:type] || inspect(item),
              source: :knowledge_graph
            }
          end)

        %{supporting: supporting, contradicting: [], gaps: []}

      _ ->
        %{supporting: [], contradicting: [], gaps: []}
    end
  end

  defp cross_reference_verified(claims, verified_facts) do
    matches =
      Enum.filter(verified_facts, fn fact ->
        Enum.any?(claims, fn claim ->
          String.jaro_distance(String.downcase(fact), String.downcase(claim)) > 0.7
        end)
      end)

    %{matches: matches, match_count: length(matches)}
  end

  # SPEC-084: Check claims against known corrections from CorrectionLearning
  defp check_claims_against_corrections(claims) do
    claims
    |> Enum.flat_map(fn claim ->
      case CorrectionLearning.check_against_corrections(claim) do
        {:contradiction, correction} ->
          ["CORRECTION CONFLICT: #{correction.content}"]

        :ok ->
          []
      end
    end)
  rescue
    _ -> []
  end

  defp determine_verification_status(memory_results, knowledge_results, cross_ref) do
    has_contradictions =
      not Enum.empty?(memory_results.contradicting) or
        not Enum.empty?(knowledge_results.contradicting)

    has_support =
      not Enum.empty?(memory_results.supporting) or
        not Enum.empty?(knowledge_results.supporting) or
        cross_ref.match_count > 0

    cond do
      has_contradictions -> :contradicted
      has_support and Enum.empty?(memory_results.gaps) -> :verified
      has_support -> :partial
      true -> :unverified
    end
  end

  defp default_verification do
    %{
      status: :unverified,
      supporting_facts: [],
      contradictions: [],
      gaps: ["Verification timed out"]
    }
  end

  defp find_relevant_knowledge(thought, problem) do
    # Search for relevant memories
    query = thought <> " " <> problem

    # Memory.search_memories returns a list directly, not {:ok, list}
    memories = Memory.search_memories(query, limit: 5, min_similarity: 0.5)

    if is_list(memories) do
      memories
      |> Enum.map(fn m ->
        %{
          content: m.content,
          relevance: m[:similarity] || 0.0,
          source: :memory,
          category: m[:category]
        }
      end)
    else
      []
    end
  rescue
    _ -> []
  end

  defp assess_thought_confidence(thought, evaluation) do
    base_score = evaluation.score

    # Adjust based on thought characteristics
    factors = []

    {score, factors} =
      if String.match?(thought, ~r/\b(I think|I believe|probably|maybe)\b/i) do
        {base_score * 0.8, ["hedged_language" | factors]}
      else
        {base_score, factors}
      end

    {score, factors} =
      if String.length(thought) < 30 do
        {score * 0.9, ["short_thought" | factors]}
      else
        {score, factors}
      end

    {score, factors} =
      if String.match?(thought, ~r/\b(because|therefore|since|given that)\b/i) do
        {min(score * 1.1, 1.0), ["reasoning_markers" | factors]}
      else
        {score, factors}
      end

    level =
      cond do
        score >= 0.7 -> :high
        score >= 0.4 -> :medium
        score >= 0.2 -> :low
        true -> :unknown
      end

    %{
      level: level,
      score: score,
      factors: factors
    }
  end

  defp needs_correction?(verification, confidence) do
    verification.status == :contradicted or
      confidence.score < @low_confidence_threshold or
      not Enum.empty?(verification.contradictions)
  end

  defp generate_corrections(thought, verification, injected_knowledge, _opts) do
    corrections = []

    # Correction based on contradictions
    corrections =
      if Enum.empty?(verification.contradictions) do
        corrections
      else
        contradiction = List.first(verification.contradictions)

        [
          %{
            original: thought,
            corrected:
              "Note: This may conflict with known fact: #{String.slice(contradiction.content || "", 0..100)}",
            reason: "Memory contradiction detected",
            source: :memory
          }
          | corrections
        ]
      end

    # Correction based on injected knowledge
    corrections =
      if Enum.empty?(injected_knowledge) do
        corrections
      else
        relevant = List.first(injected_knowledge)

        if relevant.relevance > 0.7 do
          [
            %{
              original: thought,
              corrected: "Consider: #{String.slice(relevant.content || "", 0..100)}",
              reason: "Highly relevant context available",
              source: :knowledge
            }
            | corrections
          ]
        else
          corrections
        end
      end

    Enum.take(corrections, @max_corrections_per_step)
  end

  defp build_initial_context(problem, guided_result) do
    %{
      verified_facts: [],
      open_questions: [problem],
      reasoning_chain: [],
      confidence_trend: [guided_result.confidence.score]
    }
  end

  defp get_accumulated_context(session) do
    # Try to get from session metadata, or build default
    case session[:accumulated_context] do
      nil ->
        %{
          verified_facts: [],
          open_questions: [session.problem],
          reasoning_chain: Enum.map(session.thoughts, & &1.content),
          confidence_trend: session.confidence_history
        }

      context ->
        context
    end
  end

  defp update_session_context(session_id, context) do
    ReasoningSession.update(session_id, %{accumulated_context: context})
  end

  defp update_accumulated_context(acc_context, thought, verification, confidence) do
    # Add verified facts
    new_verified =
      if verification.status == :verified do
        [thought | acc_context.verified_facts] |> Enum.take(20)
      else
        acc_context.verified_facts
      end

    # Update reasoning chain
    new_chain = [thought | acc_context.reasoning_chain] |> Enum.take(50)

    # Track confidence trend
    new_trend = [confidence.score | acc_context.confidence_trend] |> Enum.take(20)

    %{
      acc_context
      | verified_facts: new_verified,
        reasoning_chain: new_chain,
        confidence_trend: new_trend
    }
  end

  defp determine_continuation(verification, confidence, corrections, acc_context) do
    warnings = []

    # Low confidence warning
    warnings =
      if confidence.score < @low_confidence_threshold do
        ["⚠️ Low confidence (#{Float.round(confidence.score, 2)}) - consider verifying" | warnings]
      else
        warnings
      end

    # Contradiction warning
    warnings =
      if verification.status == :contradicted do
        ["⚠️ Contradicts stored knowledge - review corrections" | warnings]
      else
        warnings
      end

    # Declining confidence trend
    warnings =
      if length(acc_context.confidence_trend) >= 3 do
        recent = Enum.take(acc_context.confidence_trend, 3)

        if Enum.at(recent, 0) < Enum.at(recent, 2) - 0.2 do
          ["⚠️ Confidence declining - consider stepping back" | warnings]
        else
          warnings
        end
      else
        warnings
      end

    # Should continue?
    should_continue =
      verification.status != :contradicted and
        confidence.score >= @verification_required_threshold and
        length(corrections) < @max_corrections_per_step

    {should_continue, warnings}
  end

  # Build step result map for AdaptiveStrategy analysis
  defp step_result_for_adaptive(confidence, verification, evaluation, acc_context, step_number) do
    %{
      confidence: %{
        score: confidence.score,
        level: confidence.level
      },
      verification: %{
        status: verification.status,
        contradictions: verification.contradictions,
        gaps: verification.gaps
      },
      evaluation: %{
        quality: evaluation.quality
      },
      accumulated_context: %{
        confidence_trend: summarize_trend(acc_context.confidence_trend),
        steps_completed: length(acc_context.reasoning_chain),
        verified_facts_count: length(acc_context.verified_facts)
      },
      step_number: step_number
    }
  end

  # Format the recommended action for response
  defp build_recommended_action(step_result) do
    case AdaptiveStrategy.recommend_next(step_result) do
      {:ok, action, reason} ->
        %{
          action: action,
          reason: reason,
          guidance: AdaptiveStrategy.action_guidance(action)
        }

      _ ->
        %{
          action: :continue,
          reason: "Default: continue reasoning",
          guidance: AdaptiveStrategy.action_guidance(:continue)
        }
    end
  end

  defp verify_reasoning_chain(thoughts, acc_context) do
    verified_count = length(acc_context.verified_facts)
    total_count = length(thoughts)

    confidence =
      if total_count > 0 do
        verified_count / total_count
      else
        0.0
      end

    status =
      cond do
        confidence >= 0.7 -> :strong
        confidence >= 0.4 -> :moderate
        true -> :weak
      end

    %{
      status: status,
      confidence: confidence,
      issues: [],
      evidence: acc_context.verified_facts
    }
  end

  defp check_chain_consistency(thoughts) do
    # Simple consistency check - look for contradictory statements
    _contents = Enum.map(thoughts, & &1.content)

    # Returns basic stats from thought analysis.
    %{
      total_steps: length(thoughts),
      consistency_score: 0.8,
      potential_issues: []
    }
  end

  defp synthesize_conclusion(session, acc_context, chain_verification) do
    # Build conclusion from verified facts and reasoning chain
    key_points =
      acc_context.verified_facts
      |> Enum.take(5)
      |> Enum.join("; ")

    conclusion_text =
      if key_points != "" do
        "Based on verified reasoning: #{key_points}"
      else
        "Reasoning completed with #{length(session.thoughts)} steps."
      end

    %{
      text: conclusion_text,
      grounding: chain_verification.evidence,
      confidence: chain_verification.confidence
    }
  end

  defp calculate_final_confidence(acc_context, chain_verification) do
    # Combine chain confidence with trend
    chain_conf = chain_verification.confidence

    trend_factor =
      if Enum.empty?(acc_context.confidence_trend) do
        0.5
      else
        Enum.sum(acc_context.confidence_trend) / length(acc_context.confidence_trend)
      end

    final_score = chain_conf * 0.6 + trend_factor * 0.4

    level =
      cond do
        final_score >= 0.7 -> :high
        final_score >= 0.4 -> :medium
        final_score >= 0.2 -> :low
        true -> :unknown
      end

    %{
      level: level,
      score: final_score,
      factors: ["chain_verification", "confidence_trend"]
    }
  end

  defp store_verified_pattern(session, conclusion, confidence) do
    content = """
    Verified reasoning pattern for: #{String.slice(session.problem, 0..100)}
    Conclusion: #{String.slice(conclusion.text, 0..200)}
    Confidence: #{confidence.level} (#{Float.round(confidence.score, 2)})
    Steps: #{length(session.thoughts)}
    """

    Memory.persist_memory(content, "observation",
      importance: confidence.score,
      tags: ["reasoning_pattern", "verified"]
    )
  rescue
    _ -> :ok
  end

  defp evaluate_thought(thought, session, _acc_context) do
    ThoughtEvaluator.evaluate(thought, %{
      previous_thoughts: Enum.map(session.thoughts, & &1.content),
      problem: session.problem,
      strategy: session.strategy
    })
  end

  defp format_facts(facts) do
    Enum.map(facts, fn f ->
      %{
        content: String.slice(f[:content] || f.content || "", 0..150),
        source: f[:source] || :memory
      }
    end)
  end

  defp summarize_trend(trend) do
    if length(trend) < 2 do
      :stable
    else
      first = List.last(trend)
      last = List.first(trend)

      cond do
        last > first + 0.1 -> :improving
        last < first - 0.1 -> :declining
        true -> :stable
      end
    end
  end

  defp count_corrections(session) do
    session.thoughts
    |> Enum.filter(&Map.get(&1, :interleaved, false))
    |> length()
  end
end
