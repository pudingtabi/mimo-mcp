defmodule Mimo.Repo.Migrations.AddTemporalMemoryChains do
  @moduledoc """
  SPEC-034: Temporal Memory Chains (TMC)

  Adds supersession tracking to engrams for brain-inspired memory reconsolidation.
  When new information contradicts or updates old memories, this creates explicit
  temporal relationships via supersession chains.

  New columns:
  - supersedes_id: Points to the memory this one supersedes (if any)
  - superseded_at: Timestamp when this memory was superseded (NULL = current/active)
  - supersession_type: Type of supersession ("update", "correction", "refinement", "merge")
  """
  use Ecto.Migration

  def change do
    alter table(:engrams) do
      # Points to the memory this one supersedes (if any)
      # self-reference with nilify_all on delete to prevent orphan chain issues
      add :supersedes_id, references(:engrams, type: :integer, on_delete: :nilify_all)

      # Timestamp when this memory was superseded (NULL = current/active)
      add :superseded_at, :utc_datetime

      # Type of supersession (for analytics and chain understanding)
      # "update" - New info supersedes old (simple replacement)
      # "correction" - Old was wrong, new is correct
      # "refinement" - New adds detail to old (merged content)
      # "merge" - Multiple memories merged into one
      add :supersession_type, :string
    end

    # Index for efficient chain traversal (find what superseded this memory)
    create index(:engrams, [:supersedes_id])

    # Index for filtering active memories (WHERE superseded_at IS NULL)
    create index(:engrams, [:superseded_at])

    # Composite index for common query pattern: category + active filter
    create index(:engrams, [:category, :superseded_at])

    # Composite index for project-scoped active memories
    create index(:engrams, [:project_id, :superseded_at])
  end
end
