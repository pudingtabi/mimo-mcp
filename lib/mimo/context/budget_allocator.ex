defmodule Mimo.Context.BudgetAllocator do
  @moduledoc """
  Model-aware token budget allocation for tiered context delivery.

  SPEC-051: Allocates token budgets across three tiers based on model capabilities.

  Tier 1 (Essential): 5-10% - Critical information needed for immediate task execution
  Tier 2 (Supporting): 15-20% - Important background and related information
  Tier 3 (Background): Remaining - General project context available on-demand

  ## Model Types

  - `:small` - Haiku, GPT-4-mini, Gemini Flash (4K-8K effective context)
  - `:medium` - Opus 4, Sonnet, GPT-4 (16K-32K effective context)
  - `:large` - GPT-4 Turbo, Claude 3.5 (128K+ effective context)

  ## Examples

      BudgetAllocator.allocate(:small, 2000)
      # => %{tier1: 100, tier2: 300, tier3: 1600, total: 2000}

      BudgetAllocator.allocate("haiku", 4000)
      # => %{tier1: 200, tier2: 600, tier3: 3200, total: 4000}
  """

  @type model_type :: :small | :medium | :large | String.t()
  @type budget :: %{
          tier1: non_neg_integer(),
          tier2: non_neg_integer(),
          tier3: non_neg_integer(),
          total: non_neg_integer()
        }

  # Model name to type mappings
  @model_mappings %{
    # Small models (4K-8K effective)
    "haiku" => :small,
    "claude-3-haiku" => :small,
    "gpt-4-mini" => :small,
    "gpt-4o-mini" => :small,
    "gemini-flash" => :small,
    "gemini-1.5-flash" => :small,
    "mistral-small" => :small,
    "llama-3-8b" => :small,
    # Medium models (16K-32K effective)
    "opus" => :medium,
    "opus-4" => :medium,
    "claude-opus-4" => :medium,
    "sonnet" => :medium,
    "claude-3-sonnet" => :medium,
    "claude-3.5-sonnet" => :medium,
    "gpt-4" => :medium,
    "gpt-4-turbo" => :medium,
    "gemini-pro" => :medium,
    "gemini-1.5-pro" => :medium,
    "mistral-medium" => :medium,
    "llama-3-70b" => :medium,
    # Large models (128K+ effective)
    "gpt-4-turbo-128k" => :large,
    "claude-3-opus" => :large,
    "gemini-1.5-pro-1m" => :large,
    "mistral-large" => :large
  }

  # Budget percentages per model type
  @budget_percentages %{
    small: %{tier1: 0.05, tier2: 0.15, tier3: 0.80},
    medium: %{tier1: 0.08, tier2: 0.20, tier3: 0.72},
    large: %{tier1: 0.10, tier2: 0.25, tier3: 0.65}
  }

  # Default effective context windows (for reference)
  @default_max_tokens %{
    small: 2000,
    medium: 8000,
    large: 40_000
  }

  @doc """
  Allocate token budgets across tiers for a given model type and max tokens.

  ## Parameters

    * `model_type` - Model type atom (:small, :medium, :large) or model name string
    * `max_tokens` - Total token budget to allocate (optional, uses defaults if not provided)

  ## Returns

    Map with tier allocations: %{tier1: N, tier2: N, tier3: N, total: N}
  """
  @spec allocate(model_type(), non_neg_integer() | nil) :: budget()
  def allocate(model_type, max_tokens \\ nil)

  def allocate(model_type, max_tokens) when is_binary(model_type) do
    normalized = normalize_model_name(model_type)
    type = Map.get(@model_mappings, normalized, :medium)
    allocate(type, max_tokens)
  end

  def allocate(model_type, max_tokens) when is_atom(model_type) do
    type = if model_type in [:small, :medium, :large], do: model_type, else: :medium
    total = max_tokens || @default_max_tokens[type]
    percentages = @budget_percentages[type]

    # Allocate tier1 and tier2 first, then give remainder to tier3
    # This guarantees tier1 + tier2 + tier3 == total (no rounding drift)
    tier1 = round(total * percentages.tier1)
    tier2 = round(total * percentages.tier2)
    tier3 = total - tier1 - tier2

    %{
      tier1: tier1,
      tier2: tier2,
      tier3: tier3,
      total: total
    }
  end

  @doc """
  Get the model type for a given model name string.

  ## Examples

      BudgetAllocator.model_type("haiku")
      # => :small

      BudgetAllocator.model_type("opus")
      # => :medium
  """
  @spec model_type(String.t() | atom()) :: :small | :medium | :large
  def model_type(model_name) when is_binary(model_name) do
    normalized = normalize_model_name(model_name)
    Map.get(@model_mappings, normalized, :medium)
  end

  def model_type(model_type) when is_atom(model_type) do
    if model_type in [:small, :medium, :large], do: model_type, else: :medium
  end

  @doc """
  Get budget percentages for a model type.
  """
  @spec percentages(model_type()) :: %{tier1: float(), tier2: float(), tier3: float()}
  def percentages(model_type) when is_atom(model_type) do
    type = if model_type in [:small, :medium, :large], do: model_type, else: :medium
    @budget_percentages[type]
  end

  def percentages(model_name) when is_binary(model_name) do
    percentages(model_type(model_name))
  end

  @doc """
  Get the default max tokens for a model type.
  """
  @spec default_max_tokens(model_type()) :: non_neg_integer()
  def default_max_tokens(model_type) when is_atom(model_type) do
    type = if model_type in [:small, :medium, :large], do: model_type, else: :medium
    @default_max_tokens[type]
  end

  def default_max_tokens(model_name) when is_binary(model_name) do
    default_max_tokens(model_type(model_name))
  end

  @doc """
  Check if items fit within a tier budget.

  ## Parameters

    * `items` - List of items with `:tokens` or `:content` fields
    * `budget` - Token budget for the tier

  ## Returns

    Tuple of {fitting_items, remaining_budget}
  """
  @spec fit_to_budget([map()], non_neg_integer()) :: {[map()], non_neg_integer()}
  def fit_to_budget(items, budget) when is_list(items) and is_integer(budget) do
    {fitting, remaining} =
      Enum.reduce_while(items, {[], budget}, fn item, {acc, remaining_budget} ->
        item_tokens = estimate_item_tokens(item)

        if item_tokens <= remaining_budget do
          {:cont, {[item | acc], remaining_budget - item_tokens}}
        else
          {:halt, {acc, remaining_budget}}
        end
      end)

    {Enum.reverse(fitting), remaining}
  end

  @doc """
  Estimate tokens for a single context item.

  Uses a simple character-to-token heuristic (4 chars per token).
  """
  @spec estimate_item_tokens(map()) :: non_neg_integer()
  def estimate_item_tokens(item) when is_map(item) do
    case Map.get(item, :tokens) do
      tokens when is_integer(tokens) ->
        tokens

      _ ->
        content = Map.get(item, :content) || Map.get(item, "content") || ""
        estimate_string_tokens(content)
    end
  end

  @doc """
  Estimate tokens for a string using character count heuristic.

  Approximately 4 characters per token for English text.
  """
  @spec estimate_string_tokens(String.t()) :: non_neg_integer()
  def estimate_string_tokens(text) when is_binary(text) do
    len = String.length(text)
    # ~4 chars per token is a reasonable estimate
    # Return 0 for empty strings
    if len == 0, do: 0, else: max(1, div(len, 4))
  end

  def estimate_string_tokens(_), do: 0

  defp normalize_model_name(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/[_\s]+/, "-")
  end
end
