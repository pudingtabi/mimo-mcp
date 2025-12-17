defmodule Mimo.Cognitive.Amplifier.AmplificationLevel do
  @moduledoc """
  Defines amplification levels for cognitive enhancement.

  Each level specifies how aggressively the Amplifier forces deeper thinking:
  - :minimal - No forced amplification, pass-through mode
  - :standard - Basic decomposition and some challenges
  - :deep - Full decomposition, challenges, perspectives, coherence
  - :exhaustive - Maximum amplification, all checks enforced

  ## Usage

      level = AmplificationLevel.get(:deep)
      level.decomposition  # => true
      level.challenges     # => 4
  """

  @type level_name :: :minimal | :standard | :deep | :exhaustive | :adaptive
  @type coherence_mode :: :none | :basic | :full
  @type synthesis_mode :: :none | :optional | :required | :strict

  @type t :: %__MODULE__{
          name: level_name(),
          decomposition: boolean(),
          challenges: non_neg_integer() | :all,
          perspectives: non_neg_integer() | :all,
          coherence: coherence_mode(),
          synthesis: synthesis_mode(),
          min_thinking_steps: non_neg_integer(),
          force_verification: boolean()
        }

  defstruct [
    :name,
    decomposition: false,
    challenges: 0,
    perspectives: 0,
    coherence: :none,
    synthesis: :none,
    min_thinking_steps: 0,
    force_verification: false
  ]

  @doc """
  Get amplification level configuration by name.
  """
  @spec get(level_name()) :: t()
  def get(:minimal) do
    %__MODULE__{
      name: :minimal,
      decomposition: false,
      challenges: 0,
      perspectives: 0,
      coherence: :none,
      synthesis: :none,
      min_thinking_steps: 0,
      force_verification: false
    }
  end

  def get(:standard) do
    %__MODULE__{
      name: :standard,
      decomposition: true,
      challenges: 2,
      perspectives: 2,
      coherence: :basic,
      synthesis: :none,
      min_thinking_steps: 3,
      force_verification: false
    }
  end

  def get(:deep) do
    %__MODULE__{
      name: :deep,
      decomposition: true,
      challenges: 4,
      perspectives: 3,
      coherence: :full,
      synthesis: :required,
      min_thinking_steps: 5,
      force_verification: true
    }
  end

  def get(:exhaustive) do
    %__MODULE__{
      name: :exhaustive,
      decomposition: true,
      challenges: :all,
      perspectives: :all,
      coherence: :full,
      synthesis: :strict,
      min_thinking_steps: 7,
      force_verification: true
    }
  end

  def get(_), do: get(:standard)

  @doc """
  Get all available level names.
  """
  @spec available_levels() :: [level_name()]
  def available_levels do
    [:minimal, :standard, :deep, :exhaustive]
  end

  @doc """
  Determine appropriate level based on problem complexity.

  Used in :adaptive mode to auto-select amplification level.
  """
  @spec for_complexity(atom()) :: t()
  def for_complexity(complexity) do
    case complexity do
      :trivial -> get(:minimal)
      :simple -> get(:standard)
      :moderate -> get(:standard)
      :complex -> get(:deep)
      :very_complex -> get(:exhaustive)
      _ -> get(:standard)
    end
  end

  @doc """
  Check if a specific amplification feature is enabled.
  """
  @spec enabled?(t(), atom()) :: boolean()
  def enabled?(%__MODULE__{} = level, feature) do
    case feature do
      :decomposition -> level.decomposition
      :challenges -> level.challenges > 0 or level.challenges == :all
      :perspectives -> level.perspectives > 0 or level.perspectives == :all
      :coherence -> level.coherence != :none
      :synthesis -> level.synthesis != :none
      :verification -> level.force_verification
      _ -> false
    end
  end

  @doc """
  Get the required count for a feature (challenges, perspectives, etc.)
  """
  @spec required_count(t(), atom()) :: non_neg_integer() | :all
  def required_count(%__MODULE__{} = level, feature) do
    case feature do
      :challenges -> level.challenges
      :perspectives -> level.perspectives
      :min_steps -> level.min_thinking_steps
      _ -> 0
    end
  end
end
