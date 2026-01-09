defmodule Mimo.Cognitive.Amplifier do
  @moduledoc """
  Cognitive Amplifier - Makes any LLM think deeper.

  This is the main entry point for cognitive amplification. It orchestrates
  the pipeline of amplification stages to force deeper, more rigorous thinking.

  ## The Nano-Chip Analogy

  Like a neural implant that enhances human cognition, the Amplifier enhances
  LLM reasoning by:

  1. **Forcing decomposition** - No direct answers, break it down first
  2. **Generating challenges** - Devil's advocate, counter-arguments
  3. **Rotating perspectives** - Consider from multiple angles
  4. **Validating coherence** - Catch contradictions and circular reasoning
  5. **Enforcing synthesis** - Integrate all threads into grounded conclusion

  ## For Non-Thinking Models

  Gives them the structured thinking process they lack natively.
  Forces step-by-step reasoning externally.

  ## For Thinking Models

  Adds grounding, persistence, and verification that internal
  thinking lacks. Stacks additional oversight on top.

  ## Usage

      # Start amplified reasoning
      {:ok, session} = Amplifier.start("How do I fix this auth bug?", :deep)

      # Each think step is verified and enriched
      {:ok, result} = Amplifier.think(session.id, "First, I'll check the JWT config")

      # Get next required action (challenge, perspective, etc.)
      {:ok, action} = Amplifier.next_action(session.id)

      # Complete with forced synthesis
      {:ok, conclusion} = Amplifier.conclude(session.id)

  ## Amplification Levels

  - `:minimal` - Pass-through, no forcing
  - `:standard` - Decomposition + basic challenges
  - `:deep` - Full pipeline with perspectives and coherence
  - `:exhaustive` - Maximum amplification, all checks enforced
  - `:adaptive` - Auto-select based on problem complexity

  ## Integration with Neuro+ML

  The Amplifier leverages the neuro+ML infrastructure:
  - HebbianLearner - Strengthens effective reasoning patterns
  - AttentionLearner - Learns which amplifications matter most
  - SpreadingActivation - Finds relevant past reasoning
  - EdgePredictor - Identifies blind spots
  - CorrectionLearning - Surfaces past mistakes
  """

  require Logger

  alias Mimo.Cognitive.Amplifier.{
    AmplificationLevel,
    AmplificationSession,
    ChallengeGenerator,
    ClaimVerifier,
    CoherenceValidator,
    ConfidenceGapAnalyzer,
    PerspectiveRotator,
    SynthesisEnforcer,
    ThinkingForcer
  }

  alias Mimo.Cognitive.{ProblemAnalyzer, ReasoningSession, ThoughtEvaluator}

  @type level :: :minimal | :standard | :deep | :exhaustive | :adaptive
  @type stage :: :init | :decomposition | :thinking | :challenging | :perspectives | :synthesis

  @type amplified_result :: %{
          session_id: String.t(),
          stage: stage(),
          content: map(),
          next_action: map() | nil,
          blocking: boolean()
        }

  @doc """
  Start an amplified reasoning session.

  Analyzes the problem, selects amplification level (if adaptive),
  and initializes the session with forcing prompts.
  """
  @spec start(String.t(), level(), keyword()) :: {:ok, amplified_result()} | {:error, term()}
  def start(problem, level \\ :adaptive, opts \\ []) do
    if problem == "" or is_nil(problem) do
      {:error, "Problem is required to start amplified reasoning"}
    else
      # Determine actual level
      actual_level = resolve_level(level, problem)

      # Create session
      session = AmplificationSession.create(problem, actual_level, opts)

      # Check if decomposition is required
      forcing = ThinkingForcer.force(problem, actual_level, opts)

      if forcing.required do
        # Store decomposition requirement
        AmplificationSession.record_decomposition(session.id, forcing.prompts)
        AmplificationSession.set_blocking(session.id, "decomposition_required")

        {:ok,
         %{
           session_id: session.id,
           stage: :decomposition,
           level: actual_level.name,
           content: %{
             problem: problem,
             forcing_prompts: forcing.prompts,
             strategies: forcing.strategies_used
           },
           next_action: %{
             type: :respond_to_decomposition,
             prompts: forcing.prompts,
             instruction: "Address each decomposition prompt before proceeding."
           },
           blocking: true
         }}
      else
        {:ok,
         %{
           session_id: session.id,
           stage: :thinking,
           level: actual_level.name,
           content: %{
             problem: problem,
             ready_to_think: true
           },
           next_action: %{
             type: :think,
             instruction: "Begin your reasoning with the first thought."
           },
           blocking: false
         }}
      end
    end
  end

  @doc """
  Submit a decomposition response.

  Validates the response and advances to thinking stage if complete.

  If the response is comprehensive (addresses multiple aspects), marks all
  decomposition prompts as answered. This provides better UX than requiring
  separate responses for each prompt.
  """
  @spec submit_decomposition(String.t(), String.t(), non_neg_integer()) ::
          {:ok, amplified_result()} | {:error, term()}
  def submit_decomposition(session_id, response, index \\ 0) do
    with {:ok, state} <- AmplificationSession.get_state(session_id) do
      strategy =
        if index < length(state.decomposition) do
          # Infer strategy from prompt (simplified)
          :sub_questions
        else
          :sub_questions
        end

      case ThinkingForcer.validate_decomposition(response, strategy) do
        {:valid, items} ->
          # Check if response is comprehensive enough to satisfy all prompts
          # A response with 300+ chars or 5+ extracted items covers decomposition aspects
          comprehensive = String.length(response) >= 300 or length(items) >= 5

          if comprehensive do
            # Mark ALL decomposition prompts as answered
            num_prompts = length(state.decomposition)

            if num_prompts > 0 do
              Enum.each(0..(num_prompts - 1)//1, fn i ->
                AmplificationSession.mark_decomposition_answered(session_id, i)
              end)
            end
          else
            AmplificationSession.mark_decomposition_answered(session_id, index)
          end

          if comprehensive or AmplificationSession.decomposition_complete?(session_id) do
            AmplificationSession.clear_blocking(session_id)
            AmplificationSession.update_state(session_id, %{stage: :thinking})

            {:ok,
             %{
               session_id: session_id,
               stage: :thinking,
               content: %{
                 decomposition_complete: true,
                 items_extracted: items
               },
               next_action: %{
                 type: :think,
                 instruction: "Decomposition complete. Begin reasoning."
               },
               blocking: false
             }}
          else
            remaining = length(state.decomposition) - index - 1

            {:ok,
             %{
               session_id: session_id,
               stage: :decomposition,
               content: %{
                 items_extracted: items,
                 remaining: remaining
               },
               next_action: %{
                 type: :respond_to_decomposition,
                 prompts: [Enum.at(state.decomposition, index + 1)],
                 instruction: "Address the next decomposition prompt."
               },
               blocking: true
             }}
          end

        {:invalid, reason} ->
          {:ok,
           %{
             session_id: session_id,
             stage: :decomposition,
             content: %{
               validation_failed: true,
               reason: reason
             },
             next_action: %{
               type: :revise_decomposition,
               instruction: reason
             },
             blocking: true
           }}
      end
    end
  end

  @doc """
  Add a thinking step with full amplification.

  Each thought is:
  1. Evaluated for quality
  2. Checked for coherence with previous thoughts
  3. Challenged if appropriate
  4. Enriched with relevant context
  """
  @spec think(String.t(), String.t(), keyword()) :: {:ok, amplified_result()} | {:error, term()}
  def think(session_id, thought, opts \\ []) do
    with {:ok, session} <- ReasoningSession.get(session_id),
         {:ok, state} <- AmplificationSession.get_state(session_id) do
      level = state.level

      # Check if blocked - return structured guidance for agents
      case AmplificationSession.blocked?(session_id) do
        {true, reason} ->
          {:error,
           %{
             blocked: true,
             reason: reason,
             required_action: build_required_action(reason, session_id),
             do_not: ["amplify_think", "amplify_challenge", "amplify_conclude"],
             hint: "You must address the blocking issue first. Use the required_action command."
           }}

        {false, _} ->
          process_thought(session_id, session, state, level, thought, opts)
      end
    end
  end

  @doc """
  Get the next required action for the session.

  Based on current state and amplification level, determines what
  must happen next (challenge, perspective, synthesis, etc.)
  """
  @spec next_action(String.t()) :: {:ok, map()} | {:error, term()}
  def next_action(session_id) do
    with {:ok, session} <- ReasoningSession.get(session_id),
         {:ok, state} <- AmplificationSession.get_state(session_id) do
      level = state.level

      # Priority order of checks
      cond do
        # Check for blocking issues
        match?({true, _}, AmplificationSession.blocked?(session_id)) ->
          {true, reason} = AmplificationSession.blocked?(session_id)
          {:ok, %{type: :blocked, reason: reason, blocking: true}}

        # Check for pending must-address challenges
        (pending = AmplificationSession.pending_must_address(session_id)) != [] ->
          {:ok,
           %{
             type: :address_challenge,
             challenges: pending,
             instruction: "Address these challenges before continuing.",
             blocking: true
           }}

        # Check for coherence issues
        AmplificationSession.has_blocking_coherence_issues?(session_id) ->
          {:ok,
           %{
             type: :resolve_coherence,
             instruction: "Resolve coherence issues before continuing.",
             blocking: true
           }}

        # Check perspective coverage
        not perspective_coverage_met?(session_id, level) ->
          covered =
            state.perspectives
            |> Enum.filter(& &1.considered)
            |> Enum.map(& &1.name)

          case PerspectiveRotator.next_perspective(session.problem, covered) do
            {:ok, perspective} ->
              {:ok,
               %{
                 type: :consider_perspective,
                 perspective: perspective,
                 prompt: PerspectiveRotator.format_rotation_prompt(perspective),
                 blocking: AmplificationLevel.enabled?(level, :perspectives)
               }}

            :all_covered ->
              {:ok, %{type: :continue, instruction: "Continue reasoning."}}
          end

        # Check if ready for synthesis
        length(session.thoughts) >= level.min_thinking_steps ->
          {:ok,
           %{
             type: :synthesize,
             instruction: "Sufficient thinking completed. Ready to synthesize.",
             blocking: false
           }}

        true ->
          {:ok, %{type: :continue, instruction: "Continue reasoning."}}
      end
    end
  end

  @doc """
  Address a challenge.
  """
  @spec address_challenge(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def address_challenge(session_id, challenge_id, response) do
    with {:ok, state} <- AmplificationSession.get_state(session_id) do
      # Validate response has sufficient content (>30 chars = meaningful response)
      if String.length(response) > 30 do
        AmplificationSession.address_challenge(session_id, challenge_id, response)

        # BUG FIX: Also resolve coherence issues when challenge is addressed
        # The challenge may have been generated from a coherence issue
        AmplificationSession.resolve_all_coherence_issues(session_id)

        # Clear blocking if this was a coherence issue
        if state.blocking_reason in ["coherence_issue", "must_address_challenges"] do
          # Check if there are still pending must-address challenges
          if AmplificationSession.pending_must_address(session_id) == [] do
            AmplificationSession.clear_blocking(session_id)
          end
        end

        {:ok, %{addressed: true, challenge_id: challenge_id}}
      else
        {:error, "Response too brief. Please address the challenge more thoroughly."}
      end
    end
  end

  @doc """
  Record perspective consideration.
  """
  @spec record_perspective(String.t(), atom(), [String.t()]) ::
          {:ok, map()} | {:error, term()}
  def record_perspective(session_id, perspective_name, insights) do
    AmplificationSession.record_perspective_insights(session_id, perspective_name, insights)
    {:ok, %{perspective: perspective_name, insights_recorded: length(insights)}}
  end

  @doc """
  Conclude with forced synthesis.
  """
  @spec conclude(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def conclude(session_id, opts \\ []) do
    with {:ok, session} <- ReasoningSession.get(session_id),
         {:ok, state} <- AmplificationSession.get_state(session_id) do
      level = state.level

      # SPEC-092: Check source verification
      {:ok, verification} = AmplificationSession.check_source_verification(session_id)

      # Check prerequisites
      cond do
        # Check minimum steps
        length(session.thoughts) < level.min_thinking_steps ->
          {:error,
           "Insufficient thinking. Need at least #{level.min_thinking_steps} steps, have #{length(session.thoughts)}."}

        # Check blocking issues - return structured guidance
        match?({true, _}, AmplificationSession.blocked?(session_id)) ->
          {true, reason} = AmplificationSession.blocked?(session_id)

          {:error,
           %{
             blocked: true,
             reason: reason,
             required_action: build_required_action(reason, session_id),
             do_not: ["amplify_conclude"],
             hint: "Cannot conclude while session is blocked. Address the blocking issue first."
           }}

        # Check pending challenges
        AmplificationSession.pending_must_address(session_id) != [] ->
          {:error, "Cannot conclude: unaddressed must-address challenges remain."}

        # SPEC-092: Check if referenced sources were verified (warn, don't block)
        verification.unverified != [] and not Keyword.get(opts, :skip_source_check, false) ->
          {:error,
           %{
             blocked: false,
             reason: "unverified_sources",
             unverified_sources: verification.unverified,
             hint:
               "Warning: The problem references documents that weren't read during reasoning. " <>
                 "This may lead to hallucination. Use skip_source_check: true to override.",
             verification_rate: verification.verification_rate,
             action: "Read the unverified sources or use skip_source_check: true to proceed"
           }}

        true ->
          do_conclude(session_id, session, state, level, opts)
      end
    end
  end

  # Build the exact command the agent should use to address the blocking issue
  defp build_required_action(reason, session_id) do
    case reason do
      "decomposition_required" ->
        "reason operation=amplify_decomposition session_id=\"#{session_id}\" response=\"[Your decomposition response here - address the forcing prompts shown in the start response]\""

      "must_address_challenges" ->
        "reason operation=amplify_challenge session_id=\"#{session_id}\" challenge_id=\"[challenge_id from pending challenges]\" response=\"[Your response addressing the challenge]\""

      "coherence_issue" ->
        "reason operation=amplify_think session_id=\"#{session_id}\" thought=\"[Clarify or resolve the coherence issue]\""

      _ ->
        "reason operation=next_action session_id=\"#{session_id}\" # Check what action is required"
    end
  end

  defp resolve_level(:adaptive, problem) do
    complexity = ProblemAnalyzer.estimate_complexity(problem)
    AmplificationLevel.for_complexity(complexity)
  end

  defp resolve_level(level_name, _problem) when is_atom(level_name) do
    AmplificationLevel.get(level_name)
  end

  defp process_thought(session_id, session, state, level, thought, _opts) do
    # Step 1: Evaluate thought quality
    evaluation =
      ThoughtEvaluator.evaluate(thought, %{
        previous_thoughts: Enum.map(session.thoughts, & &1.content),
        problem: session.problem,
        strategy: session.strategy
      })

    # Step 1.5: SPEC-092 Semantic Claim Verification
    # Verify any verifiable claims in the thought against actual sources
    claim_verification = ClaimVerifier.verify_thought(thought)

    # Log verification results if any claims were found
    if claim_verification.summary.total_claims > 0 do
      Logger.debug(
        "[Amplifier] Claim verification: #{claim_verification.summary.verified}/#{claim_verification.summary.total_claims} verified"
      )
    end

    # Step 1.6: SPEC-092 Confidence-Verification Gap Analysis
    # Detect when high confidence language doesn't match verification evidence
    confidence_gap = ConfidenceGapAnalyzer.analyze(thought, claim_verification.summary)

    if confidence_gap.gap_detected do
      Logger.debug(
        "[Amplifier] Confidence gap detected: #{confidence_gap.risk_level} - #{confidence_gap.reason}"
      )
    end

    # Step 2: Check coherence
    previous_contents = Enum.map(session.thoughts, & &1.content)
    coherence = CoherenceValidator.validate_thought(thought, previous_contents)

    # Step 3: Generate challenges if enabled (with session-level cap)
    challenges =
      if AmplificationLevel.enabled?(level, :challenges) do
        # Check current must-address count to avoid overwhelming
        current_must_address = length(AmplificationSession.pending_must_address(session_id))
        max_allowed = level.max_must_address

        if current_must_address >= max_allowed do
          # Already at cap, skip generating more must-address challenges
          Logger.debug(
            "[Amplifier] Skipping challenge generation: at must-address cap (#{current_must_address}/#{max_allowed})"
          )

          []
        else
          context = %{problem: session.problem, step: length(session.thoughts) + 1}
          # Reduce max_challenges based on remaining budget
          remaining_budget = max_allowed - current_must_address

          max_for_this_step =
            min(AmplificationLevel.required_count(level, :challenges), remaining_budget)

          ChallengeGenerator.generate(thought, context, max_challenges: max_for_this_step)
        end
      else
        []
      end

    # Store challenges
    Enum.each(challenges, fn c ->
      AmplificationSession.add_challenge(session_id, c)
    end)

    # Step 4: Record thought in base session
    thought_record = %{
      content: thought,
      step: length(session.thoughts) + 1,
      evaluation: evaluation.quality,
      confidence: evaluation.score,
      branch_id: session.current_branch_id
    }

    ReasoningSession.add_thought(session_id, thought_record)

    # Step 5: Check for coherence issues
    case coherence do
      {:issues, issues} ->
        Enum.each(issues, &AmplificationSession.record_coherence_issue(session_id, &1))

        if Enum.any?(issues, &(&1.severity == :major)) do
          AmplificationSession.set_blocking(session_id, "coherence_issue")
        end

      _ ->
        :ok
    end

    # Step 6: Determine blocking state
    must_address = Enum.filter(challenges, &(&1.severity == :must_address))
    blocking = must_address != [] or match?({:issues, _}, coherence)

    if blocking and must_address != [] do
      AmplificationSession.set_blocking(session_id, "must_address_challenges")
    end

    # Build result
    {:ok,
     %{
       session_id: session_id,
       stage: state.stage,
       step_number: thought_record.step,
       content: %{
         evaluation: %{
           quality: evaluation.quality,
           score: evaluation.score,
           feedback: evaluation.feedback
         },
         coherence:
           case coherence do
             {:ok, _} -> :coherent
             {:issues, issues} -> %{issues: length(issues)}
           end,
         # SPEC-092: Include semantic claim verification results
         claim_verification:
           if claim_verification.summary.total_claims > 0 do
             %{
               total_claims: claim_verification.summary.total_claims,
               verified: claim_verification.summary.verified,
               failed: claim_verification.summary.failed,
               verification_rate: claim_verification.summary.verification_rate,
               unverified_claims:
                 claim_verification.results
                 |> Enum.reject(& &1.verified)
                 |> Enum.map(fn r -> %{claim: r.claim.raw_match, reason: r.evidence} end)
             }
           else
             nil
           end,
         # SPEC-092: Include confidence-verification gap analysis
         confidence_gap:
           if confidence_gap.gap_detected do
             %{
               risk_level: confidence_gap.risk_level,
               reason: confidence_gap.reason,
               empty_trap: confidence_gap.empty_trap
             }
           else
             nil
           end,
         challenges_generated: length(challenges),
         must_address: length(must_address)
       },
       next_action: build_next_action(challenges, coherence, state),
       blocking: blocking
     }}
  end

  defp build_next_action(challenges, coherence, _state) do
    must_address = Enum.filter(challenges, &(&1.severity == :must_address))

    cond do
      must_address != [] ->
        %{
          type: :address_challenges,
          challenges: must_address,
          instruction: ChallengeGenerator.format_for_injection(must_address)
        }

      match?({:issues, _}, coherence) ->
        {:issues, issues} = coherence
        prompts = CoherenceValidator.generate_resolution_prompts(issues)

        %{
          type: :resolve_coherence,
          issues: issues,
          prompts: prompts
        }

      true ->
        %{
          type: :continue,
          instruction: "Continue with next reasoning step."
        }
    end
  end

  defp perspective_coverage_met?(session_id, level) do
    if AmplificationLevel.enabled?(level, :perspectives) do
      count = AmplificationSession.perspectives_considered_count(session_id)
      required = AmplificationLevel.required_count(level, :perspectives)
      count >= required
    else
      true
    end
  end

  defp do_conclude(session_id, session, _state, level, _opts) do
    # Run coherence validation on full chain
    coherence = CoherenceValidator.validate(session.thoughts, session.problem)

    if coherence.status == :major_issues do
      {:error,
       "Cannot conclude: major coherence issues. #{CoherenceValidator.format_issues(coherence.issues)}"}
    else
      # Prepare synthesis
      case SynthesisEnforcer.prepare(session_id) do
        {:ok, synthesis} ->
          if synthesis.ready or not AmplificationLevel.enabled?(level, :synthesis) do
            # Complete the session
            ReasoningSession.complete(session_id)

            {:ok,
             %{
               session_id: session_id,
               status: :concluded,
               synthesis: %{
                 completeness: synthesis.completeness,
                 prompt: synthesis.synthesis_prompt
               },
               coherence: %{
                 status: coherence.status,
                 issues: length(coherence.issues),
                 confidence_impact: coherence.confidence_impact
               },
               summary: %{
                 total_steps: length(session.thoughts),
                 level_used: level.name
               }
             }}
          else
            {:error,
             "Synthesis incomplete (#{Float.round(synthesis.completeness * 100, 1)}%). Missing: #{inspect(Enum.map(synthesis.missing_threads, & &1.type))}"}
          end

        {:error, reason} ->
          {:error, "Synthesis preparation failed: #{reason}"}
      end
    end
  end
end
