defmodule Mimo.Brain.Emergence.Pattern do
  @moduledoc """
  SPEC-044: Classifies and stores emergent patterns.

  Emergent patterns are behaviors and abilities that arise from the
  interaction of simpler components at scale - capabilities that were
  not explicitly programmed but emerge naturally from system complexity.

  ## Pattern Types

  - `:workflow` - A sequence of actions that achieves a goal
  - `:inference` - A conclusion drawn from combining knowledge
  - `:heuristic` - A rule of thumb that usually works
  - `:skill` - An ability to do something effectively

  ## Pattern Lifecycle

  1. Detection: Patterns are first detected by the Detector module
  2. Classification: Patterns are classified by type and strength
  3. Storage: Patterns are persisted for tracking
  4. Evolution: Patterns evolve as more occurrences are observed
  5. Promotion: Strong patterns are promoted to explicit capabilities
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Mimo.Repo
  alias Mimo.Brain.EctoJsonMap
  alias Mimo.Brain.EctoJsonList

  @derive {Jason.Encoder,
           only: [
             :id,
             :type,
             :description,
             :components,
             :trigger_conditions,
             :success_rate,
             :occurrences,
             :first_seen,
             :last_seen,
             :strength,
             :evolution,
             :status,
             :metadata
           ]}

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "emergence_patterns" do
    field(:type, Ecto.Enum, values: [:workflow, :inference, :heuristic, :skill])
    field(:description, :string)
    field(:components, EctoJsonList, default: [])
    field(:trigger_conditions, EctoJsonList, default: [])
    field(:success_rate, :float, default: 0.0)
    field(:occurrences, :integer, default: 1)
    field(:first_seen, :utc_datetime_usec)
    field(:last_seen, :utc_datetime_usec)
    field(:strength, :float, default: 0.0)
    field(:evolution, EctoJsonList, default: [])
    field(:status, Ecto.Enum, values: [:active, :promoted, :dormant, :archived], default: :active)
    field(:metadata, EctoJsonMap, default: %{})

    # Pattern signature for deduplication
    field(:signature, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: binary(),
          type: :workflow | :inference | :heuristic | :skill,
          description: String.t(),
          components: list(map()),
          trigger_conditions: list(String.t()),
          success_rate: float(),
          occurrences: integer(),
          first_seen: DateTime.t(),
          last_seen: DateTime.t(),
          strength: float(),
          evolution: list(map()),
          status: :active | :promoted | :dormant | :archived,
          metadata: map(),
          signature: String.t()
        }

  @type_descriptors %{
    workflow: "A sequence of actions that achieves a goal",
    inference: "A conclusion drawn from combining knowledge",
    heuristic: "A rule of thumb that usually works",
    skill: "An ability to do something effectively"
  }

  # ─────────────────────────────────────────────────────────────────
  # Changesets
  # ─────────────────────────────────────────────────────────────────

  def changeset(pattern, attrs) do
    pattern
    |> cast(attrs, [
      :type,
      :description,
      :components,
      :trigger_conditions,
      :success_rate,
      :occurrences,
      :first_seen,
      :last_seen,
      :strength,
      :evolution,
      :status,
      :metadata,
      :signature
    ])
    |> validate_required([:type, :description])
    |> validate_number(:success_rate, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:strength, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:occurrences, greater_than_or_equal_to: 1)
    |> unique_constraint(:signature, name: "emergence_patterns_signature_index")
    |> put_default_timestamps()
    |> generate_signature()
  end

  defp put_default_timestamps(changeset) do
    now = DateTime.utc_now()

    changeset
    |> put_change_if_nil(:first_seen, now)
    |> put_change_if_nil(:last_seen, now)
  end

  defp put_change_if_nil(changeset, field, value) do
    case get_field(changeset, field) do
      nil -> put_change(changeset, field, value)
      _ -> changeset
    end
  end

  defp generate_signature(changeset) do
    # Only generate signature for new records (inserts), not updates
    # This prevents unique constraint violations during record_occurrence
    if changeset.data.id do
      # Existing record - don't change signature
      changeset
    else
      # New record - generate signature
      type = get_field(changeset, :type)
      components = get_field(changeset, :components) || []

      if type && components != [] do
        hash_input = "#{type}:#{Jason.encode!(components)}"

        signature =
          :crypto.hash(:sha256, hash_input) |> Base.encode16(case: :lower) |> String.slice(0, 16)

        put_change(changeset, :signature, signature)
      else
        changeset
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Public API
  # ─────────────────────────────────────────────────────────────────

  @doc """
  Creates a new pattern from detected data.
  """
  @spec create(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Finds or creates a pattern by signature.
  If found, increments occurrence count and updates last_seen.
  Handles race conditions with retry on constraint violation.
  """
  @spec find_or_create(map()) :: {:ok, t()} | {:error, term()}
  def find_or_create(attrs) do
    # Generate signature for lookup
    type = attrs[:type]
    components = attrs[:components] || []
    hash_input = "#{type}:#{Jason.encode!(components)}"

    signature =
      :crypto.hash(:sha256, hash_input) |> Base.encode16(case: :lower) |> String.slice(0, 16)

    # Add signature to attrs for insert
    attrs_with_sig = Map.put(attrs, :signature, signature)

    case get_by_signature(signature) do
      nil -> create_with_retry(attrs_with_sig, signature)
      existing -> record_occurrence(existing)
    end
  end

  # Handle race condition: if insert fails due to unique constraint, find and update
  defp create_with_retry(attrs, signature) do
    case create(attrs) do
      {:ok, pattern} ->
        {:ok, pattern}

      {:error, %Ecto.Changeset{} = changeset} ->
        if constraint_error?(changeset, "emergence_patterns_signature_index") do
          # Another process inserted the pattern - find and update it
          retry_after_constraint_error(signature)
        else
          {:error, changeset}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    # Handle Ecto.ConstraintError raised when constraint is violated
    e in Ecto.ConstraintError ->
      if e.constraint == "emergence_patterns_signature_index" do
        retry_after_constraint_error(signature)
      else
        reraise e, __STACKTRACE__
      end
  end

  defp retry_after_constraint_error(signature) do
    case get_by_signature(signature) do
      nil -> {:error, :race_condition_unresolved}
      existing -> record_occurrence(existing)
    end
  end

  defp constraint_error?(%Ecto.Changeset{errors: errors}, constraint_name) do
    Enum.any?(errors, fn
      {_field, {_msg, [constraint: :unique, constraint_name: ^constraint_name]}} -> true
      _ -> false
    end)
  end

  @doc """
  Gets a pattern by signature.
  """
  @spec get_by_signature(String.t()) :: t() | nil
  def get_by_signature(signature) do
    from(p in __MODULE__, where: p.signature == ^signature)
    |> Repo.one()
  end

  @doc """
  Records a new occurrence of the pattern.
  Updates occurrences, last_seen, and recalculates strength.
  """
  @spec record_occurrence(t()) :: {:ok, t()} | {:error, term()}
  def record_occurrence(pattern) do
    new_occurrences = pattern.occurrences + 1
    new_strength = calculate_strength(pattern, new_occurrences)

    evolution_entry = %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      occurrences: new_occurrences,
      strength: new_strength
    }

    pattern
    |> changeset(%{
      occurrences: new_occurrences,
      last_seen: DateTime.utc_now(),
      strength: new_strength,
      evolution: pattern.evolution ++ [evolution_entry]
    })
    |> Repo.update()
  end

  @doc """
  Records a success or failure for the pattern.
  Updates success_rate based on weighted moving average.
  """
  @spec record_outcome(t(), boolean()) :: {:ok, t()} | {:error, term()}
  def record_outcome(pattern, success?) do
    # Weighted moving average: new_rate = old_rate * 0.9 + outcome * 0.1
    weight = 0.1
    outcome = if success?, do: 1.0, else: 0.0
    new_rate = pattern.success_rate * (1 - weight) + outcome * weight

    pattern
    |> changeset(%{success_rate: new_rate})
    |> Repo.update()
  end

  @doc """
  Lists patterns by type and status.
  """
  @spec list(keyword()) :: [t()]
  def list(opts \\ []) do
    type = Keyword.get(opts, :type)
    status = Keyword.get(opts, :status, :active)
    limit = Keyword.get(opts, :limit, 50)
    order = Keyword.get(opts, :order, :desc)

    query = from(p in __MODULE__)

    query = if type, do: where(query, [p], p.type == ^type), else: query
    query = if status, do: where(query, [p], p.status == ^status), else: query

    query
    |> order_by([p], [{^order, p.strength}])
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Gets patterns ready for promotion based on thresholds.
  """
  @spec promotion_candidates(keyword()) :: [t()]
  def promotion_candidates(opts \\ []) do
    min_occurrences = Keyword.get(opts, :min_occurrences, 10)
    min_success_rate = Keyword.get(opts, :min_success_rate, 0.8)
    min_strength = Keyword.get(opts, :min_strength, 0.75)

    from(p in __MODULE__,
      where: p.status == :active,
      where: p.occurrences >= ^min_occurrences,
      where: p.success_rate >= ^min_success_rate,
      where: p.strength >= ^min_strength,
      order_by: [desc: p.strength]
    )
    |> Repo.all()
  end

  @doc """
  Marks a pattern as promoted.
  """
  @spec promote(t()) :: {:ok, t()} | {:error, term()}
  def promote(pattern) do
    pattern
    |> changeset(%{status: :promoted})
    |> Repo.update()
  end

  @doc """
  Gets the strongest pattern of each type.
  """
  @spec strongest_by_type() :: %{atom() => t() | nil}
  def strongest_by_type do
    [:workflow, :inference, :heuristic, :skill]
    |> Enum.map(fn type ->
      strongest =
        from(p in __MODULE__,
          where: p.type == ^type and p.status == :active,
          order_by: [desc: p.strength],
          limit: 1
        )
        |> Repo.one()

      {type, strongest}
    end)
    |> Map.new()
  end

  @doc """
  Gets patterns that are improving (strength increasing over time).
  """
  @spec improving(keyword()) :: [t()]
  def improving(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    from(p in __MODULE__,
      where: p.status == :active,
      order_by: [desc: p.strength],
      limit: ^limit
    )
    |> Repo.all()
    |> Enum.filter(&pattern_improving?/1)
  end

  @doc """
  Gets patterns that are declining (strength decreasing over time).
  """
  @spec declining(keyword()) :: [t()]
  def declining(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    from(p in __MODULE__,
      where: p.status == :active,
      order_by: [asc: p.strength],
      limit: ^limit
    )
    |> Repo.all()
    |> Enum.filter(&pattern_declining?/1)
  end

  @doc """
  Gets count of all patterns.
  """
  @spec count_all() :: integer()
  def count_all do
    Repo.aggregate(__MODULE__, :count, :id)
  end

  @doc """
  Gets count of promoted patterns.
  """
  @spec count_promoted() :: integer()
  def count_promoted do
    from(p in __MODULE__, where: p.status == :promoted)
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Gets average success rate across all active patterns.
  """
  @spec avg_success_rate() :: float()
  def avg_success_rate do
    from(p in __MODULE__, where: p.status == :active)
    |> Repo.aggregate(:avg, :success_rate) || 0.0
  end

  @doc """
  Gets count of patterns by status, grouped.
  """
  @spec count_by_status() :: %{atom() => integer()}
  def count_by_status do
    from(p in __MODULE__,
      group_by: p.status,
      select: {p.status, count(p.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Gets recent patterns within the last N days.
  """
  @spec count_recent(keyword()) :: integer()
  def count_recent(opts \\ []) do
    days = Keyword.get(opts, :days, 7)
    since = DateTime.utc_now() |> DateTime.add(-days * 24 * 60 * 60, :second)

    from(p in __MODULE__,
      where: p.first_seen >= ^since
    )
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Gets promotion count in the last N days.
  """
  @spec promotions_recent(keyword()) :: integer()
  def promotions_recent(opts \\ []) do
    days = Keyword.get(opts, :days, 30)
    since = DateTime.utc_now() |> DateTime.add(-days * 24 * 60 * 60, :second)

    from(p in __MODULE__,
      where: p.status == :promoted and p.updated_at >= ^since
    )
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Gets unique domains covered by patterns.
  """
  @spec unique_domains() :: [String.t()]
  def unique_domains do
    from(p in __MODULE__, where: p.status == :active)
    |> Repo.all()
    |> Enum.flat_map(fn pattern ->
      pattern.metadata[:domains] || []
    end)
    |> Enum.uniq()
  end

  @doc """
  Gets unique tool combinations from workflow patterns.
  """
  @spec unique_tool_combos() :: [[String.t()]]
  def unique_tool_combos do
    from(p in __MODULE__,
      where: p.type == :workflow and p.status == :active
    )
    |> Repo.all()
    |> Enum.map(fn pattern ->
      pattern.components
      |> Enum.map(&(&1["tool"] || &1[:tool]))
      |> Enum.reject(&is_nil/1)
    end)
    |> Enum.uniq()
  end

  @doc """
  DEMAND 3: Search patterns by description for pattern library matching.

  Used by prepare_context to find relevant patterns for a given query.
  Returns patterns sorted by relevance (simple keyword matching for now).
  """
  @spec search_by_description(String.t(), keyword()) :: [t()]
  def search_by_description(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    status = Keyword.get(opts, :status, :active)

    # Normalize query for matching
    query_lower = String.downcase(query)
    query_words = String.split(query_lower, ~r/\s+/) |> Enum.filter(&(String.length(&1) > 2))

    # Get all active patterns and score by keyword match
    from(p in __MODULE__,
      where: p.status == ^status,
      order_by: [desc: p.strength]
    )
    |> Repo.all()
    |> Enum.map(fn pattern ->
      desc_lower = String.downcase(pattern.description || "")

      # Calculate match score based on word overlap
      match_count =
        Enum.count(query_words, fn word ->
          String.contains?(desc_lower, word)
        end)

      word_count = max(length(query_words), 1)
      match_score = match_count / word_count

      # Combine with pattern strength for final score
      final_score = match_score * 0.6 + (pattern.strength || 0) * 0.4

      {pattern, final_score}
    end)
    |> Enum.filter(fn {_pattern, score} -> score > 0.1 end)
    |> Enum.sort_by(fn {_pattern, score} -> score end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {pattern, _score} -> pattern end)
  end

  @doc """
  Returns the type descriptor for a pattern type.
  """
  @spec type_descriptor(atom()) :: String.t()
  def type_descriptor(type), do: @type_descriptors[type] || "Unknown pattern type"

  # ─────────────────────────────────────────────────────────────────
  # Private Helpers
  # ─────────────────────────────────────────────────────────────────

  defp calculate_strength(pattern, occurrences) do
    # Strength factors:
    # - Occurrence frequency (more = stronger)
    # - Success rate (higher = stronger)
    # - Recency (recent patterns weighted higher)
    # - Age (established patterns get bonus)

    occurrence_factor = min(1.0, occurrences / 50)
    success_factor = pattern.success_rate

    # Recency: patterns used in last 7 days get boost
    days_since_use = DateTime.diff(DateTime.utc_now(), pattern.last_seen, :day)
    recency_factor = max(0.5, 1.0 - days_since_use / 30)

    # Age bonus: established patterns get slight boost
    days_old = DateTime.diff(DateTime.utc_now(), pattern.first_seen, :day)
    age_factor = min(1.1, 1.0 + days_old / 365)

    # Weighted combination
    strength = (occurrence_factor * 0.3 + success_factor * 0.4 + recency_factor * 0.3) * age_factor
    Float.round(min(1.0, strength), 4)
  end

  defp pattern_improving?(pattern) do
    # Check if strength has been increasing in recent evolution
    case pattern.evolution do
      [] ->
        false

      [_single] ->
        false

      entries when length(entries) >= 2 ->
        recent = Enum.take(entries, -3)
        strengths = Enum.map(recent, &(&1[:strength] || &1["strength"]))

        case strengths do
          [a, b] -> b > a
          [a, b, c] -> c > b and b > a
          _ -> false
        end
    end
  end

  defp pattern_declining?(pattern) do
    # Check if strength has been decreasing in recent evolution
    case pattern.evolution do
      [] ->
        false

      [_single] ->
        false

      entries when length(entries) >= 2 ->
        recent = Enum.take(entries, -3)
        strengths = Enum.map(recent, &(&1[:strength] || &1["strength"]))

        case strengths do
          [a, b] -> b < a
          [a, b, c] -> c < b and b < a
          _ -> false
        end
    end
  end
end
