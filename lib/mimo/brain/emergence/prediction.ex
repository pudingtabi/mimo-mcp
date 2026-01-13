defmodule Mimo.Brain.Emergence.Prediction do
  @moduledoc """
  Schema for tracking emergence predictions and their outcomes.

  This enables the prediction feedback loop (Track 4.2 P2):
  - Store predictions with confidence and factors
  - Record actual outcomes when patterns evolve
  - Calculate calibrated accuracy for future predictions
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  require Logger
  alias Mimo.Brain.{EctoJsonMap}
  alias Mimo.Brain.Emergence.Pattern
  alias Mimo.Repo

  @derive {Jason.Encoder,
           only: [
             :id,
             :pattern_id,
             :predicted_outcome,
             :confidence,
             :eta_days,
             :factors,
             :outcome,
             :outcome_at,
             :accuracy_score,
             :predicted_at,
             :deadline_at
           ]}

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "emergence_predictions" do
    belongs_to(:pattern, Pattern, type: :binary_id)

    field(:predicted_outcome, Ecto.Enum, values: [:will_promote, :will_decline, :stable])
    field(:confidence, :float)
    field(:eta_days, :float)
    field(:factors, EctoJsonMap, default: %{})
    field(:pattern_snapshot, EctoJsonMap, default: %{})

    # Outcome tracking
    field(:outcome, Ecto.Enum, values: [:promoted, :declined, :still_active, :expired])
    field(:outcome_at, :utc_datetime_usec)
    field(:accuracy_score, :float)

    # Timing
    field(:predicted_at, :utc_datetime_usec)
    field(:deadline_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: binary(),
          pattern_id: binary(),
          predicted_outcome: :will_promote | :will_decline | :stable,
          confidence: float(),
          eta_days: float() | nil,
          factors: map(),
          pattern_snapshot: map(),
          outcome: :promoted | :declined | :still_active | :expired | nil,
          outcome_at: DateTime.t() | nil,
          accuracy_score: float() | nil,
          predicted_at: DateTime.t(),
          deadline_at: DateTime.t() | nil
        }

  @doc """
  Creates a changeset for a new prediction.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(prediction, attrs) do
    prediction
    |> cast(attrs, [
      :pattern_id,
      :predicted_outcome,
      :confidence,
      :eta_days,
      :factors,
      :pattern_snapshot,
      :outcome,
      :outcome_at,
      :accuracy_score,
      :predicted_at,
      :deadline_at
    ])
    |> validate_required([:pattern_id, :predicted_outcome, :confidence, :predicted_at])
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:accuracy_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> foreign_key_constraint(:pattern_id)
  end

  @doc """
  Creates a changeset for recording an outcome.
  """
  @spec outcome_changeset(t(), map()) :: Ecto.Changeset.t()
  def outcome_changeset(prediction, attrs) do
    prediction
    |> cast(attrs, [:outcome, :outcome_at, :accuracy_score])
    |> validate_required([:outcome, :outcome_at])
  end

  # ─────────────────────────────────────────────────────────────────
  # Query Functions
  # ─────────────────────────────────────────────────────────────────

  @doc """
  Records a new prediction for a pattern.
  """
  @spec record(Pattern.t(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def record(pattern, prediction_data) do
    now = DateTime.utc_now()
    eta_days = Map.get(prediction_data, :eta_days)

    deadline =
      if eta_days && eta_days > 0 do
        DateTime.add(now, round(eta_days * 24 * 60 * 60), :second)
      else
        # Default to 30 days if no ETA
        DateTime.add(now, 30 * 24 * 60 * 60, :second)
      end

    attrs = %{
      pattern_id: pattern.id,
      predicted_outcome: prediction_data.predicted_outcome,
      confidence: prediction_data.confidence,
      eta_days: eta_days,
      factors: Map.get(prediction_data, :factors, %{}),
      pattern_snapshot: %{
        strength: pattern.strength,
        success_rate: pattern.success_rate,
        occurrences: pattern.occurrences,
        status: pattern.status
      },
      predicted_at: now,
      deadline_at: deadline
    }

    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets pending predictions that need outcome checking.
  """
  @spec pending_outcomes(keyword()) :: [t()]
  def pending_outcomes(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    now = DateTime.utc_now()

    __MODULE__
    |> where([p], is_nil(p.outcome))
    |> where([p], p.deadline_at <= ^now)
    |> order_by([p], asc: p.deadline_at)
    |> limit(^limit)
    |> preload(:pattern)
    |> Repo.all()
  end

  @doc """
  Records the outcome for a prediction.
  """
  @spec record_outcome(t(), atom()) :: {:ok, t()} | {:error, term()}
  def record_outcome(prediction, actual_outcome) do
    accuracy = calculate_accuracy(prediction, actual_outcome)

    prediction
    |> outcome_changeset(%{
      outcome: actual_outcome,
      outcome_at: DateTime.utc_now(),
      accuracy_score: accuracy
    })
    |> Repo.update()
  end

  @doc """
  Calculates accuracy statistics over a time window.
  """
  @spec accuracy_stats(keyword()) :: map()
  def accuracy_stats(opts \\ []) do
    days = Keyword.get(opts, :days, 30)
    since = DateTime.utc_now() |> DateTime.add(-days * 24 * 60 * 60, :second)

    query =
      from(p in __MODULE__,
        where: not is_nil(p.outcome),
        where: p.predicted_at >= ^since,
        select: %{
          total: count(p.id),
          avg_accuracy: avg(p.accuracy_score),
          avg_confidence: avg(p.confidence),
          promoted: sum(fragment("CASE WHEN outcome = 'promoted' THEN 1 ELSE 0 END")),
          declined: sum(fragment("CASE WHEN outcome = 'declined' THEN 1 ELSE 0 END")),
          expired: sum(fragment("CASE WHEN outcome = 'expired' THEN 1 ELSE 0 END"))
        }
      )

    result = Repo.one(query) || %{total: 0, avg_accuracy: nil}

    # Calculate calibration error (difference between confidence and accuracy)
    calibration_error = calculate_calibration_error(since)

    Map.merge(result, %{
      days: days,
      calibration_error: calibration_error,
      is_calibrated: result.total >= 10
    })
  end

  @doc """
  Gets accuracy by confidence bucket for calibration analysis.
  """
  @spec calibration_buckets(keyword()) :: [map()]
  def calibration_buckets(opts \\ []) do
    days = Keyword.get(opts, :days, 90)
    since = DateTime.utc_now() |> DateTime.add(-days * 24 * 60 * 60, :second)

    # Group predictions by confidence buckets
    query =
      from(p in __MODULE__,
        where: not is_nil(p.outcome),
        where: p.predicted_at >= ^since,
        select: %{
          bucket: fragment("CAST(? * 10 AS INTEGER) * 10", p.confidence),
          count: count(p.id),
          avg_accuracy: avg(p.accuracy_score),
          avg_confidence: avg(p.confidence)
        },
        group_by: fragment("CAST(? * 10 AS INTEGER) * 10", p.confidence),
        order_by: fragment("CAST(? * 10 AS INTEGER) * 10", p.confidence)
      )

    Repo.all(query)
  end

  @doc """
  Gets the most recent predictions for a pattern.
  """
  @spec for_pattern(binary(), keyword()) :: [t()]
  def for_pattern(pattern_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    __MODULE__
    |> where([p], p.pattern_id == ^pattern_id)
    |> order_by([p], desc: p.predicted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Counts predictions by outcome.
  """
  @spec count_by_outcome() :: map()
  def count_by_outcome do
    query =
      from(p in __MODULE__,
        select: {p.outcome, count(p.id)},
        group_by: p.outcome
      )

    Repo.all(query)
    |> Map.new(fn {outcome, count} -> {outcome || :pending, count} end)
  end

  # ─────────────────────────────────────────────────────────────────
  # Private Helpers
  # ─────────────────────────────────────────────────────────────────

  defp calculate_accuracy(prediction, actual_outcome) do
    # Calculate how accurate the prediction was
    case {prediction.predicted_outcome, actual_outcome} do
      # Perfect predictions
      {:will_promote, :promoted} -> 1.0
      {:will_decline, :declined} -> 1.0
      {:stable, :still_active} -> 1.0
      # Completely wrong
      {:will_promote, :declined} -> 0.0
      {:will_decline, :promoted} -> 0.0
      # Partially correct (stable but expired)
      {:stable, :expired} -> 0.5
      {:will_promote, :expired} -> 0.3
      {:will_decline, :expired} -> 0.3
      # Still active when promotion expected (too early to judge)
      {:will_promote, :still_active} -> 0.5
      {:will_decline, :still_active} -> 0.5
      # Unexpected promotion/decline
      {:stable, :promoted} -> 0.3
      {:stable, :declined} -> 0.3
      # Default
      _ -> 0.5
    end
  end

  defp calculate_calibration_error(since) do
    # Calibration error = average |confidence - accuracy|
    query =
      from(p in __MODULE__,
        where: not is_nil(p.outcome),
        where: not is_nil(p.accuracy_score),
        where: p.predicted_at >= ^since,
        select: avg(fragment("ABS(? - ?)", p.confidence, p.accuracy_score))
      )

    case Repo.one(query) do
      nil -> nil
      error when is_float(error) -> Float.round(error, 4)
      error -> error
    end
  end
end
