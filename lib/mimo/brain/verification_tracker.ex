defmodule Mimo.Brain.VerificationTracker do
  @moduledoc """
  SPEC-AI-TEST P1: Tracks verification patterns to detect ceremonial vs genuine verification.

  This GenServer maintains statistics about verification usage, identifying:
  - Ceremonial verification (claims without actual checks)
  - Genuine executable verification (using verify tool)
  - Verification accuracy and patterns
  - Overconfidence detection via Brier scores

  ## Features

  - Records verification attempts and outcomes
  - Detects ceremonial ("Let me verify") vs genuine verification
  - Calculates Brier scores for confidence calibration
  - Identifies overconfidence patterns
  - Tracks verification success rates by operation type
  - Suggests when verification should be used

  ## Usage

      # Record a verification attempt
      VerificationTracker.record_claim("Mississippi has 4 s's", %{claimed: 4, method: :ceremonial})
      
      # Record actual verification
      VerificationTracker.record_verification(:count, %{claimed: 4, actual: 4, verified: true})
      
      # Get statistics
      VerificationTracker.stats()
      
      # Check for overconfidence
      VerificationTracker.detect_overconfidence()
  """

  use GenServer
  require Logger

  @table :verification_tracker
  @stats_table :verification_stats
  @name __MODULE__

  # Cleanup older than 30 days
  @cleanup_age_days 30
  # Aggregate every hour
  @aggregate_interval_ms 60 * 60 * 1000

  defstruct total_claims: 0,
            ceremonial_count: 0,
            genuine_count: 0,
            verified_correct: 0,
            verified_incorrect: 0,
            total_brier_score: 0.0,
            overconfidence_detected: 0,
            last_aggregated: nil,
            verification_by_type: %{}

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  Record a verification claim (may be ceremonial or genuine).

  ## Parameters

  - claim: The claim being made
  - metadata: Map with :claimed value, :method (:ceremonial or :genuine), :confidence (0-1)
  """
  def record_claim(claim, metadata) do
    GenServer.cast(@name, {:record_claim, claim, metadata, DateTime.utc_now()})
  end

  @doc """
  Record an actual verification result.

  ## Parameters

  - operation: The verification operation (:count, :math, :logic, :compare, :self_check)
  - result: Map with :claimed, :actual, :verified boolean, :confidence
  """
  def record_verification(operation, result) do
    GenServer.cast(@name, {:record_verification, operation, result, DateTime.utc_now()})
  end

  @doc """
  Get verification statistics.
  """
  def stats do
    GenServer.call(@name, :stats)
  end

  @doc """
  Detect overconfidence patterns.

  Returns patterns where confidence was high but verification failed.
  """
  def detect_overconfidence(opts \\ []) do
    threshold = Keyword.get(opts, :brier_threshold, 0.3)
    GenServer.call(@name, {:detect_overconfidence, threshold})
  end

  @doc """
  Get verification success rate by operation type.
  """
  def success_by_type do
    GenServer.call(@name, :success_by_type)
  end

  @doc """
  Calculate average Brier score (0=perfect, 0.25=random, 1=always wrong).
  """
  def brier_score do
    GenServer.call(@name, :brier_score)
  end

  @doc """
  Clear all tracking data.
  """
  def clear do
    GenServer.call(@name, :clear)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS tables
    :ets.new(@table, [:named_table, :public, :duplicate_bag])
    :ets.new(@stats_table, [:named_table, :public, :set])

    # Initialize stats
    :ets.insert(@stats_table, {:stats, %__MODULE__{}})

    # Schedule periodic aggregation
    schedule_aggregation()

    Logger.info("[VerificationTracker] Started with ETS tables")

    {:ok, %{}}
  end

  @impl true
  def handle_cast({:record_claim, claim, metadata, timestamp}, state) do
    method = Map.get(metadata, :method, :unknown)

    # Store in ETS
    :ets.insert(
      @table,
      {{:claim, timestamp},
       %{
         claim: claim,
         method: method,
         confidence: Map.get(metadata, :confidence),
         claimed_value: Map.get(metadata, :claimed),
         timestamp: timestamp
       }}
    )

    # Update stats
    [{:stats, stats}] = :ets.lookup(@stats_table, :stats)

    updated_stats = %{
      stats
      | total_claims: stats.total_claims + 1,
        ceremonial_count:
          if(method == :ceremonial, do: stats.ceremonial_count + 1, else: stats.ceremonial_count),
        genuine_count:
          if(method == :genuine, do: stats.genuine_count + 1, else: stats.genuine_count)
    }

    :ets.insert(@stats_table, {:stats, updated_stats})

    {:noreply, state}
  end

  @impl true
  def handle_cast({:record_verification, operation, result, timestamp}, state) do
    verified = Map.get(result, :verified, false)
    confidence = Map.get(result, :confidence, 0.5)

    # Calculate Brier score component
    # Brier = (predicted_prob - actual_outcome)^2
    # If verified=true, outcome=1; if false, outcome=0
    outcome = if verified, do: 1.0, else: 0.0
    brier_component = :math.pow(confidence - outcome, 2)

    # Detect overconfidence (high confidence but wrong)
    overconfident = confidence >= 0.8 and not verified

    # Store in ETS
    :ets.insert(
      @table,
      {{:verification, timestamp},
       %{
         operation: operation,
         claimed: Map.get(result, :claimed),
         actual: Map.get(result, :actual),
         verified: verified,
         confidence: confidence,
         brier_component: brier_component,
         overconfident: overconfident,
         timestamp: timestamp
       }}
    )

    # Update stats
    [{:stats, stats}] = :ets.lookup(@stats_table, :stats)

    by_type = stats.verification_by_type
    type_stats = Map.get(by_type, operation, %{total: 0, correct: 0})

    updated_type_stats = %{
      total: type_stats.total + 1,
      correct: if(verified, do: type_stats.correct + 1, else: type_stats.correct)
    }

    updated_stats = %{
      stats
      | total_claims: stats.total_claims + 1,
        genuine_count: stats.genuine_count + 1,
        verified_correct:
          if(verified, do: stats.verified_correct + 1, else: stats.verified_correct),
        verified_incorrect:
          if(!verified, do: stats.verified_incorrect + 1, else: stats.verified_incorrect),
        total_brier_score: stats.total_brier_score + brier_component,
        overconfidence_detected:
          if(overconfident,
            do: stats.overconfidence_detected + 1,
            else: stats.overconfidence_detected
          ),
        verification_by_type: Map.put(by_type, operation, updated_type_stats)
    }

    :ets.insert(@stats_table, {:stats, updated_stats})

    {:noreply, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    [{:stats, stats}] = :ets.lookup(@stats_table, :stats)

    # Calculate ratios
    total = stats.total_claims
    ceremonial_ratio = if total > 0, do: stats.ceremonial_count / total, else: 0.0
    genuine_ratio = if total > 0, do: stats.genuine_count / total, else: 0.0

    success_rate =
      if stats.genuine_count > 0,
        do: stats.verified_correct / stats.genuine_count,
        else: 0.0

    result = %{
      total_claims: total,
      ceremonial_count: stats.ceremonial_count,
      genuine_count: stats.genuine_count,
      ceremonial_ratio: Float.round(ceremonial_ratio, 3),
      genuine_ratio: Float.round(genuine_ratio, 3),
      verified_correct: stats.verified_correct,
      verified_incorrect: stats.verified_incorrect,
      success_rate: Float.round(success_rate, 3),
      overconfidence_detected: stats.overconfidence_detected,
      verification_by_type: stats.verification_by_type
    }

    {:reply, result, state}
  end

  @impl true
  def handle_call({:detect_overconfidence, threshold}, _from, state) do
    # Find verification attempts with high confidence but failure
    overconfident_attempts =
      :ets.match_object(
        @table,
        {{:verification, :_}, %{overconfident: true, confidence: :"$1", operation: :"$2"}}
      )
      |> Enum.filter(fn {{:verification, _ts}, data} ->
        data.brier_component > threshold
      end)
      |> Enum.map(fn {{:verification, ts}, data} ->
        %{
          timestamp: ts,
          operation: data.operation,
          confidence: data.confidence,
          claimed: data.claimed,
          actual: data.actual,
          brier_score: Float.round(data.brier_component, 3)
        }
      end)
      |> Enum.take(20)

    {:reply, overconfident_attempts, state}
  end

  @impl true
  def handle_call(:success_by_type, _from, state) do
    [{:stats, stats}] = :ets.lookup(@stats_table, :stats)

    success_by_type =
      Enum.map(stats.verification_by_type, fn {operation, type_stats} ->
        success_rate =
          if type_stats.total > 0,
            do: type_stats.correct / type_stats.total,
            else: 0.0

        {operation,
         %{
           total: type_stats.total,
           correct: type_stats.correct,
           success_rate: Float.round(success_rate, 3)
         }}
      end)
      |> Enum.into(%{})

    {:reply, success_by_type, state}
  end

  @impl true
  def handle_call(:brier_score, _from, state) do
    [{:stats, stats}] = :ets.lookup(@stats_table, :stats)

    avg_brier =
      if stats.genuine_count > 0,
        do: stats.total_brier_score / stats.genuine_count,
        else: 0.0

    interpretation =
      cond do
        avg_brier < 0.1 -> :excellent
        avg_brier < 0.2 -> :good
        avg_brier < 0.3 -> :acceptable
        true -> :poor
      end

    result = %{
      average_brier_score: Float.round(avg_brier, 4),
      interpretation: interpretation,
      total_verifications: stats.genuine_count,
      note: "0=perfect, 0.25=random guessing, 1=always wrong"
    }

    {:reply, result, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    :ets.insert(@stats_table, {:stats, %__MODULE__{}})
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:aggregate, state) do
    cleanup_old_entries()
    schedule_aggregation()
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private Functions

  defp schedule_aggregation do
    Process.send_after(self(), :aggregate, @aggregate_interval_ms)
  end

  defp cleanup_old_entries do
    cutoff = DateTime.add(DateTime.utc_now(), -@cleanup_age_days * 24 * 60 * 60, :second)

    # Delete old claims
    :ets.select_delete(@table, [
      {{{:claim, :"$1"}, :_}, [{:<, :"$1", cutoff}], [true]}
    ])

    # Delete old verifications
    :ets.select_delete(@table, [
      {{{:verification, :"$1"}, :_}, [{:<, :"$1", cutoff}], [true]}
    ])

    Logger.debug("[VerificationTracker] Cleaned up entries older than #{@cleanup_age_days} days")
  end
end
