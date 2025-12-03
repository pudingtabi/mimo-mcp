defmodule Mimo.Brain.Reflector.Config do
  @moduledoc """
  Configuration for the Reflective Intelligence System.

  Part of SPEC-043: Reflective Intelligence System.

  Provides runtime configuration for reflection behavior including:
  - Quality thresholds
  - Iteration limits
  - Dimension weights
  - Auto-reflection rules
  - Output formatting

  ## Configuration

  Set in config/config.exs:

      config :mimo, Mimo.Brain.Reflector,
        enabled: true,
        default_threshold: 0.75,
        max_iterations: 3,
        auto_reflect_tools: [:file_read, :terminal_execute, :search],
        skip_reflection_for: [:memory_search, :list_directory],
        confidence_output: :structured,
        store_all_reflections: false,
        weights: %{
          correctness: 0.25,
          completeness: 0.20,
          confidence: 0.20,
          clarity: 0.15,
          grounding: 0.15,
          error_penalty: 0.30
        }
  """

  @default_config %{
    enabled: true,
    default_threshold: 0.70,
    max_iterations: 3,
    auto_reflect_tools: [:file, :terminal, :search, :fetch, :browser],
    skip_reflection_for: [:memory, :list_procedures, :awakening_status],
    confidence_output: :structured,
    store_all_reflections: false,
    # Use fast mode for outputs under this length
    fast_mode_threshold: 500,
    weights: %{
      correctness: 0.25,
      completeness: 0.20,
      confidence: 0.20,
      clarity: 0.15,
      grounding: 0.15,
      error_penalty: 0.30
    }
  }

  @doc """
  Get the full configuration with defaults.
  """
  @spec get() :: map()
  def get do
    app_config = Application.get_env(:mimo, Mimo.Brain.Reflector, %{})
    Map.merge(@default_config, Enum.into(app_config, %{}))
  end

  @doc """
  Get a specific configuration value.
  """
  @spec get(atom()) :: term()
  def get(key) when is_atom(key) do
    Map.get(get(), key)
  end

  @doc """
  Get a specific configuration value with default.
  """
  @spec get(atom(), term()) :: term()
  def get(key, default) when is_atom(key) do
    Map.get(get(), key, default)
  end

  @doc """
  Check if reflection is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    get(:enabled)
  end

  @doc """
  Get the default quality threshold.
  """
  @spec default_threshold() :: float()
  def default_threshold do
    get(:default_threshold)
  end

  @doc """
  Get the maximum iterations for refinement.
  """
  @spec max_iterations() :: pos_integer()
  def max_iterations do
    get(:max_iterations)
  end

  @doc """
  Get the dimension weights for scoring.
  """
  @spec weights() :: map()
  def weights do
    get(:weights)
  end

  @doc """
  Check if a tool should trigger auto-reflection.
  """
  @spec should_auto_reflect?(atom()) :: boolean()
  def should_auto_reflect?(tool_name) when is_atom(tool_name) do
    if enabled?() do
      auto_reflect = get(:auto_reflect_tools)
      skip_for = get(:skip_reflection_for)

      tool_name in auto_reflect and tool_name not in skip_for
    else
      false
    end
  end

  @doc """
  Check if fast mode should be used based on output length.
  """
  @spec use_fast_mode?(non_neg_integer()) :: boolean()
  def use_fast_mode?(output_length) do
    output_length < get(:fast_mode_threshold)
  end

  @doc """
  Get the confidence output format.
  """
  @spec confidence_output_format() :: :structured | :natural | :hidden
  def confidence_output_format do
    get(:confidence_output)
  end

  @doc """
  Check if all reflections should be stored (not just failures).
  """
  @spec store_all_reflections?() :: boolean()
  def store_all_reflections? do
    get(:store_all_reflections)
  end

  @doc """
  Update a configuration value at runtime.
  Note: This only affects the current runtime, not persistent config.
  """
  @spec put(atom(), term()) :: :ok
  def put(key, value) when is_atom(key) do
    current = Application.get_env(:mimo, Mimo.Brain.Reflector, [])
    updated = Keyword.put(current, key, value)
    Application.put_env(:mimo, Mimo.Brain.Reflector, updated)
    :ok
  end
end
