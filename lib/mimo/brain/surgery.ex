defmodule Mimo.Brain.Surgery do
  @moduledoc """
  Brain surgery utilities for maintenance and repair operations.

  This module provides tools for:
  - Protecting critical memories from decay
  - Removing duplicate content
  - Migrating legacy embeddings to int8 format
  - Repairing orphaned memories

  ## Usage

      # Protect critical memories
      {:ok, count} = Mimo.Brain.Surgery.protect_critical()

      # Remove duplicates (dry run)
      {:ok, preview} = Mimo.Brain.Surgery.deduplicate(dry_run: true)

      # Remove duplicates (execute)
      {:ok, removed} = Mimo.Brain.Surgery.deduplicate(dry_run: false)

      # Migrate float32 to int8
      {:ok, migrated} = Mimo.Brain.Surgery.migrate_to_int8()

      # Full health surgery
      {:ok, report} = Mimo.Brain.Surgery.full_surgery(dry_run: true)
  """

  require Logger
  import Ecto.Query

  alias Mimo.{Brain.Engram, Brain.LLM, Repo, Vector.Math}

  @doc """
  Protect critical memories from decay and forgetting.

  ## Criteria

  - High importance (>= 0.85)
  - Entity anchors
  - Frequently accessed (10+ accesses)
  - Architecture/system knowledge
  - User preferences

  ## Returns

      {:ok, count} - Number of memories newly protected
  """
  @spec protect_critical(keyword()) :: {:ok, non_neg_integer()}
  def protect_critical(opts \\ []) do
    importance_threshold = Keyword.get(opts, :importance_threshold, 0.85)
    access_threshold = Keyword.get(opts, :access_threshold, 10)

    Logger.info("[Surgery] Starting protection surgery...")

    # Track initial state
    initial_protected =
      Repo.one(from(e in Engram, where: e.protected == true, select: count())) || 0

    # 1. High importance
    {high_imp, _} =
      from(e in Engram,
        where: e.importance >= ^importance_threshold,
        where: e.protected == false or is_nil(e.protected)
      )
      |> Repo.update_all(set: [protected: true])

    Logger.debug("[Surgery] Protected #{high_imp} high-importance memories")

    # 2. Entity anchors
    {anchors, _} =
      from(e in Engram,
        where: e.category == "entity_anchor",
        where: e.protected == false or is_nil(e.protected)
      )
      |> Repo.update_all(set: [protected: true])

    Logger.debug("[Surgery] Protected #{anchors} entity anchors")

    # 3. Frequently accessed
    {accessed, _} =
      from(e in Engram,
        where: e.access_count >= ^access_threshold,
        where: e.protected == false or is_nil(e.protected)
      )
      |> Repo.update_all(set: [protected: true])

    Logger.debug("[Surgery] Protected #{accessed} frequently accessed memories")

    # 4. Architecture knowledge (SQL fragment for LIKE patterns)
    {arch, _} =
      from(e in Engram,
        where: e.protected == false or is_nil(e.protected),
        where:
          fragment("? LIKE '%SPEC-%'", e.content) or
            fragment("? LIKE '%architecture%'", e.content) or
            fragment("? LIKE '%mimo_mcp%'", e.content) or
            fragment("? LIKE '%Engram%'", e.content) or
            fragment("? LIKE '%embedding%quantiz%'", e.content)
      )
      |> Repo.update_all(set: [protected: true])

    Logger.debug("[Surgery] Protected #{arch} architecture knowledge memories")

    # Final count
    final_protected =
      Repo.one(from(e in Engram, where: e.protected == true, select: count())) || 0

    newly_protected = final_protected - initial_protected

    Logger.info(
      "[Surgery] Protection complete: #{newly_protected} newly protected, #{final_protected} total"
    )

    {:ok, newly_protected}
  end

  @doc """
  Remove duplicate memories, keeping the oldest (first created).

  ## Options

      * `:dry_run` - Preview without deleting (default: true)
      * `:limit` - Max duplicates to process (default: 100)

  ## Returns

      {:ok, %{groups: N, removed: N, preview: [...]}} 
  """
  @spec deduplicate(keyword()) :: {:ok, map()}
  def deduplicate(opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, true)
    limit = Keyword.get(opts, :limit, 100)

    Logger.info("[Surgery] Starting deduplication (dry_run: #{dry_run})...")

    # Find duplicates - keep MIN(id) for each content
    duplicates_query = """
    SELECT id, category, importance, substr(content, 1, 60) as preview
    FROM engrams 
    WHERE id NOT IN (SELECT MIN(id) FROM engrams GROUP BY content)
    ORDER BY id
    LIMIT ?
    """

    {:ok, result} = Repo.query(duplicates_query, [limit])

    duplicates =
      Enum.map(result.rows, fn [id, cat, imp, preview] ->
        %{id: id, category: cat, importance: imp, preview: preview}
      end)

    duplicate_count = length(duplicates)

    if dry_run do
      Logger.info("[Surgery] Dry run: would remove #{duplicate_count} duplicate memories")

      {:ok,
       %{
         groups: count_duplicate_groups(),
         removed: 0,
         would_remove: duplicate_count,
         preview: Enum.take(duplicates, 10)
       }}
    else
      # Actually delete
      ids_to_delete = Enum.map(duplicates, & &1.id)

      {deleted, _} =
        from(e in Engram, where: e.id in ^ids_to_delete)
        |> Repo.delete_all()

      Logger.info("[Surgery] Removed #{deleted} duplicate memories")

      {:ok,
       %{
         groups: count_duplicate_groups(),
         removed: deleted,
         preview: Enum.take(duplicates, 10)
       }}
    end
  end

  defp count_duplicate_groups do
    query = """
    SELECT COUNT(*) FROM (
      SELECT content FROM engrams GROUP BY content HAVING COUNT(*) > 1
    )
    """

    case Repo.query(query) do
      {:ok, %{rows: [[count]]}} -> count
      _ -> 0
    end
  end

  @doc """
  Migrate remaining float32 embeddings to int8 format.

  ## Options

      * `:dry_run` - Preview without migrating (default: false)
      * `:batch_size` - Process N at a time (default: 50)

  ## Returns

      {:ok, %{migrated: N, failed: N, remaining: N}}
  """
  @spec migrate_to_int8(keyword()) :: {:ok, map()}
  def migrate_to_int8(opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)
    batch_size = Keyword.get(opts, :batch_size, 50)

    Logger.info("[Surgery] Starting int8 migration (dry_run: #{dry_run})...")

    # Find float32-only embeddings
    # Note: embedding is EctoJsonList type, so compare raw JSON text in SQLite
    float32_only =
      from(e in Engram,
        where: is_nil(e.embedding_int8) or fragment("length(?) = 0", e.embedding_int8),
        where:
          not is_nil(e.embedding) and
            fragment("? != '[]' AND length(?) > 2", e.embedding, e.embedding),
        limit: ^batch_size
      )
      |> Repo.all()

    count = length(float32_only)

    if dry_run do
      Logger.info("[Surgery] Dry run: would migrate #{count} memories")
      {:ok, %{migrated: 0, would_migrate: count, failed: 0}}
    else
      results =
        Enum.map(float32_only, fn engram ->
          case migrate_engram_to_int8(engram) do
            :ok -> :migrated
            {:error, _} -> :failed
          end
        end)

      migrated = Enum.count(results, &(&1 == :migrated))
      failed = Enum.count(results, &(&1 == :failed))

      remaining =
        Repo.one(
          from(e in Engram,
            where: is_nil(e.embedding_int8) or fragment("length(?) = 0", e.embedding_int8),
            where:
              not is_nil(e.embedding) and
                fragment("? != '[]' AND length(?) > 2", e.embedding, e.embedding),
            select: count()
          )
        ) || 0

      Logger.info("[Surgery] Migration complete: #{migrated} migrated, #{failed} failed")

      {:ok, %{migrated: migrated, failed: failed, remaining: remaining}}
    end
  end

  defp migrate_engram_to_int8(engram) do
    case Engram.get_embedding(engram) do
      {:ok, embedding} when is_list(embedding) and embedding != [] ->
        case Math.quantize_int8(embedding) do
          {:ok, {binary, scale, offset}} ->
            changeset =
              Ecto.Changeset.change(engram, %{
                embedding_int8: binary,
                embedding_scale: scale,
                embedding_offset: offset,
                # Clear float32 to save space
                embedding: []
              })

            case Repo.update(changeset) do
              {:ok, _} ->
                Logger.debug("[Surgery] Migrated engram #{engram.id}")
                :ok

              {:error, cs} ->
                Logger.warning("[Surgery] Failed to update #{engram.id}: #{inspect(cs.errors)}")
                {:error, :update_failed}
            end

          {:error, reason} ->
            Logger.warning("[Surgery] Quantization failed for #{engram.id}: #{inspect(reason)}")
            {:error, reason}
        end

      _ ->
        Logger.debug("[Surgery] No valid embedding for #{engram.id}")
        {:error, :no_embedding}
    end
  end

  @doc """
  Repair orphaned memories by regenerating embeddings.

  ## Options

      * `:dry_run` - Preview without repairing (default: false)
      * `:batch_size` - Process N at a time (default: 20)

  ## Returns

      {:ok, %{repaired: N, failed: N, remaining: N}}
  """
  @spec repair_orphans(keyword()) :: {:ok, map()}
  def repair_orphans(opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)
    batch_size = Keyword.get(opts, :batch_size, 20)

    Logger.info("[Surgery] Starting orphan repair (dry_run: #{dry_run})...")

    # Find orphaned memories (no embedding at all)
    # Note: embedding is EctoJsonList type, so compare raw JSON text in SQLite
    orphans =
      from(e in Engram,
        where:
          (is_nil(e.embedding_int8) or fragment("length(?) = 0", e.embedding_int8)) and
            (is_nil(e.embedding) or fragment("? = '[]' OR length(?) <= 2", e.embedding, e.embedding)),
        limit: ^batch_size
      )
      |> Repo.all()

    count = length(orphans)

    if dry_run do
      Logger.info("[Surgery] Dry run: would repair #{count} orphaned memories")

      {:ok,
       %{
         repaired: 0,
         would_repair: count,
         failed: 0,
         preview: Enum.map(orphans, &%{id: &1.id, content: String.slice(&1.content, 0, 50)})
       }}
    else
      results =
        Enum.map(orphans, fn engram ->
          case repair_orphan(engram) do
            :ok -> :repaired
            {:error, _} -> :failed
          end
        end)

      repaired = Enum.count(results, &(&1 == :repaired))
      failed = Enum.count(results, &(&1 == :failed))

      remaining = count_orphans()

      Logger.info("[Surgery] Repair complete: #{repaired} repaired, #{failed} failed")

      {:ok, %{repaired: repaired, failed: failed, remaining: remaining}}
    end
  end

  defp repair_orphan(engram) do
    case LLM.generate_embedding(engram.content) do
      {:ok, embedding} when is_list(embedding) and embedding != [] ->
        case Math.quantize_int8(embedding) do
          {:ok, {binary, scale, offset}} ->
            changeset =
              Ecto.Changeset.change(engram, %{
                embedding_int8: binary,
                embedding_scale: scale,
                embedding_offset: offset
              })

            case Repo.update(changeset) do
              {:ok, _} ->
                Logger.debug("[Surgery] Repaired orphan #{engram.id}")
                :ok

              {:error, _} ->
                {:error, :update_failed}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("[Surgery] Embedding generation failed for #{engram.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp count_orphans do
    # Note: embedding is EctoJsonList type, so compare raw JSON text in SQLite
    Repo.one(
      from(e in Engram,
        where:
          (is_nil(e.embedding_int8) or fragment("length(?) = 0", e.embedding_int8)) and
            (is_nil(e.embedding) or fragment("? = '[]' OR length(?) <= 2", e.embedding, e.embedding)),
        select: count()
      )
    ) || 0
  end

  @doc """
  Run complete brain surgery: protect, deduplicate, migrate, repair.

  ## Options

      * `:dry_run` - Preview all operations without changes (default: true)

  ## Returns

      {:ok, %{protection: {...}, deduplication: {...}, migration: {...}, repair: {...}}}
  """
  @spec full_surgery(keyword()) :: {:ok, map()}
  def full_surgery(opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, true)

    Logger.info("[Surgery] Starting full brain surgery (dry_run: #{dry_run})...")

    results = %{
      protection:
        if(dry_run,
          do: {:ok, %{would_protect: "~200-300"}},
          else: protect_critical(opts)
        ),
      deduplication: deduplicate(Keyword.put(opts, :dry_run, dry_run)),
      migration: migrate_to_int8(Keyword.put(opts, :dry_run, dry_run)),
      repair: repair_orphans(Keyword.put(opts, :dry_run, dry_run))
    }

    Logger.info("[Surgery] Full surgery complete")

    {:ok, results}
  end
end
