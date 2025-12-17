defmodule Mimo.Brain.Engram do
  @moduledoc """
  Engram - the memory storage record.

  This is an Ecto schema for storing memories in SQLite with embeddings.
  Embeddings and metadata are stored as JSON text or binary blobs.

  NOTE: Terms like "brain" and "engram" are organizational metaphors.
  This is a database record with configurable TTL, not neuroscience.
  See docs/ANTI-SLOP.md for honest assessment.

  ## Decay Fields (SPEC-003)

  The following fields support memory decay/forgetting:
  - `access_count` - Number of times this memory has been accessed
  - `last_accessed_at` - Timestamp of last access
  - `decay_rate` - Rate at which memory decays (default 0.01 = 69 day half-life)
  - `protected` - Whether this memory is protected from forgetting

  ## Passive Memory Fields (SPEC-012)

  - `thread_id` - Links memory to the thread/session that created it
  - `original_importance` - The initial importance score (for tracking decay)

  ## Project Scoping & Auto-Tagging

  - `project_id` - Workspace/project identifier for memory isolation (default: "global")
  - `tags` - LLM auto-generated tags for categorization and filtering

  ## Embedding Storage Optimization (SPEC-031 & SPEC-033)

  The engram supports three embedding formats:

  ### Float32 (Legacy)
  - `embedding` - JSON-encoded list of floats (4KB for 1024-dim)
  - `embedding_dim` - Dimension of the embedding

  ### Int8 Quantized (Optimized - SPEC-031)
  - `embedding_int8` - Binary blob with quantized values (256 bytes for 256-dim)
  - `embedding_scale` - Scale factor for dequantization
  - `embedding_offset` - Offset for dequantization

  ### Binary Quantized (Ultra-fast pre-filtering - SPEC-033)
  - `embedding_binary` - Binary blob with sign bits (32 bytes for 256-dim)

  Int8 storage provides 16x reduction compared to legacy float32:
  - 1024-dim float32 JSON: ~20KB
  - 256-dim int8 binary: ~272 bytes (256 + scale/offset)

  Binary storage enables ultra-fast Hamming distance pre-filtering:
  - 256-dim binary: 32 bytes
  - Hamming distance: ~10x faster than int8 cosine similarity

  ## Temporal Memory Chains (SPEC-034)

  Memory version tracking (supersession):
  - `supersedes_id` - Points to the memory this one supersedes (if any)
  - `superseded_at` - Timestamp when this memory was superseded (NULL = current/active)
  - `supersession_type` - Type: "update", "correction", "refinement", "merge"

  When a memory is superseded, it remains in the database but is excluded from
  default searches. This allows full version history via supersession chains.

  ## Importance-Decay Mapping (SPEC-012)

  | Importance | Decay Rate | Half-Life |
  |------------|------------|-----------|
  | 0.9-1.0    | 0.0001     | 693 days  |
  | 0.7-0.9    | 0.001      | 69 days   |
  | 0.5-0.7    | 0.005      | 14 days   |
  | 0.3-0.5    | 0.02       | 3.5 days  |
  | <0.3       | 0.1        | 17 hours  |
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Mimo.Vector.Math

  # Engrams use integer IDs (existing database)
  # Threads/Interactions use binary_id (new tables)

  schema "engrams" do
    field(:content, :string)
    field(:category, :string)
    field(:importance, :float, default: 0.5)

    # Float32 embedding storage (legacy, kept for backward compatibility)
    # These use custom Ecto type that serializes to JSON
    field(:embedding, Mimo.Brain.EctoJsonList, default: [])
    field(:metadata, Mimo.Brain.EctoJsonMap, default: %{})

    # Decay/forgetting fields (SPEC-003)
    field(:access_count, :integer, default: 0)
    field(:last_accessed_at, :naive_datetime_usec)
    field(:decay_rate, :float, default: 0.01)
    field(:protected, :boolean, default: false)

    # Passive Memory fields (SPEC-012)
    field(:original_importance, :float)
    field(:thread_id, :binary_id)

    # Project scoping & auto-tagging
    field(:project_id, :string, default: "global")
    field(:tags, Mimo.Brain.EctoJsonList, default: [])

    # Embedding dimension tracking (SPEC-031)
    # Default 256 for MRL-truncated embeddings, 1024 for legacy full embeddings
    field(:embedding_dim, :integer, default: 256)

    # Int8 quantized embedding storage (SPEC-031 Phase 2)
    # Binary blob for quantized embedding values
    field(:embedding_int8, :binary)
    # Scale factor for dequantization: float = (int8 + 128) * scale + offset
    field(:embedding_scale, :float)
    # Offset for dequantization
    field(:embedding_offset, :float)

    # Binary quantized embedding storage (SPEC-033 Phase 3a)
    # Binary blob with sign bits for ultra-fast Hamming distance pre-filtering
    # 256-dim embedding = 32 bytes (1 bit per dimension)
    field(:embedding_binary, :binary)

    # Temporal Memory Chains fields (SPEC-034)
    # Points to the memory this one supersedes (if any)
    field(:supersedes_id, :integer)
    # Timestamp when this memory was superseded (NULL = current/active)
    field(:superseded_at, :utc_datetime)
    # Type of supersession: "update", "correction", "refinement", "merge"
    field(:supersession_type, :string)

    # Knowledge syncing field (for auto-learning from memories)
    # Timestamp when this memory was synced to knowledge graph (NULL = not yet synced)
    field(:knowledge_synced_at, :utc_datetime)

    # Temporal validity (SPEC-060)
    # valid_from/valid_until allow time-bounded facts; validity_source tracks origin
    field(:valid_from, :utc_datetime)
    field(:valid_until, :utc_datetime)
    field(:validity_source, :string, default: "inferred")

    # Link to source interactions (join table with binary_id)
    # many_to_many :interactions, Mimo.Brain.Interaction, join_through: "interaction_engrams"

    timestamps()
  end

  @valid_categories [
    "fact",
    "action",
    "observation",
    "plan",
    "episode",
    "procedure",
    "entity_anchor"
  ]

  def changeset(engram, attrs) do
    engram
    |> cast(attrs, [
      :content,
      :category,
      :importance,
      :embedding,
      :metadata,
      :access_count,
      :last_accessed_at,
      :decay_rate,
      :protected,
      :original_importance,
      :thread_id,
      :project_id,
      :tags,
      :embedding_dim,
      :embedding_int8,
      :embedding_scale,
      :embedding_offset,
      :embedding_binary,
      # SPEC-034: Temporal Memory Chains
      :supersedes_id,
      :superseded_at,
      :supersession_type,
      # Knowledge syncing
      :knowledge_synced_at,
      # SPEC-060: Temporal validity
      :valid_from,
      :valid_until,
      :validity_source
    ])
    |> validate_required([:content, :category])
    |> validate_inclusion(:category, @valid_categories)
    |> validate_number(:importance, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:decay_rate, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_inclusion(:supersession_type, ["update", "correction", "refinement", "merge", nil])
    |> validate_inclusion(:validity_source, [
      "explicit",
      "inferred",
      "superseded",
      "corrected",
      "expired",
      nil
    ])
    |> validate_no_self_supersession()
    |> set_original_importance()
    |> set_decay_rate_from_importance()
  end

  @doc """
  Check if the engram is valid at a given datetime (SPEC-060).
  """
  @spec valid_at?(%__MODULE__{}, DateTime.t()) :: boolean()
  def valid_at?(%__MODULE__{} = engram, %DateTime{} = datetime) do
    from_ok = is_nil(engram.valid_from) or DateTime.compare(engram.valid_from, datetime) != :gt
    until_ok = is_nil(engram.valid_until) or DateTime.compare(engram.valid_until, datetime) == :gt
    from_ok and until_ok
  end

  @doc """
  Check if the engram is currently valid.
  """
  @spec currently_valid?(%__MODULE__{}) :: boolean()
  def currently_valid?(%__MODULE__{} = engram) do
    valid_at?(engram, DateTime.utc_now())
  end

  @doc """
  Invalidate an engram by setting valid_until to now and updating validity_source.
  """
  @spec invalidate(%__MODULE__{}, String.t()) :: Ecto.Changeset.t()
  def invalidate(%__MODULE__{} = engram, reason \\ "superseded") do
    change(engram, %{valid_until: DateTime.utc_now(), validity_source: reason})
  end

  # SPEC-034: Prevent self-supersession (engram cannot supersede itself)
  defp validate_no_self_supersession(changeset) do
    case {get_field(changeset, :id), get_change(changeset, :supersedes_id)} do
      {id, supersedes_id} when is_integer(id) and id == supersedes_id ->
        add_error(changeset, :supersedes_id, "cannot supersede itself")

      _ ->
        changeset
    end
  end

  @doc """
  Converts float32 embedding to int8 quantized format.

  Returns {:ok, %{embedding_int8: binary, embedding_scale: float, embedding_offset: float}}
  or {:error, reason}
  """
  @spec quantize_embedding(list(float())) ::
          {:ok, %{embedding_int8: binary(), embedding_scale: float(), embedding_offset: float()}}
          | {:error, atom()}
  def quantize_embedding([]), do: {:error, :empty_embedding}

  def quantize_embedding(embedding) when is_list(embedding) do
    case Math.quantize_int8(embedding) do
      {:ok, {binary, scale, offset}} ->
        {:ok,
         %{
           embedding_int8: binary,
           embedding_scale: scale,
           embedding_offset: offset
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Dequantizes int8 embedding back to float32 format.

  Returns {:ok, list(float())} or {:error, reason}
  """
  @spec dequantize_embedding(binary(), float(), float()) ::
          {:ok, list(float())} | {:error, atom()}
  def dequantize_embedding(nil, _, _), do: {:error, :nil_embedding}
  def dequantize_embedding(_binary, nil, _), do: {:error, :nil_scale}
  def dequantize_embedding(_binary, _, nil), do: {:error, :nil_offset}

  def dequantize_embedding(binary, scale, offset)
      when is_binary(binary) and is_number(scale) and is_number(offset) do
    Math.dequantize_int8(binary, scale, offset)
  end

  @doc """
  Gets the embedding from an engram, preferring int8 if available.

  Automatically dequantizes int8 to float32 if needed.
  """
  @spec get_embedding(%__MODULE__{}) :: {:ok, list(float())} | {:error, atom()}
  def get_embedding(%__MODULE__{embedding_int8: nil, embedding: embedding})
      when is_list(embedding) and length(embedding) > 0 do
    {:ok, embedding}
  end

  def get_embedding(%__MODULE__{
        embedding_int8: int8,
        embedding_scale: scale,
        embedding_offset: offset
      })
      when is_binary(int8) and byte_size(int8) > 0 do
    dequantize_embedding(int8, scale, offset)
  end

  def get_embedding(%__MODULE__{embedding: embedding})
      when is_list(embedding) and length(embedding) > 0 do
    {:ok, embedding}
  end

  def get_embedding(_), do: {:error, :no_embedding}

  @doc """
  Gets the raw int8 binary embedding (for int8 similarity calculations).

  Returns {:ok, binary} or {:error, reason}
  """
  @spec get_embedding_int8(%__MODULE__{}) :: {:ok, binary()} | {:error, atom()}
  def get_embedding_int8(%__MODULE__{embedding_int8: int8})
      when is_binary(int8) and byte_size(int8) > 0 do
    {:ok, int8}
  end

  def get_embedding_int8(_), do: {:error, :no_int8_embedding}

  @doc """
  Gets the binary embedding for ultra-fast Hamming distance pre-filtering.

  Returns {:ok, binary} or {:error, reason}
  """
  @spec get_embedding_binary(%__MODULE__{}) :: {:ok, binary()} | {:error, atom()}
  def get_embedding_binary(%__MODULE__{embedding_binary: binary})
      when is_binary(binary) and byte_size(binary) > 0 do
    {:ok, binary}
  end

  def get_embedding_binary(_), do: {:error, :no_binary_embedding}

  @doc """
  Checks if the engram has an int8 quantized embedding.
  """
  @spec has_int8_embedding?(%__MODULE__{}) :: boolean()
  def has_int8_embedding?(%__MODULE__{embedding_int8: int8})
      when is_binary(int8) and byte_size(int8) > 0,
      do: true

  def has_int8_embedding?(_), do: false

  @doc """
  Checks if the engram has a binary embedding for Hamming pre-filtering.
  """
  @spec has_binary_embedding?(%__MODULE__{}) :: boolean()
  def has_binary_embedding?(%__MODULE__{embedding_binary: binary})
      when is_binary(binary) and byte_size(binary) > 0,
      do: true

  def has_binary_embedding?(_), do: false

  # When creating, preserve original importance for decay tracking
  defp set_original_importance(changeset) do
    case {get_field(changeset, :original_importance), get_change(changeset, :importance)} do
      {nil, importance} when is_number(importance) ->
        put_change(changeset, :original_importance, importance)

      _ ->
        changeset
    end
  end

  # Set decay rate based on importance (SPEC-012 mapping)
  defp set_decay_rate_from_importance(changeset) do
    # Only set if decay_rate not explicitly provided
    case get_change(changeset, :decay_rate) do
      nil ->
        importance = get_field(changeset, :importance) || 0.5
        decay_rate = importance_to_decay_rate(importance)
        put_change(changeset, :decay_rate, decay_rate)

      _ ->
        changeset
    end
  end

  @doc """
  Maps importance score to decay rate.

  Higher importance = lower decay rate = longer memory retention.
  Based on exponential decay: half_life = ln(2) / decay_rate

  NOTE: These rates are configurable via config :mimo_mcp, :decay_rates
  They are MANUALLY TUNED, not empirically validated. See docs/ANTI-SLOP.md.
  """
  def importance_to_decay_rate(importance) when importance >= 0.9 do
    decay_config()[:critical] || 0.0001
  end

  def importance_to_decay_rate(importance) when importance >= 0.7 do
    decay_config()[:high] || 0.001
  end

  def importance_to_decay_rate(importance) when importance >= 0.5 do
    decay_config()[:medium] || 0.005
  end

  def importance_to_decay_rate(importance) when importance >= 0.3 do
    decay_config()[:low] || 0.02
  end

  def importance_to_decay_rate(_importance) do
    decay_config()[:ephemeral] || 0.1
  end

  defp decay_config do
    Application.get_env(:mimo_mcp, :decay_rates, %{})
  end

  @doc """
  Calculates the current effective importance after decay.

  Uses exponential decay: importance(t) = original * e^(-decay_rate * days)
  """
  def effective_importance(%__MODULE__{} = engram) do
    original = engram.original_importance || engram.importance
    decay_rate = engram.decay_rate || 0.01

    days_since_creation =
      case engram.inserted_at do
        nil ->
          0

        inserted_at ->
          NaiveDateTime.diff(NaiveDateTime.utc_now(), inserted_at, :second) / 86_400.0
      end

    original * :math.exp(-decay_rate * days_since_creation)
  end

  # =============================================================================
  # SPEC-034: Temporal Memory Chain Helpers
  # =============================================================================

  @doc """
  Checks if this engram is currently active (not superseded).
  """
  @spec active?(%__MODULE__{}) :: boolean()
  def active?(%__MODULE__{superseded_at: nil}), do: true
  def active?(%__MODULE__{superseded_at: _}), do: false

  @doc """
  Checks if this engram has been superseded.
  """
  @spec superseded?(%__MODULE__{}) :: boolean()
  def superseded?(%__MODULE__{superseded_at: nil}), do: false
  def superseded?(%__MODULE__{superseded_at: _}), do: true

  @doc """
  Checks if this engram is part of a supersession chain (has superseded another).
  """
  @spec has_predecessor?(%__MODULE__{}) :: boolean()
  def has_predecessor?(%__MODULE__{supersedes_id: nil}), do: false
  def has_predecessor?(%__MODULE__{supersedes_id: _}), do: true

  @doc """
  Returns a summary map for chain display.
  """
  @spec chain_summary(%__MODULE__{}) :: map()
  def chain_summary(%__MODULE__{} = engram) do
    %{
      id: engram.id,
      content: String.slice(engram.content || "", 0, 100),
      category: engram.category,
      importance: engram.importance,
      created_at: engram.inserted_at,
      supersedes_id: engram.supersedes_id,
      superseded_at: engram.superseded_at,
      supersession_type: engram.supersession_type,
      active: active?(engram)
    }
  end
end
