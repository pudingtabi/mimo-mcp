defmodule Mimo.SemanticStore do
  @moduledoc """
  Facade module for the Semantic Store - a knowledge graph for entity relationships.

  Provides a unified API for:
  - Storing and querying semantic triples (subject-predicate-object)
  - Graph traversal and path finding
  - Entity relationship management

  ## Architecture

  The SemanticStore is composed of several sub-modules:
  - `Repository` - CRUD operations for triples
  - `Query` - Graph queries using SQLite recursive CTEs
  - `Ingestor` - Bulk ingestion from LLM-extracted facts
  - `Resolver` - Entity resolution and deduplication
  - `InferenceEngine` - Rule-based inference for new facts
  - `Dreamer` - Background inference worker
  - `Observer` - Proactive context observer
  """

  alias Mimo.SemanticStore.{Query, Repository}

  @doc """
  Query for entities related to a search term.

  Used by HybridRetriever for graph-based search.

  ## Options

    * `:limit` - Maximum results (default: 10)
    * `:min_confidence` - Minimum triple confidence (default: 0.5)
  """
  @spec query_related(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def query_related(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    min_confidence = Keyword.get(opts, :min_confidence, 0.5)

    # Search for triples where query appears in subject, predicate, or object
    results = Repository.search(query, limit: limit, min_confidence: min_confidence)

    {:ok, results}
  rescue
    e -> {:error, e}
  end

  @doc """
  Count connections (relationships) for an entity.

  Used by HybridScorer for graph connectivity scoring.
  """
  @spec count_connections(term()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count_connections(entity_id) do
    count = Repository.count_relationships(entity_id)
    {:ok, count}
  rescue
    e -> {:error, e}
  end

  @doc """
  Store a semantic triple.
  """
  defdelegate store_triple(subject, predicate, object, opts \\ []), to: Repository

  @doc """
  Get all relationships for an entity.
  """
  defdelegate get_relationships(entity_id, entity_type), to: Query

  @doc """
  Find entities reachable via transitive closure.
  """
  defdelegate transitive_closure(start_id, start_type, predicate, opts \\ []), to: Query

  @doc """
  Find shortest path between entities.
  """
  defdelegate find_path(from_id, to_id, predicate, opts \\ []), to: Query

  @doc """
  Pattern matching query.
  """
  defdelegate pattern_match(clauses), to: Query
end
