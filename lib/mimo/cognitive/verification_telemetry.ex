defmodule Mimo.Cognitive.VerificationTelemetry do
  @moduledoc """
  SPEC-062: Unified Telemetry for Verification Infrastructure.

  Provides standardized telemetry events for:
  - Verification operations (count, math, logic, compare, self_check)
  - Meta-task detection
  - Calibration updates
  - Reasoner integration events

  ## Telemetry Events

  All events are prefixed with `[:mimo, :verification, ...]`:

  - `[:mimo, :verification, :count]` - Count verification completed
  - `[:mimo, :verification, :math]` - Math verification completed
  - `[:mimo, :verification, :logic]` - Logic verification completed
  - `[:mimo, :verification, :compare]` - Compare verification completed
  - `[:mimo, :verification, :self_check]` - Self-check completed
  - `[:mimo, :meta_task, :detection]` - Meta-task detection event
  - `[:mimo, :calibration, :update]` - Calibration claim/outcome logged

  ## Metrics

  Each event includes:
  - `duration`: Time taken in milliseconds
  - `success`: Whether the operation succeeded
  - Additional operation-specific metrics

  ## Usage

      # In your verification code:
      VerificationTelemetry.emit_verification(:count, result, duration_ms)

      # Attach handlers at startup:
      VerificationTelemetry.attach_handlers()
  """

  require Logger

  @event_prefix [:mimo, :verification]
  @meta_task_prefix [:mimo, :meta_task]
  @calibration_prefix [:mimo, :calibration]

  # ============================================================================
  # TELEMETRY EMISSION
  # ============================================================================

  @doc """
  Emit a verification operation telemetry event.

  ## Parameters

  - operation: The verification operation (:count, :math, :logic, :compare, :self_check)
  - result: The result map from the verification
  - duration_ms: Time taken in milliseconds
  """
  @spec emit_verification(atom(), map(), non_neg_integer()) :: :ok
  def emit_verification(operation, result, duration_ms) when is_atom(operation) do
    success = get_success(result)
    match = get_match(result)

    :telemetry.execute(
      @event_prefix ++ [operation],
      %{
        duration: duration_ms,
        success: if(success, do: 1, else: 0)
      },
      %{
        operation: operation,
        match: match,
        method: get_method(result)
      }
    )

    :ok
  end

  @doc """
  Emit a meta-task detection telemetry event.

  ## Parameters

  - detected?: Whether a meta-task was detected
  - type: The type of meta-task (or :standard)
  - method: Detection method (:regex or :llm_fallback)
  """
  @spec emit_meta_task_detection(boolean(), atom(), atom()) :: :ok
  def emit_meta_task_detection(detected?, type, method) do
    :telemetry.execute(
      @meta_task_prefix ++ [:detection],
      %{detected: if(detected?, do: 1, else: 0)},
      %{type: type, method: method}
    )

    :ok
  end

  @doc """
  Emit a calibration update telemetry event.

  ## Parameters

  - confidence: The claimed confidence (0-100)
  - outcome: Whether the answer was correct (nil if not yet known)
  """
  @spec emit_calibration_update(number(), boolean() | nil) :: :ok
  def emit_calibration_update(confidence, outcome) do
    :telemetry.execute(
      @calibration_prefix ++ [:update],
      %{
        confidence: confidence,
        correct: if(outcome, do: 1, else: 0)
      },
      %{
        has_outcome: outcome != nil
      }
    )

    :ok
  end

  @doc """
  Emit a reasoner meta-task integration event.
  """
  @spec emit_reasoner_meta_task(String.t(), atom(), map()) :: :ok
  def emit_reasoner_meta_task(session_id, task_type, guidance) do
    :telemetry.execute(
      [:mimo, :reasoner, :meta_task],
      %{enhanced: 1},
      %{
        session_id: session_id,
        task_type: task_type,
        confidence: Map.get(guidance, :confidence, 0.5)
      }
    )

    :ok
  end

  # ============================================================================
  # HANDLER ATTACHMENT
  # ============================================================================

  @doc """
  Attach default telemetry handlers for logging and metrics collection.

  Call this at application startup to enable verification telemetry logging.
  """
  @spec attach_handlers() :: :ok
  def attach_handlers do
    handlers = [
      {
        "mimo-verification-handler",
        [
          @event_prefix ++ [:count],
          @event_prefix ++ [:math],
          @event_prefix ++ [:logic],
          @event_prefix ++ [:compare],
          @event_prefix ++ [:self_check]
        ],
        &handle_verification/4
      },
      {
        "mimo-meta-task-handler",
        [@meta_task_prefix ++ [:detection]],
        &handle_meta_task/4
      },
      {
        "mimo-calibration-handler",
        [@calibration_prefix ++ [:update]],
        &handle_calibration/4
      }
    ]

    for {id, events, handler} <- handlers do
      case :telemetry.attach_many(id, events, handler, nil) do
        :ok -> :ok
        {:error, :already_exists} -> :ok
      end
    end

    :ok
  end

  @doc """
  Detach all verification telemetry handlers.
  """
  @spec detach_handlers() :: :ok
  def detach_handlers do
    :telemetry.detach("mimo-verification-handler")
    :telemetry.detach("mimo-meta-task-handler")
    :telemetry.detach("mimo-calibration-handler")
    :ok
  rescue
    _ -> :ok
  end

  # ============================================================================
  # HANDLER IMPLEMENTATIONS
  # ============================================================================

  defp handle_verification(event, measurements, metadata, _config) do
    operation = List.last(event)
    duration = Map.get(measurements, :duration, 0)
    success = Map.get(measurements, :success, 0) == 1

    Logger.debug(
      "[Verification.#{operation}] completed in #{duration}ms, success=#{success}, match=#{metadata[:match]}"
    )

    # Update aggregated stats (could integrate with Prometheus/StatsD here)
    update_verification_stats(operation, success, duration)
  end

  defp handle_meta_task(_event, measurements, metadata, _config) do
    detected = Map.get(measurements, :detected, 0) == 1

    if detected do
      Logger.info("[MetaTask] Detected type=#{metadata[:type]} via #{metadata[:method]}")
    end
  end

  defp handle_calibration(_event, measurements, metadata, _config) do
    confidence = Map.get(measurements, :confidence, 0)
    has_outcome = Map.get(metadata, :has_outcome, false)

    if has_outcome do
      correct = Map.get(measurements, :correct, 0) == 1
      Logger.debug("[Calibration] Confidence=#{confidence}% → #{if correct, do: "✓", else: "✗"}")
    end
  end

  # ============================================================================
  # STATS AGGREGATION
  # ============================================================================

  @stats_table :verification_telemetry_stats

  @doc """
  Get aggregated verification statistics.
  """
  @spec get_stats() :: map()
  def get_stats do
    ensure_stats_table()

    case :ets.lookup(@stats_table, :stats) do
      [{:stats, stats}] -> stats
      [] -> %{}
    end
  end

  @doc """
  Reset aggregated statistics.
  """
  @spec reset_stats() :: :ok
  def reset_stats do
    ensure_stats_table()
    :ets.insert(@stats_table, {:stats, %{}})
    :ok
  end

  defp ensure_stats_table do
    case :ets.whereis(@stats_table) do
      :undefined ->
        :ets.new(@stats_table, [:named_table, :public, :set])

      _ ->
        :ok
    end
  end

  defp update_verification_stats(operation, success, duration) do
    ensure_stats_table()

    current =
      case :ets.lookup(@stats_table, :stats) do
        [{:stats, stats}] -> stats
        [] -> %{}
      end

    op_stats = Map.get(current, operation, %{count: 0, successes: 0, total_duration: 0})

    updated_op_stats = %{
      count: op_stats.count + 1,
      successes: op_stats.successes + if(success, do: 1, else: 0),
      total_duration: op_stats.total_duration + duration,
      avg_duration:
        Float.round((op_stats.total_duration + duration) / (op_stats.count + 1), 2),
      success_rate:
        Float.round((op_stats.successes + if(success, do: 1, else: 0)) / (op_stats.count + 1), 3)
    }

    :ets.insert(@stats_table, {:stats, Map.put(current, operation, updated_op_stats)})
  end

  # ============================================================================
  # HELPER FUNCTIONS
  # ============================================================================

  defp get_success({:ok, %{verified: true}}), do: true
  defp get_success({:ok, %{match: true}}), do: true
  defp get_success({:ok, _}), do: true
  defp get_success({:error, _}), do: false
  defp get_success(_), do: false

  defp get_match({:ok, %{match: match}}), do: match
  defp get_match({:ok, %{verified: verified}}), do: verified
  defp get_match(_), do: nil

  defp get_method({:ok, %{method: method}}), do: method
  defp get_method(_), do: :unknown
end
