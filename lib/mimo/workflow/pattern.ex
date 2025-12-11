defmodule Mimo.Workflow.Pattern do
  @moduledoc """
  SPEC-053: Workflow Pattern Schema

  Represents a learned workflow pattern extracted from tool usage logs.
  Patterns capture successful tool sequences, preconditions, and success rates.

  ## Fields

    * `id` - Unique pattern identifier
    * `name` - Human-readable pattern name
    * `description` - Pattern description
    * `category` - Pattern category (:debugging, :file_operations, :code_navigation, :context_gathering, :project_setup)
    * `preconditions` - Conditions that must be met before execution
    * `steps` - Ordered list of tool calls
    * `bindings` - Parameter bindings for step arguments
    * `success_rate` - Historical success rate (0.0-1.0)
    * `avg_token_savings` - Average token savings when using this pattern
    * `usage_count` - Number of times pattern has been used
    * `confidence_threshold` - Minimum confidence for auto-execution
    * `timeout_ms` - Maximum execution time in milliseconds
    * `metadata` - Additional pattern metadata
    * `tags` - Categorization tags
    * `created_from` - Session IDs that contributed to this pattern
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type category :: :debugging | :file_operations | :code_navigation | :context_gathering | :project_setup | :custom

  @type precondition :: %{
          type: :file_exists | :memory_contains | :code_symbol_defined | :context_has_key | :project_indexed | :custom,
          check: atom(),
          key: String.t() | nil,
          params: map(),
          description: String.t()
        }

  @type binding :: %{
          name: String.t(),
          type: :string | :integer | :float | :boolean | :map | :list,
          required: boolean(),
          extractor: String.t() | nil,
          default: any()
        }

  @type retry_policy :: %{
          max_attempts: integer(),
          backoff_ms: integer(),
          timeout_ms: integer(),
          conditions: [map()]
        }

  @type step :: %{
          tool: String.t(),
          name: String.t() | nil,
          operation: String.t(),
          args: map(),
          params: map(),
          dynamic_bindings: [map()],
          retry_policy: retry_policy() | nil,
          timeout_ms: integer() | nil,
          description: String.t() | nil
        }

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          description: String.t() | nil,
          category: category(),
          preconditions: [precondition()],
          steps: [step()],
          bindings: [binding()],
          success_rate: float(),
          avg_token_savings: integer(),
          usage_count: integer(),
          last_used: DateTime.t() | nil,
          confidence_threshold: float(),
          timeout_ms: integer() | nil,
          metadata: map(),
          tags: [String.t()],
          created_from: [String.t()],
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @categories [:debugging, :file_operations, :code_navigation, :context_gathering, :project_setup, :custom]

  @primary_key {:id, :string, autogenerate: false}
  schema "workflow_patterns" do
    field :name, :string
    field :description, :string
    field :category, Ecto.Enum, values: @categories, default: :custom
    field :preconditions, {:array, :map}, default: []
    field :steps, {:array, :map}, default: []
    field :bindings, {:array, :map}, default: []
    field :success_rate, :float, default: 0.0
    field :avg_token_savings, :integer, default: 0
    field :usage_count, :integer, default: 0
    field :last_used, :utc_datetime_usec
    field :confidence_threshold, :float, default: 0.7
    field :timeout_ms, :integer
    field :metadata, :map, default: %{}
    field :tags, {:array, :string}, default: []
    field :created_from, {:array, :string}, default: []

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:id, :name, :steps]
  @optional_fields [
    :description,
    :category,
    :preconditions,
    :bindings,
    :success_rate,
    :avg_token_savings,
    :usage_count,
    :last_used,
    :confidence_threshold,
    :timeout_ms,
    :metadata,
    :tags,
    :created_from
  ]

  @doc """
  Creates a changeset for a workflow pattern.
  """
  def changeset(pattern, attrs) do
    pattern
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:success_rate, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:confidence_threshold,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
    |> validate_inclusion(:category, @categories)
    |> validate_steps()
  end

  @doc """
  Creates a new pattern with a generated ID.
  """
  def new(attrs) do
    id = attrs[:id] || generate_id(attrs[:name] || "pattern")

    %__MODULE__{}
    |> changeset(Map.put(attrs, :id, id))
  end

  @doc """
  Updates an existing pattern's success metrics.
  """
  def update_success_metrics(pattern, success?, token_savings \\ 0) do
    new_usage = pattern.usage_count + 1

    new_success_rate =
      if success? do
        (pattern.success_rate * pattern.usage_count + 1.0) / new_usage
      else
        (pattern.success_rate * pattern.usage_count) / new_usage
      end

    new_avg_savings =
      if new_usage > 0 do
        div(pattern.avg_token_savings * pattern.usage_count + token_savings, new_usage)
      else
        token_savings
      end

    pattern
    |> changeset(%{
      success_rate: new_success_rate,
      avg_token_savings: new_avg_savings,
      usage_count: new_usage,
      last_used: DateTime.utc_now()
    })
  end

  @doc """
  Returns the list of valid categories.
  """
  def categories, do: @categories

  # Private functions

  defp generate_id(name) do
    timestamp = System.os_time(:millisecond)
    random = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    slug = name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_")
    "#{slug}_#{timestamp}_#{random}"
  end

  defp validate_steps(changeset) do
    steps = get_field(changeset, :steps) || []

    if Enum.all?(steps, &valid_step?/1) do
      changeset
    else
      add_error(changeset, :steps, "contains invalid step definitions")
    end
  end

  defp valid_step?(%{"tool" => tool}) when is_binary(tool), do: true
  defp valid_step?(%{tool: tool}) when is_binary(tool), do: true
  defp valid_step?(_), do: false
end
