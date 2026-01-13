defmodule Mimo.Repo.Migrations.CreateEmergencePredictions do
  @moduledoc """
  Creates the emergence_predictions table for tracking prediction accuracy.

  This enables the prediction feedback loop (Track 4.2 P2):
  - Store predictions when made
  - Record outcomes when patterns are promoted/archived
  - Calculate calibrated accuracy over time
  """
  use Ecto.Migration

  def change do
    create table(:emergence_predictions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Link to the pattern being predicted
      add :pattern_id, references(:emergence_patterns, type: :binary_id, on_delete: :delete_all)

      # Prediction details
      add :predicted_outcome, :string, null: false  # will_promote, will_decline, stable
      add :confidence, :float, null: false  # 0.0 to 1.0
      add :eta_days, :float  # Estimated days until outcome

      # Factors that influenced the prediction (JSON)
      add :factors, :text, default: "{}"

      # Pattern snapshot at prediction time
      add :pattern_snapshot, :text, default: "{}"  # strength, success_rate, occurrences

      # Outcome tracking
      add :outcome, :string  # promoted, declined, still_active, expired
      add :outcome_at, :utc_datetime_usec
      add :accuracy_score, :float  # 0.0 to 1.0, how accurate was this prediction?

      # Timing
      add :predicted_at, :utc_datetime_usec, null: false
      add :deadline_at, :utc_datetime_usec  # When to check outcome (predicted_at + eta_days)

      timestamps(type: :utc_datetime_usec)
    end

    # Indexes
    create index(:emergence_predictions, [:pattern_id])
    create index(:emergence_predictions, [:predicted_outcome])
    create index(:emergence_predictions, [:outcome])
    create index(:emergence_predictions, [:predicted_at])
    create index(:emergence_predictions, [:deadline_at])

    # For finding predictions that need outcome checking
    create index(:emergence_predictions, [:outcome, :deadline_at],
      where: "outcome IS NULL",
      name: :emergence_predictions_pending_outcome)
  end
end
