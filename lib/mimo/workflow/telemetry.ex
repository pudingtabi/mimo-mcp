defmodule Mimo.Workflow.Telemetry do
  @moduledoc """
  Telemetry module for SPEC-053/054 Workflow Orchestration.

  Provides comprehensive monitoring and observability for the workflow
  engine, including pattern prediction, execution, and model adaptation.

  ## Telemetry Events

  ### Workflow Events
  - `[:mimo, :workflow, :predict]` - Pattern prediction attempt
  - `[:mimo, :workflow, :execute]` - Workflow execution
  - `[:mimo, :workflow, :step]` - Individual step execution
  - `[:mimo, :workflow, :complete]` - Workflow completion

  ### Pattern Events
  - `[:mimo, :workflow, :pattern, :match]` - Pattern matching attempt
  - `[:mimo, :workflow, :pattern, :extract]` - Pattern extraction
  - `[:mimo, :workflow, :pattern, :cluster]` - Pattern clustering

  ### Model Adaptation Events
  - `[:mimo, :workflow, :adapt]` - Template adaptation
  - `[:mimo, :workflow, :model, :profile]` - Model profiling
  - `[:mimo, :workflow, :learning]` - Learning event recorded

  ## Usage

  Attach handlers in your application startup:

      Mimo.Workflow.Telemetry.attach()

  Or attach specific handlers:

      :telemetry.attach(
        "my-workflow-handler",
        [:mimo, :workflow, :execute],
        &MyHandler.handle_event/4,
        nil
      )

  """
  require Logger

  @events [
    # Core workflow events
    [:mimo, :workflow, :predict],
    [:mimo, :workflow, :execute],
    [:mimo, :workflow, :step],
    [:mimo, :workflow, :complete],
    
    # Pattern events
    [:mimo, :workflow, :pattern, :match],
    [:mimo, :workflow, :pattern, :extract],
    [:mimo, :workflow, :pattern, :cluster],
    
    # Model adaptation events
    [:mimo, :workflow, :adapt],
    [:mimo, :workflow, :model, :profile],
    [:mimo, :workflow, :learning],
    
    # Router events (already defined but listed for completeness)
    [:mimo, :router, :classify],
    [:mimo, :router, :suggest_workflow],
    
    # Executor events
    [:mimo, :workflow, :executor, :execute]
  ]

  @doc """
  Attach default telemetry handlers for logging.

  Logs workflow events at appropriate levels for observability.
  """
  def attach do
    :telemetry.attach_many(
      "mimo-workflow-default-handler",
      @events,
      &handle_event/4,
      nil
    )
  end

  @doc """
  Detach default telemetry handlers.
  """
  def detach do
    :telemetry.detach("mimo-workflow-default-handler")
  end

  @doc """
  Get all registered workflow telemetry events.
  """
  def events, do: @events

  @doc """
  Emit a workflow telemetry event.

  Convenience function for consistent event emission.
  """
  def emit(event_name, measurements, metadata \\ %{}) do
    :telemetry.execute(
      [:mimo, :workflow | List.wrap(event_name)],
      measurements,
      metadata
    )
  end

  # =============================================================================
  # Event Handlers
  # =============================================================================

  def handle_event([:mimo, :workflow, :predict], measurements, metadata, _config) do
    duration_ms = Map.get(measurements, :duration_us, 0) / 1000
    pattern = Map.get(metadata, :pattern_name, "unknown")
    confidence = Map.get(measurements, :confidence, 0)
    
    Logger.info(
      "Workflow prediction: pattern=#{pattern} confidence=#{Float.round(confidence, 2)} " <>
      "duration=#{Float.round(duration_ms, 1)}ms"
    )
  end

  def handle_event([:mimo, :workflow, :execute], measurements, metadata, _config) do
    duration_ms = Map.get(measurements, :duration_us, 0) / 1000
    pattern = Map.get(metadata, :pattern_name, "unknown")
    status = Map.get(metadata, :status, :unknown)
    
    log_level = if status == :ok, do: :info, else: :warning
    
    Logger.log(
      log_level,
      "Workflow execution: pattern=#{pattern} status=#{status} " <>
      "duration=#{Float.round(duration_ms, 1)}ms"
    )
  end

  def handle_event([:mimo, :workflow, :step], measurements, metadata, _config) do
    duration_ms = Map.get(measurements, :duration_us, 0) / 1000
    tool = Map.get(metadata, :tool, "unknown")
    status = Map.get(metadata, :status, :unknown)
    
    if duration_ms > 1000 do
      Logger.warning(
        "Slow workflow step: tool=#{tool} status=#{status} " <>
        "duration=#{Float.round(duration_ms, 1)}ms"
      )
    else
      Logger.debug(
        "Workflow step: tool=#{tool} status=#{status} " <>
        "duration=#{Float.round(duration_ms, 1)}ms"
      )
    end
  end

  def handle_event([:mimo, :workflow, :complete], measurements, metadata, _config) do
    total_duration_ms = Map.get(measurements, :total_duration_ms, 0)
    step_count = Map.get(measurements, :step_count, 0)
    pattern = Map.get(metadata, :pattern_name, "unknown")
    outcome = Map.get(metadata, :outcome, :unknown)
    
    Logger.info(
      "Workflow completed: pattern=#{pattern} outcome=#{outcome} " <>
      "steps=#{step_count} total_duration=#{Float.round(total_duration_ms, 1)}ms"
    )
  end

  def handle_event([:mimo, :workflow, :pattern, :match], measurements, metadata, _config) do
    candidates = Map.get(measurements, :candidate_count, 0)
    best_score = Map.get(measurements, :best_score, 0)
    query = Map.get(metadata, :query, "")
    
    Logger.debug(
      "Pattern matching: candidates=#{candidates} best_score=#{Float.round(best_score, 2)} " <>
      "query=\"#{String.slice(query, 0, 50)}...\""
    )
  end

  def handle_event([:mimo, :workflow, :pattern, :extract], measurements, metadata, _config) do
    patterns_found = Map.get(measurements, :patterns_found, 0)
    session_id = Map.get(metadata, :session_id, "unknown")
    
    Logger.info(
      "Pattern extraction: session=#{session_id} patterns_found=#{patterns_found}"
    )
  end

  def handle_event([:mimo, :workflow, :pattern, :cluster], measurements, _metadata, _config) do
    cluster_count = Map.get(measurements, :cluster_count, 0)
    pattern_count = Map.get(measurements, :pattern_count, 0)
    
    Logger.debug(
      "Pattern clustering: patterns=#{pattern_count} clusters=#{cluster_count}"
    )
  end

  def handle_event([:mimo, :workflow, :adapt], measurements, metadata, _config) do
    duration_ms = Map.get(measurements, :duration_us, 0) / 1000
    original_steps = Map.get(measurements, :original_steps, 0)
    adapted_steps = Map.get(measurements, :adapted_steps, 0)
    tier = Map.get(metadata, :tier, :unknown)
    model = Map.get(metadata, :model_id, "unknown")
    
    Logger.info(
      "Template adaptation: model=#{model} tier=#{tier} " <>
      "steps=#{original_steps}→#{adapted_steps} duration=#{Float.round(duration_ms, 1)}ms"
    )
  end

  def handle_event([:mimo, :workflow, :model, :profile], measurements, metadata, _config) do
    model = Map.get(metadata, :model_id, "unknown")
    tier = Map.get(metadata, :tier, :unknown)
    capabilities = Map.get(measurements, :capability_scores, %{})
    
    avg_capability = if map_size(capabilities) > 0 do
      sum = Enum.sum(Map.values(capabilities))
      Float.round(sum / map_size(capabilities), 2)
    else
      0
    end
    
    Logger.debug(
      "Model profiled: model=#{model} tier=#{tier} avg_capability=#{avg_capability}"
    )
  end

  def handle_event([:mimo, :workflow, :learning], measurements, metadata, _config) do
    pattern = Map.get(metadata, :pattern_name, "unknown")
    model = Map.get(metadata, :model_id, "unknown")
    outcome = Map.get(metadata, :outcome, :unknown)
    affinity_delta = Map.get(measurements, :affinity_delta, 0)
    
    Logger.debug(
      "Learning event: pattern=#{pattern} model=#{model} outcome=#{outcome} " <>
      "affinity_delta=#{Float.round(affinity_delta, 3)}"
    )
  end

  def handle_event([:mimo, :router, :classify], measurements, metadata, _config) do
    duration_ms = Map.get(measurements, :duration_us, 0) / 1000
    confidence = Map.get(measurements, :confidence, 0)
    store = Map.get(metadata, :primary_store, :unknown)
    
    if duration_ms > 10 do
      Logger.warning(
        "Slow router classification: store=#{store} confidence=#{Float.round(confidence, 2)} " <>
        "duration=#{Float.round(duration_ms, 1)}ms"
      )
    end
  end

  def handle_event([:mimo, :router, :suggest_workflow], measurements, metadata, _config) do
    duration_ms = Map.get(measurements, :duration_us, 0) / 1000
    confidence = Map.get(measurements, :confidence, 0)
    suggestion_type = Map.get(metadata, :suggestion_type, :unknown)
    
    Logger.debug(
      "Workflow suggestion: type=#{suggestion_type} confidence=#{Float.round(confidence, 2)} " <>
      "duration=#{Float.round(duration_ms, 1)}ms"
    )
  end

  def handle_event([:mimo, :workflow, :executor, :execute], measurements, metadata, _config) do
    duration_ms = Map.get(measurements, :duration_us, 0) / 1000
    pattern = Map.get(metadata, :pattern_name, "unknown")
    status = Map.get(metadata, :status, :unknown)
    
    Logger.info(
      "Executor: pattern=#{pattern} status=#{status} duration=#{Float.round(duration_ms, 1)}ms"
    )
  end

  # Catch-all for any unhandled workflow events
  def handle_event(event, measurements, metadata, _config) do
    event_name = Enum.join(event, ".")
    Logger.debug(
      "Workflow telemetry: event=#{event_name} " <>
      "measurements=#{inspect(measurements)} metadata=#{inspect(metadata)}"
    )
  end
end
