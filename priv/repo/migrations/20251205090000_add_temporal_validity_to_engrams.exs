defmodule Mimo.Repo.Migrations.AddTemporalValidityToEngrams do
  use Ecto.Migration

  def change do
    alter table(:engrams) do
      add :valid_from, :utc_datetime
      add :valid_until, :utc_datetime
      add :validity_source, :string, default: "inferred"
    end

    create index(:engrams, [:valid_from])
    create index(:engrams, [:valid_until])
    create index(:engrams, [:valid_from, :valid_until])
  end
end
