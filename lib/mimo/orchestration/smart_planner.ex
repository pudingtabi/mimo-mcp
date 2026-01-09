defmodule Mimo.Orchestration.SmartPlanner do
  @moduledoc """
  SPEC-2026-004: Smart Orchestrator v2 - Intelligent Tool Selection

  Connects 13 underutilized Mimo modules to create intelligent tool selection
  that learns from outcomes.

  ## Architecture

  ```
  Request → Pre-Check → Predict → Analyze → Plan → Execute → Learn
               ↓           ↓        ↓         ↓       ↓        ↓
          Correction   Active    Goal      Tools   Track   Hebbian
          Learning   Inference  Decompose         Outcome  Learning
  ```

  ## Integrated Modules

  - Pre-Check: CorrectionLearning, ErrorPredictor
  - Predict: ActiveInference, GnnPredictor, SelfDiscover, EpistemicBrain
  - Analyze: GoalDecomposer, NoveltyDetector
  - Learn: HebbianLearner, AttentionLearner, FeedbackLoop, Emergence
  """

  require Logger

  alias Mimo.ActiveInference
  alias Mimo.Autonomous.GoalDecomposer

  alias Mimo.Brain.{
    AttentionLearner,
    CorrectionLearning,
    ErrorPredictor,
    NoveltyDetector
  }

  alias Mimo.Brain.Emergence.{ABTesting, Promoter, UsageTracker}
  alias Mimo.Cognitive.{EpistemicBrain, FeedbackLoop, SelfDiscover}
  alias Mimo.NeuroSymbolic.GnnPredictor
  alias Mimo.Orchestrator

  @type plan_result :: {:ok, map()} | {:blocked, map()} | {:error, term()}
  @type tool_name :: :file | :terminal | :code | :web | :memory | :reason

  # Minimum confidence to proceed without human confirmation
  # @min_confidence 0.5  # Reserved for future use

  # Maximum tools to predict
  @max_tools 5

  @doc """
  Main entry point: Analyze task and return optimal tool plan.

  Returns:
  - `{:ok, plan}` - Plan with predicted tools
  - `{:blocked, reason}` - Action blocked by pre-check
  - `{:error, reason}` - Planning failed
  """
  @spec plan(map()) :: plan_result()
  def plan(request) do
    start_time = System.monotonic_time(:millisecond)
    description = request["description"] || ""

    Logger.info("[SmartPlanner] Planning: #{String.slice(description, 0, 50)}...")

    # Phase 0: Pre-Check (blocks bad actions)
    case pre_check(description, request) do
      {:blocked, reason} ->
        Logger.warning("[SmartPlanner] Blocked: #{inspect(reason)}")
        {:blocked, reason}

      :ok ->
        # Phase 1: Predict (what tools will we need?)
        predictions = predict(description, request)

        # Phase 2: Analyze (complexity, decomposition)
        analysis = analyze(description, predictions, request)

        # Phase 3: Build execution plan
        plan = build_plan(predictions, analysis, request)

        latency = System.monotonic_time(:millisecond) - start_time
        Logger.info("[SmartPlanner] Plan built in #{latency}ms: #{inspect(plan.tools)}")

        {:ok, Map.put(plan, :planning_latency_ms, latency)}
    end
  end

  @doc """
  Execute a plan and record outcomes for learning.
  """
  @spec execute_and_learn(map()) :: {:ok, map()} | {:error, term()}
  def execute_and_learn(plan) do
    start_time = System.monotonic_time(:millisecond)

    # Convert to orchestrator format
    steps =
      Enum.map(plan.tools, fn tool_spec ->
        %{
          tool: tool_spec.tool,
          operation: tool_spec.operation,
          args: tool_spec.args || %{}
        }
      end)

    # Execute via orchestrator
    result = Orchestrator.execute_plan(steps, timeout: 300_000)

    # Phase 5: Learn from outcome
    latency = System.monotonic_time(:millisecond) - start_time
    learn_from_outcome(plan, result, latency)

    result
  end

  # ─────────────────────────────────────────────────────────────────
  # Phase 0: Pre-Check
  # ─────────────────────────────────────────────────────────────────

  defp pre_check(description, context) do
    # Check for relevant corrections (past mistakes)
    corrections = CorrectionLearning.find_relevant_corrections(description, limit: 3)

    if length(corrections) > 0 do
      Logger.warning("[SmartPlanner] Found #{length(corrections)} relevant past corrections")
      # Don't block, but add warning to context
    end

    # Check if ErrorPredictor would block this action
    action_type = infer_action_type(description)

    if ErrorPredictor.should_block?(action_type, context) do
      {:warnings, warnings} = ErrorPredictor.analyze_before_action(action_type, context)
      critical = Enum.filter(warnings, &(&1.severity == :critical))

      {:blocked,
       %{
         reason: :error_predictor_block,
         warnings: warnings,
         critical: critical,
         suggestion: "Address critical warnings before proceeding"
       }}
    else
      :ok
    end
  rescue
    e ->
      Logger.warning("[SmartPlanner] Pre-check error: #{Exception.message(e)}")
      # Don't block on pre-check errors
      :ok
  end

  # ─────────────────────────────────────────────────────────────────
  # Phase 1: Predict
  # ─────────────────────────────────────────────────────────────────

  defp predict(description, _context) do
    predictions = %{
      active_inference: nil,
      gnn: nil,
      self_discover: nil,
      epistemic: nil
    }

    # 1. Active Inference (already learns from feedback!)
    predictions =
      case ActiveInference.infer(description) do
        {:ok, inference} ->
          %{predictions | active_inference: inference}

        _ ->
          predictions
      end

    # 2. GNN Predictor (semantic similarity)
    predictions =
      case GnnPredictor.predict_links(%{content: description}, 10) do
        {:ok, links} when is_list(links) and length(links) > 0 ->
          %{predictions | gnn: links}

        _ ->
          predictions
      end

    # 3. Self-Discover for complex tasks
    predictions =
      if complex_task?(description) do
        case SelfDiscover.discover(description, use_cache: true) do
          {:ok, discovery} ->
            %{predictions | self_discover: discovery}

          _ ->
            predictions
        end
      else
        predictions
      end

    # 4. Epistemic Brain for uncertainty
    predictions =
      case EpistemicBrain.analyze_gaps(description) do
        %{} = gaps ->
          %{predictions | epistemic: gaps}

        _ ->
          predictions
      end

    # Combine predictions into tool recommendations
    %{
      raw: predictions,
      tools: extract_tool_predictions(predictions, description),
      confidence: calculate_confidence(predictions)
    }
  rescue
    e ->
      Logger.warning("[SmartPlanner] Prediction error: #{Exception.message(e)}")
      %{raw: %{}, tools: heuristic_tools(description), confidence: 0.3}
  end

  # ─────────────────────────────────────────────────────────────────
  # Phase 2: Analyze
  # ─────────────────────────────────────────────────────────────────

  defp analyze(description, predictions, _context) do
    # Goal decomposition
    task_spec = %{description: description}

    decomposition =
      case GoalDecomposer.maybe_decompose(task_spec) do
        {:decomposed, subtasks, deps} ->
          %{type: :complex, subtasks: subtasks, dependencies: deps}

        {:simple, _} ->
          %{type: :simple, subtasks: [task_spec], dependencies: %{}}
      end

    # Novelty detection (can we reuse a pattern?)
    novelty = NoveltyDetector.classify(description, "action")

    %{
      decomposition: decomposition,
      novelty: novelty,
      complexity: if(decomposition.type == :complex, do: :high, else: :low),
      predicted_confidence: predictions.confidence
    }
  rescue
    e ->
      Logger.warning("[SmartPlanner] Analysis error: #{Exception.message(e)}")
      %{decomposition: %{type: :simple}, novelty: :new, complexity: :unknown}
  end

  # ─────────────────────────────────────────────────────────────────
  # Phase 3: Build Plan
  # ─────────────────────────────────────────────────────────────────

  defp build_plan(predictions, analysis, request) do
    # Get A/B testing suggestions
    ab_suggestions =
      case ABTesting.get_suggestions("smart_planner", request) do
        {:test, suggestions} -> suggestions
        _ -> []
      end

    # Final tool list
    tools =
      predictions.tools
      |> maybe_add_ab_suggestions(ab_suggestions)
      |> Enum.take(@max_tools)

    %{
      id: generate_plan_id(),
      description: request["description"],
      tools: tools,
      predictions: predictions.raw,
      analysis: analysis,
      confidence: predictions.confidence,
      ab_group: ABTesting.current_group(),
      created_at: DateTime.utc_now()
    }
  end

  # ─────────────────────────────────────────────────────────────────
  # Phase 5: Learn
  # ─────────────────────────────────────────────────────────────────

  defp learn_from_outcome(plan, result, latency) do
    success? = match?({:ok, _}, result)

    # 1. Hebbian Learning: Tools that fire together, wire together
    tool_ids = Enum.map(plan.tools, & &1.tool)
    emit_tool_coactivation(tool_ids)

    # 2. Attention Learning: Reinforce or punish
    signal = if success?, do: :positive, else: :negative

    context = %{
      tools: tool_ids,
      latency: latency,
      confidence: plan.confidence
    }

    AttentionLearner.feedback(signal, plan.id, context)

    # 3. Feedback Loop
    FeedbackLoop.record_outcome(:tool_execution, %{plan_id: plan.id}, %{
      success: success?,
      tools: tool_ids,
      latency: latency
    })

    # 4. A/B Testing
    ABTesting.track_outcome(success?)

    # 5. Active Inference (update surprise)
    ActiveInference.record_outcome(plan.description, %{success: success?})

    # 6. Emergence Promoter (check if pattern should be promoted)
    if success? do
      maybe_promote_pattern(plan)
    end

    # 7. Correction Learning (if failure)
    if not success? do
      CorrectionLearning.analyze_and_learn(
        "Tool sequence #{inspect(tool_ids)} failed",
        %{plan: plan}
      )
    end

    Logger.info("[SmartPlanner] Learned from #{if success?, do: "success", else: "failure"}")
  rescue
    e ->
      Logger.warning("[SmartPlanner] Learning error: #{Exception.message(e)}")
  end

  # ─────────────────────────────────────────────────────────────────
  # Helper Functions
  # ─────────────────────────────────────────────────────────────────

  defp infer_action_type(description) do
    desc = String.downcase(description)

    cond do
      String.contains?(desc, ["edit", "write", "create", "modify"]) -> :file_edit
      String.contains?(desc, ["run", "execute", "command", "terminal"]) -> :terminal_command
      String.contains?(desc, ["refactor", "restructure"]) -> :refactor
      String.contains?(desc, ["debug", "fix", "error"]) -> :debug
      String.contains?(desc, ["deploy", "release"]) -> :deploy
      String.contains?(desc, ["implement", "build", "add"]) -> :implement
      true -> :general
    end
  end

  defp complex_task?(description) do
    word_count = length(String.split(description))

    word_count > 30 or
      String.contains?(String.downcase(description), [
        "implement",
        "refactor",
        "migrate",
        "design",
        "architecture",
        "integrate",
        "multiple"
      ])
  end

  defp extract_tool_predictions(predictions, description) do
    # Start with heuristics
    tools = heuristic_tools(description)

    # Enhance with Active Inference predictions
    tools =
      if predictions.active_inference do
        needs = predictions.active_inference[:predicted_needs] || []
        inferred = Enum.flat_map(needs, &need_to_tools/1)
        Enum.uniq(tools ++ inferred)
      else
        tools
      end

    # Format as tool specs
    Enum.map(tools, fn tool ->
      %{tool: tool, operation: default_operation(tool), args: %{}}
    end)
  end

  defp heuristic_tools(description) do
    desc = String.downcase(description)

    cond do
      String.contains?(desc, ["bug", "fix", "error", "debug"]) ->
        [:reason, :code, :file]

      String.contains?(desc, ["test", "spec", "run tests"]) ->
        [:terminal]

      String.contains?(desc, ["implement", "create", "add", "build"]) ->
        [:reason, :code, :file, :terminal]

      String.contains?(desc, ["what", "how", "explain", "?"]) ->
        [:memory]

      String.contains?(desc, ["search", "find", "look for"]) ->
        [:code, :memory]

      String.contains?(desc, ["refactor", "clean", "restructure"]) ->
        [:code, :file]

      true ->
        [:reason, :memory]
    end
  end

  defp need_to_tools(:related_code), do: [:code]
  defp need_to_tools(:past_errors), do: [:memory]
  defp need_to_tools(:dependencies), do: [:code]
  defp need_to_tools(:relationships), do: [:memory]
  defp need_to_tools(:similar_experiences), do: [:memory]
  defp need_to_tools(_), do: []

  defp default_operation(:file), do: "read"
  defp default_operation(:terminal), do: "execute"
  defp default_operation(:code), do: "symbols"
  defp default_operation(:memory), do: "search"
  defp default_operation(:reason), do: "guided"
  defp default_operation(:web), do: "search"
  defp default_operation(_), do: "execute"

  defp calculate_confidence(predictions) do
    scores = []

    # Active inference confidence
    scores =
      if predictions.active_inference do
        [predictions.active_inference[:confidence] || 0.5 | scores]
      else
        scores
      end

    # GNN has predictions
    scores =
      if predictions.gnn && length(predictions.gnn) > 0 do
        [0.7 | scores]
      else
        scores
      end

    # Epistemic gaps reduce confidence
    scores =
      if predictions.epistemic && predictions.epistemic[:gap_type] == :no_knowledge do
        [0.2 | scores]
      else
        scores
      end

    if scores == [] do
      # Default low confidence
      0.3
    else
      Enum.sum(scores) / length(scores)
    end
  end

  defp maybe_add_ab_suggestions(tools, []), do: tools

  defp maybe_add_ab_suggestions(tools, suggestions) do
    # Add suggested tools that aren't already in the list
    existing = MapSet.new(tools, & &1.tool)

    new_tools =
      Enum.filter(suggestions, fn s ->
        not MapSet.member?(existing, s[:tool])
      end)

    tools ++ new_tools
  end

  defp emit_tool_coactivation(tool_ids) when length(tool_ids) < 2, do: :ok

  defp emit_tool_coactivation(tool_ids) do
    # Emit telemetry for Hebbian learning
    pairs = for t1 <- tool_ids, t2 <- tool_ids, t1 < t2, do: {t1, t2}

    :telemetry.execute(
      [:mimo, :tool, :coactivation],
      %{count: length(pairs)},
      %{pairs: pairs}
    )
  rescue
    _ -> :ok
  end

  defp maybe_promote_pattern(plan) do
    # Track usage for emergence
    pattern_id = "tool_sequence:#{Enum.map_join(plan.tools, "->", & &1.tool)}"
    UsageTracker.track_usage(pattern_id, %{description: plan.description})

    # Check if ready for promotion
    case Promoter.evaluate_for_promotion(%{
           id: pattern_id,
           type: :workflow,
           description: "Auto-discovered tool sequence",
           occurrence_count: 1,
           success_rate: 1.0,
           components: plan.tools
         }) do
      {:promote, _} ->
        Logger.info("[SmartPlanner] Pattern promoted: #{pattern_id}")

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp generate_plan_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
