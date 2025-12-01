defmodule Mimo.Tools.Dispatchers.Cognitive do
  @moduledoc """
  Cognitive operations dispatcher.

  Handles epistemic uncertainty and meta-cognitive operations:
  - assess: Evaluate confidence (Cognitive.ConfidenceAssessor.assess)
  - gaps: Detect knowledge gaps (Cognitive.GapDetector.analyze)
  - query: Full epistemic query (Cognitive.EpistemicBrain.query + CalibratedResponse)
  - can_answer: Check if topic is answerable (Cognitive.EpistemicBrain.can_answer?)
  - suggest: Get learning suggestions (Cognitive.UncertaintyTracker.suggest_learning_targets)
  - stats: Tracker statistics (Cognitive.UncertaintyTracker.stats)

  Also handles the 'think' tool operations:
  - thought: Single reasoning step
  - plan: Planning with steps
  - sequential: Sequential thinking chain
  """

  alias Mimo.Tools.Helpers

  @doc """
  Dispatch cognitive operation based on args.
  """
  def dispatch(args) do
    op = args["operation"] || "assess"

    case op do
      "assess" ->
        dispatch_assess(args)

      "gaps" ->
        dispatch_gaps(args)

      "query" ->
        dispatch_query(args)

      "can_answer" ->
        dispatch_can_answer(args)

      "suggest" ->
        dispatch_suggest(args)

      "stats" ->
        dispatch_stats()

      _ ->
        {:error,
         "Unknown cognitive operation: #{op}. Available: assess, gaps, query, can_answer, suggest, stats"}
    end
  end

  @doc """
  Dispatch think tool operations.
  """
  def dispatch_think(args) do
    op = args["operation"] || "thought"

    case op do
      "thought" ->
        Mimo.Skills.Cognition.think(args["thought"] || "")

      "plan" ->
        Mimo.Skills.Cognition.plan(args["steps"] || [])

      "sequential" ->
        Mimo.Skills.Cognition.sequential_thinking(%{
          "thought" => args["thought"] || "",
          "thoughtNumber" => args["thoughtNumber"] || 1,
          "totalThoughts" => args["totalThoughts"] || 1,
          "nextThoughtNeeded" => args["nextThoughtNeeded"] || false
        })

      _ ->
        {:error, "Unknown think operation: #{op}"}
    end
  end

  # ==========================================================================
  # PRIVATE HELPERS
  # ==========================================================================

  defp dispatch_assess(args) do
    topic = args["topic"] || ""

    if topic == "" do
      {:error, "Topic is required for assess operation"}
    else
      uncertainty = Mimo.Cognitive.ConfidenceAssessor.assess(topic)

      # Track the assessment for stats (fixes missing instrumentation)
      Mimo.Cognitive.UncertaintyTracker.record(topic, uncertainty)

      {:ok, Helpers.format_uncertainty(uncertainty)}
    end
  end

  defp dispatch_gaps(args) do
    topic = args["topic"] || ""

    if topic == "" do
      {:error, "Topic is required for gaps operation"}
    else
      gap = Mimo.Cognitive.GapDetector.analyze(topic)

      {:ok,
       %{
         topic: topic,
         gap_type: gap.gap_type,
         severity: gap.severity,
         suggestion: gap.suggestion,
         actions: gap.actions,
         details: gap.details
       }}
    end
  end

  defp dispatch_query(args) do
    topic = args["topic"] || ""

    if topic == "" do
      {:error, "Topic is required for query operation"}
    else
      {:ok, result} = Mimo.Cognitive.EpistemicBrain.query(topic)

      {:ok,
       %{
         response: result.response,
         confidence: result.uncertainty.confidence,
         score: Float.round(result.uncertainty.score, 3),
         gap_type: result.gap_analysis.gap_type,
         actions_taken: result.actions_taken,
         can_answer: result.uncertainty.confidence in [:high, :medium]
       }}
    end
  end

  defp dispatch_can_answer(args) do
    topic = args["topic"] || ""
    min_confidence_val = args["min_confidence"] || 0.4

    if topic == "" do
      {:error, "Topic is required for can_answer operation"}
    else
      # Convert numeric confidence to confidence level
      min_level =
        cond do
          min_confidence_val >= 0.7 -> :high
          min_confidence_val >= 0.4 -> :medium
          min_confidence_val >= 0.2 -> :low
          true -> :unknown
        end

      can_answer = Mimo.Cognitive.EpistemicBrain.can_answer?(topic, min_level)
      uncertainty = Mimo.Cognitive.ConfidenceAssessor.assess(topic)

      {:ok,
       %{
         topic: topic,
         can_answer: can_answer,
         confidence: uncertainty.confidence,
         score: Float.round(uncertainty.score, 3),
         recommendation: if(can_answer, do: "proceed", else: "research_needed")
       }}
    end
  end

  defp dispatch_suggest(args) do
    limit = args["limit"] || 5
    targets = Mimo.Cognitive.UncertaintyTracker.suggest_learning_targets(limit: limit)

    {:ok,
     %{
       learning_targets:
         Enum.map(targets, fn t ->
           %{
             topic: t.topic,
             priority: Float.round(t.priority, 3),
             reason: t.reason,
             suggested_action: t.suggested_action
           }
         end),
       count: length(targets)
     }}
  end

  defp dispatch_stats do
    stats = Mimo.Cognitive.UncertaintyTracker.stats()
    avg_conf = Map.get(stats, :avg_confidence) || Map.get(stats, :average_confidence) || 0.0

    {:ok,
     %{
       total_queries: stats.total_queries,
       unique_topics: stats.unique_topics,
       gaps_detected: stats.gaps_detected,
       confidence_distribution: Map.get(stats, :confidence_distribution, %{}),
       average_confidence: Float.round(avg_conf * 1.0, 3)
     }}
  end
end
