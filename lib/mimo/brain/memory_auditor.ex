defmodule Mimo.Brain.MemoryAuditor do
  @moduledoc """
  Memory quality control - detect contradictions, duplicates, obsolete facts.

  Part of IMPLEMENTATION_PLAN_Q1_2026 Phase 1: Foundation Hardening.

  This module provides visibility into memory quality issues:
  - Exact duplicates: Identical content stored multiple times
  - Potential contradictions: Similar memories with opposite sentiment/meaning
  - Obsolete candidates: Old memories with low importance and low access

  ## Usage

      # Full audit
      Mimo.Brain.MemoryAuditor.audit()

      # Find specific issues
      Mimo.Brain.MemoryAuditor.find_exact_duplicates()
      Mimo.Brain.MemoryAuditor.find_contradictions(limit: 20)
      Mimo.Brain.MemoryAuditor.find_obsolete_candidates(days_old: 90)
  """

  alias Mimo.Brain.Engram
  alias Mimo.Brain.Memory
  alias Mimo.Repo
  import Ecto.Query
  require Logger

  @doc """
  Run a full memory audit.

  Returns a map with:
  - `exact_duplicates` - List of duplicate content with counts
  - `potential_contradictions` - List of potentially contradicting memory pairs
  - `obsolete_candidates` - List of memories that may be candidates for removal
  """
  def audit(opts \\ []) do
    Logger.info("[MemoryAuditor] Starting audit...")

    start_time = System.monotonic_time(:millisecond)

    results = %{
      exact_duplicates: find_exact_duplicates(),
      potential_contradictions: find_contradictions(opts[:limit] || 20),
      obsolete_candidates: find_obsolete_candidates(opts[:days_old] || 90)
    }

    duration = System.monotonic_time(:millisecond) - start_time
    Logger.info("[MemoryAuditor] Audit complete in #{duration}ms")

    results
  end

  @doc """
  Find memories with identical content.

  Returns a list of {content, count} tuples for content that appears more than once.
  """
  def find_exact_duplicates do
    # Find memories with identical content
    # Note: This uses raw SQL for SQLite compatibility
    query =
      from(e in Engram,
        group_by: e.content,
        having: count(e.id) > 1,
        select: %{content: e.content, count: count(e.id)}
      )

    case Repo.all(query) do
      results when is_list(results) ->
        results

      _ ->
        []
    end
  rescue
    e ->
      Logger.warning("[MemoryAuditor] Failed to find duplicates: #{Exception.message(e)}")
      []
  end

  @doc """
  Find potentially contradicting memories.

  Uses a heuristic approach:
  1. Find memories containing negation words (not, never, don't, etc.)
  2. For each, find semantically similar memories
  3. Check if the similar memory lacks negation (potential contradiction)

  Note: This is a heuristic and may produce false positives. Human review is recommended.
  """
  def find_contradictions(limit \\ 20) do
    # Find memories with negation patterns
    negation_query =
      from(e in Engram,
        where:
          fragment(
            "? LIKE '%not %' OR ? LIKE '%no %' OR ? LIKE '%never%' OR ? LIKE '%don''t%' OR ? LIKE '%doesn''t%' OR ? LIKE '%cannot%' OR ? LIKE '%won''t%'",
            e.content,
            e.content,
            e.content,
            e.content,
            e.content,
            e.content,
            e.content
          ),
        limit: ^limit,
        select: e
      )

    memories = Repo.all(negation_query)

    # For each negated memory, find semantically similar memories
    Enum.flat_map(memories, fn memory ->
      find_contradicting_pairs(memory)
    end)
    |> Enum.take(limit)
  rescue
    e ->
      Logger.warning("[MemoryAuditor] Failed to find contradictions: #{Exception.message(e)}")
      []
  end

  @doc """
  Find old memories that may be candidates for removal.

  Criteria:
  - Older than `days_old` days
  - Low importance (< 0.3)
  - Low access count (< 2 accesses)
  - Not protected
  """
  def find_obsolete_candidates(days_old \\ 90) do
    cutoff = NaiveDateTime.utc_now() |> NaiveDateTime.add(-days_old * 24 * 60 * 60, :second)

    query =
      from(e in Engram,
        where: e.inserted_at < ^cutoff,
        where: e.importance < 0.3,
        where: e.access_count < 2,
        where: e.protected != true,
        # Not already superseded
        where: is_nil(e.superseded_at),
        order_by: [asc: e.importance],
        limit: 50,
        select: %{
          id: e.id,
          content: e.content,
          importance: e.importance,
          access_count: e.access_count,
          inserted_at: e.inserted_at,
          category: e.category
        }
      )

    results = Repo.all(query)

    # Calculate age for each result
    Enum.map(results, fn r ->
      age_days = NaiveDateTime.diff(NaiveDateTime.utc_now(), r.inserted_at, :second) / 86_400
      Map.put(r, :age_days, Float.round(age_days, 1))
    end)
  rescue
    e ->
      Logger.warning("[MemoryAuditor] Failed to find obsolete candidates: #{Exception.message(e)}")
      []
  end

  @doc """
  Generate recommendations based on audit results.
  """
  def generate_recommendations(results) do
    recs = []

    # Recommendations based on duplicates
    dup_count = length(results.exact_duplicates)

    recs =
      cond do
        dup_count > 50 ->
          recs ++
            [
              %{
                severity: :high,
                issue: "High duplicate count (#{dup_count})",
                recommendation:
                  "Implement automatic deduplication on store. Consider adding content hash check."
              }
            ]

        dup_count > 10 ->
          recs ++
            [
              %{
                severity: :medium,
                issue: "Moderate duplicate count (#{dup_count})",
                recommendation:
                  "Review duplicates and consider manual cleanup or content normalization."
              }
            ]

        true ->
          recs
      end

    # Recommendations based on contradictions
    contra_count = length(results.potential_contradictions)

    recs =
      cond do
        contra_count > 10 ->
          recs ++
            [
              %{
                severity: :medium,
                issue: "Potential contradictions detected (#{contra_count})",
                recommendation:
                  "Review contradictions manually - may indicate evolving understanding or genuine conflicts. Consider TMC supersession."
              }
            ]

        contra_count > 0 ->
          recs ++
            [
              %{
                severity: :low,
                issue: "Some potential contradictions (#{contra_count})",
                recommendation: "Review flagged memories to verify they don't conflict."
              }
            ]

        true ->
          recs
      end

    # Recommendations based on obsolete candidates
    obsolete_count = length(results.obsolete_candidates)

    recs =
      cond do
        obsolete_count > 30 ->
          recs ++
            [
              %{
                severity: :medium,
                issue: "Many obsolete memory candidates (#{obsolete_count})",
                recommendation:
                  "Consider more aggressive decay parameters or implement memory surgery for cleanup."
              }
            ]

        obsolete_count > 10 ->
          recs ++
            [
              %{
                severity: :low,
                issue: "Some obsolete memory candidates (#{obsolete_count})",
                recommendation:
                  "Memory decay is working normally. Consider reviewing oldest candidates."
              }
            ]

        true ->
          recs
      end

    recs
  end

  # Private Functions

  defp find_contradicting_pairs(memory) do
    # Use Memory.search to find semantically similar memories
    {:ok, similar_memories} = Memory.search(memory.content, limit: 5, threshold: 0.65)

    # Filter to memories that might contradict
    similar_memories
    |> Enum.filter(fn sim ->
      sim.id != memory.id and potentially_contradicts?(memory.content, sim.content)
    end)
    |> Enum.map(fn sim ->
      %{
        memory_a_id: memory.id,
        memory_b_id: sim.id,
        content_a: truncate(memory.content, 100),
        content_b: truncate(sim.content, 100),
        similarity: sim.similarity,
        reason: "Memory A has negation, Memory B does not"
      }
    end)
  end

  defp potentially_contradicts?(content_a, content_b) do
    # Simple heuristic: one has negation, other doesn't
    negation_pattern =
      ~r/(^|\s)(not|no|never|don't|doesn't|cannot|won't|isn't|aren't|wasn't|weren't|hasn't|haven't|hadn't|shouldn't|wouldn't|couldn't|can't)(\s|$)/i

    has_negation_a = Regex.match?(negation_pattern, content_a)
    has_negation_b = Regex.match?(negation_pattern, content_b)

    # Only flag if one has negation and the other doesn't
    has_negation_a != has_negation_b
  end

  defp truncate(string, max_length) do
    if String.length(string) > max_length do
      String.slice(string, 0, max_length) <> "..."
    else
      string
    end
  end
end
