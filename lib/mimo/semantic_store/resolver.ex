defmodule Mimo.SemanticStore.Resolver do
  @moduledoc """
  Entity Resolution using Vector-backed Entity Linking.

  Resolves ambiguous entity mentions ("The DB") to canonical IDs ("db:postgres")
  using vector similarity search against entity anchors.
  """

  require Logger
  alias Mimo.Repo
  alias Mimo.Brain.Memory

  @entity_anchor_type "entity_anchor"
  @resolution_threshold 0.85
  @default_graph_id "global"

  @doc """
  Resolves a text mention to a canonical entity ID.

  ## Parameters
    - `text` - The entity mention (e.g., "The DB", "auth service")
    - `expected_type` - Expected entity type (:auto, :service, :person, etc.)
    - `opts` - Options:
      - `:graph_id` - Graph namespace (default: "global")
      - `:create_anchor` - Force anchor creation (default: false)
      - `:min_score` - Override resolution threshold

  ## Returns
    - `{:ok, canonical_id}` - Successfully resolved
    - `{:error, :ambiguous, candidates}` - Multiple high-confidence matches
    - `{:error, reason}` - Resolution failed
  """
  @spec resolve_entity(String.t(), atom(), keyword()) ::
          {:ok, String.t()} | {:error, atom()} | {:error, :ambiguous, list()}
  def resolve_entity(text, expected_type \\ :auto, opts \\ []) do
    start_time = System.monotonic_time(:millisecond)
    graph_id = Keyword.get(opts, :graph_id, @default_graph_id)
    create_anchor = Keyword.get(opts, :create_anchor, false)
    min_score = Keyword.get(opts, :min_score, @resolution_threshold)

    normalized_text = normalize_text(text)

    # Search for existing entity anchors
    result =
      case search_entity_anchors(normalized_text, expected_type, graph_id) do
        {:ok, []} ->
          # No matches - create new entity
          create_new_entity(normalized_text, expected_type, graph_id)

        {:ok, [{entity_id, score}]} when score >= min_score ->
          # Single high-confidence match
          if create_anchor do
            ensure_entity_anchor(entity_id, text, graph_id)
          end

          {:ok, entity_id}

        {:ok, [{_entity_id, score}]} when score < min_score ->
          # Low confidence - create new entity
          create_new_entity(normalized_text, expected_type, graph_id)

        {:ok, candidates} when length(candidates) > 1 ->
          # Multiple matches - check for clear winner
          [{top_id, top_score}, {_, second_score} | _] = candidates

          if top_score >= min_score and top_score - second_score > 0.1 do
            # Clear winner
            if create_anchor do
              ensure_entity_anchor(top_id, text, graph_id)
            end

            {:ok, top_id}
          else
            # Ambiguous
            {:error, :ambiguous, Enum.map(candidates, &elem(&1, 0))}
          end

        {:error, reason} ->
          {:error, reason}
      end

    # Emit telemetry
    duration_ms = System.monotonic_time(:millisecond) - start_time

    {method, confidence} =
      case result do
        {:ok, _} -> {"resolved", 1.0}
        {:error, :ambiguous, _} -> {"ambiguous", 0.5}
        _ -> {"failed", 0.0}
      end

    :telemetry.execute(
      [:mimo, :semantic_store, :resolve],
      %{duration_ms: duration_ms},
      %{method: method, confidence: confidence, type: expected_type}
    )

    result
  end

  @doc """
  Ensures an entity anchor exists for the given entity ID and text.
  Creates one if missing. Idempotent.
  """
  @spec ensure_entity_anchor(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def ensure_entity_anchor(entity_id, text, graph_id \\ @default_graph_id) do
    normalized = normalize_text(text)

    # Check if anchor already exists
    case find_exact_anchor(entity_id, normalized, graph_id) do
      {:ok, _} ->
        :ok

      {:error, :not_found} ->
        # Create new anchor asynchronously
        Task.Supervisor.start_child(Mimo.TaskSupervisor, fn ->
          create_entity_anchor(entity_id, normalized, graph_id)
        end)

        :ok
    end
  end

  @doc """
  Creates a new entity with canonical ID and vector anchor.
  """
  @spec create_new_entity(String.t(), atom(), String.t()) :: {:ok, String.t()}
  def create_new_entity(text, type, graph_id) do
    entity_id = generate_canonical_id(text, type)

    # Create the anchor synchronously to ensure it exists
    case create_entity_anchor(entity_id, text, graph_id) do
      {:ok, _} ->
        {:ok, entity_id}

      {:error, reason} ->
        Logger.warning("Failed to create entity anchor: #{inspect(reason)}")
        # Return ID anyway, anchor will be created later
        {:ok, entity_id}
    end
  end

  # ==========================================================================
  # Private Functions
  # ==========================================================================

  defp search_entity_anchors(text, expected_type, graph_id) do
    # Use vector similarity search
    case Memory.search(text, limit: 5, type: @entity_anchor_type) do
      {:ok, results} ->
        candidates =
          results
          |> Enum.filter(fn r ->
            r.metadata["graph_id"] == graph_id and
              (expected_type == :auto or r.metadata["entity_type"] == to_string(expected_type))
          end)
          |> Enum.map(fn r -> {r.metadata["ref"], r.score} end)
          |> Enum.sort_by(&elem(&1, 1), :desc)

        {:ok, candidates}

      {:error, reason} ->
        Logger.warning("Entity anchor search failed: #{inspect(reason)}")
        # Return empty on search failure, will create new
        {:ok, []}
    end
  end

  defp find_exact_anchor(entity_id, text, graph_id) do
    # Check if exact anchor exists (by category + ref via metadata + content)
    # Note: engrams table uses 'category' not 'type', and stores ref in metadata
    query = """
    SELECT id FROM engrams 
    WHERE category = $1 
      AND content = $2
      AND (metadata->>'graph_id' = $3 OR metadata->>'graph_id' IS NULL)
      AND metadata->>'ref' = $4
    LIMIT 1
    """

    case Ecto.Adapters.SQL.query(Repo, query, [@entity_anchor_type, text, graph_id, entity_id]) do
      {:ok, %{rows: [[id]]}} -> {:ok, id}
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_entity_anchor(entity_id, text, graph_id) do
    Memory.store(%{
      content: text,
      type: @entity_anchor_type,
      ref: entity_id,
      metadata: %{
        "graph_id" => graph_id,
        "entity_type" => extract_type_from_id(entity_id),
        "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
    })
  end

  defp generate_canonical_id(text, type) do
    slug =
      text
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")
      |> String.slice(0, 50)

    type_prefix = if type == :auto, do: "entity", else: to_string(type)
    "#{type_prefix}:#{slug}"
  end

  defp extract_type_from_id(entity_id) do
    case String.split(entity_id, ":", parts: 2) do
      [type, _] -> type
      _ -> "entity"
    end
  end

  defp normalize_text(text) do
    text
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end
end
