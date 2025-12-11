defmodule Mimo.AdaptiveWorkflow.TemplateAdapter do
  @moduledoc """
  Template Adapter for SPEC-054: Adaptive Workflow Engine.

  Adapts workflow patterns based on model capabilities. Transforms
  standard patterns into model-optimized variants.

  ## Adaptation Strategies

  Based on model tier and capabilities:

  ### Tier 3 (Small Models) Adaptations
  - Add `prepare_context` as first step
  - Insert reasoning checkpoints
  - Require confirmation for destructive actions
  - Reduce parallel tool calls to sequential

  ### Tier 2 (Medium Models) Adaptations
  - Add optional guidance steps
  - Moderate parallel tool limits
  - Suggest but don't require confirmation

  ### Tier 1 (Large Models) Adaptations
  - Allow full parallelism
  - Minimal guidance overhead
  - Trust model judgment

  ## Architecture

         Original Pattern
              │
              ▼
    ┌─────────────────────────┐
    │    TemplateAdapter      │
    │  ┌───────────────────┐  │
    │  │ Model Profile     │◄─┼─── ModelProfiler
    │  └─────────┬─────────┘  │
    │            │            │
    │            ▼            │
    │  ┌───────────────────┐  │
    │  │ Transformation    │  │
    │  │ Rules Engine     │  │
    │  └─────────┬─────────┘  │
    │            │            │
    │            ▼            │
    │  ┌───────────────────┐  │
    │  │ Step Optimizer    │  │
    │  └───────────────────┘  │
    └────────────│────────────┘
                 │
                 ▼
        Adapted Pattern

  """
  require Logger

  alias Mimo.Workflow.Pattern
  alias Mimo.AdaptiveWorkflow.ModelProfiler

  @type adaptation_opts :: [
          model_id: String.t(),
          context: map(),
          force_tier: ModelProfiler.tier() | nil,
          skip_adaptations: [atom()]
        ]

  # =============================================================================
  # Public API
  # =============================================================================

  @doc """
  Adapt a workflow pattern for a specific model.

  Applies all relevant transformations based on model capabilities.

  ## Options
  - `:model_id` - The model to adapt for
  - `:context` - Additional context for adaptation decisions
  - `:force_tier` - Override detected tier
  - `:skip_adaptations` - List of adaptation types to skip
  """
  @spec adapt(Pattern.t() | nil, adaptation_opts()) :: {:ok, Pattern.t()} | {:error, term()}
  def adapt(pattern, opts \\ [])
  def adapt(nil, _opts), do: {:error, :nil_pattern}
  def adapt(%Pattern{steps: nil} = pattern, opts), do: adapt(%{pattern | steps: []}, opts)

  def adapt(%Pattern{} = pattern, opts) do
    model_id = Keyword.get(opts, :model_id)
    context = Keyword.get(opts, :context, %{})
    force_tier = Keyword.get(opts, :force_tier)
    skip = Keyword.get(opts, :skip_adaptations, [])

    if model_id == nil and force_tier == nil do
      {:error, :model_id_required}
    else
      tier = force_tier || ModelProfiler.detect_tier(model_id)

      recommendations =
        if model_id, do: ModelProfiler.get_workflow_recommendations(model_id), else: %{}

      adapted =
        pattern
        |> maybe_add_context_step(tier, skip, context)
        |> maybe_add_reasoning_steps(tier, skip, recommendations)
        |> maybe_add_confirmation_steps(tier, skip, recommendations)
        |> maybe_limit_parallelism(tier, skip, recommendations)
        |> maybe_add_guidance(tier, skip, recommendations)
        |> update_metadata(model_id, tier)

      {:ok, adapted}
    end
  end

  @doc """
  Get adaptation summary for a pattern and model.

  Returns what changes would be made without actually applying them.
  """
  @spec preview_adaptations(Pattern.t() | nil, adaptation_opts()) :: map()
  def preview_adaptations(pattern, opts \\ [])
  def preview_adaptations(nil, _opts), do: %{error: :nil_pattern, adaptations: []}

  def preview_adaptations(%Pattern{steps: nil} = pattern, opts),
    do: preview_adaptations(%{pattern | steps: []}, opts)

  def preview_adaptations(%Pattern{} = pattern, opts) do
    model_id = Keyword.get(opts, :model_id)
    force_tier = Keyword.get(opts, :force_tier)

    tier = force_tier || (model_id && ModelProfiler.detect_tier(model_id)) || :tier2

    recommendations =
      if model_id, do: ModelProfiler.get_workflow_recommendations(model_id), else: %{}

    %{
      original_step_count: length(pattern.steps || []),
      tier: tier,
      adaptations: list_adaptations(pattern, tier, recommendations),
      estimated_overhead_ms: calculate_overhead(tier, pattern),
      recommendation_summary: summarize_recommendations(recommendations)
    }
  end

  @doc """
  Create a tier-specific template from a base pattern.

  Used to pre-generate optimized templates for each tier.
  """
  @spec create_tier_template(Pattern.t(), ModelProfiler.tier()) :: Pattern.t()
  def create_tier_template(%Pattern{} = pattern, tier) do
    {:ok, adapted} = adapt(pattern, force_tier: tier)

    %{
      adapted
      | name: "#{pattern.name}_#{tier}",
        metadata: Map.put(pattern.metadata || %{}, :tier_template, tier)
    }
  end

  # =============================================================================
  # Adaptation Functions
  # =============================================================================

  defp maybe_add_context_step(pattern, tier, skip, context) do
    if tier == :tier3 and :context_step not in skip do
      add_prepare_context_step(pattern, context)
    else
      pattern
    end
  end

  defp add_prepare_context_step(pattern, _context) do
    # Determine what context to gather based on pattern needs
    query = build_context_query(pattern)

    context_step = %{
      tool: "meta",
      name: "prepare_context",
      args: %{
        operation: "prepare_context",
        query: query,
        max_tokens: 2000
      },
      description: "Gather relevant context before execution (added for smaller models)"
    }

    # Insert at the beginning
    %{pattern | steps: [context_step | pattern.steps]}
  end

  defp build_context_query(pattern) do
    # Generate a context query based on pattern purpose
    case pattern.category do
      :debugging ->
        "debugging context: error patterns, past solutions, code structure"

      :code_navigation ->
        "code navigation context: symbol definitions, file structure, dependencies"

      :file_operations ->
        "file operation context: project structure, recent changes, related files"

      _ ->
        "relevant context for: #{pattern.description || pattern.name}"
    end
  end

  defp maybe_add_reasoning_steps(pattern, tier, skip, recommendations) do
    needs_reasoning = recommendations[:add_reasoning_steps] || tier == :tier3

    if needs_reasoning and :reasoning_steps not in skip do
      add_reasoning_checkpoints(pattern)
    else
      pattern
    end
  end

  defp add_reasoning_checkpoints(pattern) do
    # Add reasoning step before complex operations
    updated_steps =
      Enum.flat_map(pattern.steps, fn step ->
        if complex_step?(step) do
          reasoning_step = %{
            tool: "think",
            name: "reasoning_checkpoint",
            args: %{
              operation: "thought",
              thought:
                "Before executing #{step[:name] || step.tool}: verify approach and expected outcome"
            },
            description: "Reasoning checkpoint (added for smaller models)"
          }

          [reasoning_step, step]
        else
          [step]
        end
      end)

    %{pattern | steps: updated_steps}
  end

  defp complex_step?(step) do
    complex_tools = ["file", "terminal", "code"]
    tool = step[:tool] || step["tool"]
    args = step[:args] || step["args"] || step[:params] || step["params"] || %{}
    operation = args[:operation] || args["operation"]
    tool in complex_tools and operation in ["edit", "write", "multi_replace", "execute"]
  end

  defp maybe_add_confirmation_steps(pattern, tier, skip, recommendations) do
    require_confirmation = recommendations[:require_confirmation] || tier == :tier3

    if require_confirmation and :confirmation_steps not in skip do
      add_confirmation_for_destructive(pattern)
    else
      pattern
    end
  end

  defp add_confirmation_for_destructive(pattern) do
    updated_steps =
      Enum.flat_map(pattern.steps, fn step ->
        if destructive_step?(step) do
          confirmation = %{
            tool: "think",
            name: "confirm_action",
            args: %{
              operation: "plan",
              steps: [
                "About to execute: #{step[:name] || step.tool}",
                "This is a destructive operation",
                "Proceeding with caution"
              ]
            },
            description: "Confirmation checkpoint for destructive operation"
          }

          [confirmation, step]
        else
          [step]
        end
      end)

    %{pattern | steps: updated_steps}
  end

  defp destructive_step?(step) do
    destructive_ops = ["write", "edit", "delete", "multi_replace", "execute", "move"]
    tool = step[:tool] || step["tool"]
    args = step[:args] || step["args"] || step[:params] || step["params"] || %{}
    operation = args[:operation] || args["operation"]
    operation in destructive_ops or tool == "terminal"
  end

  defp maybe_limit_parallelism(pattern, tier, skip, recommendations) do
    max_parallel = recommendations[:max_parallel_tools] || tier_to_parallel(tier)

    if :parallelism not in skip do
      limit_parallel_steps(pattern, max_parallel)
    else
      pattern
    end
  end

  defp tier_to_parallel(:tier1), do: 5
  defp tier_to_parallel(:tier2), do: 3
  defp tier_to_parallel(:tier3), do: 1
  # Default to tier2 behavior for unknown tiers
  defp tier_to_parallel(_), do: 3

  defp limit_parallel_steps(pattern, max_parallel) do
    # Mark steps that can run in parallel with groups
    # Steps within the same group can run in parallel (up to max_parallel)

    updated_steps =
      Enum.with_index(pattern.steps)
      |> Enum.map(fn {step, idx} ->
        group = div(idx, max_parallel)
        Map.put(step, :parallel_group, group)
      end)

    %{
      pattern
      | steps: updated_steps,
        metadata: Map.put(pattern.metadata || %{}, :max_parallel, max_parallel)
    }
  end

  defp maybe_add_guidance(pattern, tier, skip, recommendations) do
    needs_guidance =
      tier in [:tier2, :tier3] or
        recommendations[:needs_coding_guidance] == true or
        recommendations[:needs_reasoning_support] == true

    if needs_guidance and :guidance not in skip do
      add_guidance_metadata(pattern, recommendations)
    else
      pattern
    end
  end

  defp add_guidance_metadata(pattern, recommendations) do
    guidance = %{
      prefer_structured: true,
      explain_each_step: recommendations[:needs_reasoning_support] || false,
      provide_examples: recommendations[:needs_coding_guidance] || false,
      verify_before_proceeding: true
    }

    %{pattern | metadata: Map.merge(pattern.metadata || %{}, %{guidance: guidance})}
  end

  defp update_metadata(pattern, model_id, tier) do
    %{
      pattern
      | metadata:
          Map.merge(pattern.metadata || %{}, %{
            adapted_for: model_id,
            adapted_tier: tier,
            adapted_at: DateTime.utc_now()
          })
    }
  end

  # =============================================================================
  # Preview Helpers
  # =============================================================================

  defp list_adaptations(pattern, tier, recommendations) do
    adaptations = []

    adaptations =
      if tier == :tier3 do
        [{:add_prepare_context, "Insert prepare_context step at beginning"} | adaptations]
      else
        adaptations
      end

    adaptations =
      if tier == :tier3 or recommendations[:add_reasoning_steps] do
        complex_count = Enum.count(pattern.steps, &complex_step?/1)

        if complex_count > 0 do
          [
            {:add_reasoning_checkpoints, "Add #{complex_count} reasoning checkpoint(s)"}
            | adaptations
          ]
        else
          adaptations
        end
      else
        adaptations
      end

    adaptations =
      if tier == :tier3 or recommendations[:require_confirmation] do
        destructive_count = Enum.count(pattern.steps, &destructive_step?/1)

        if destructive_count > 0 do
          [{:add_confirmations, "Add #{destructive_count} confirmation step(s)"} | adaptations]
        else
          adaptations
        end
      else
        adaptations
      end

    adaptations =
      if tier != :tier1 do
        max_p = tier_to_parallel(tier)
        [{:limit_parallelism, "Limit parallel execution to #{max_p} tools"} | adaptations]
      else
        adaptations
      end

    Enum.reverse(adaptations)
  end

  defp calculate_overhead(tier, pattern) do
    base_overhead =
      case tier do
        # prepare_context adds ~500ms
        :tier3 -> 500
        # minimal overhead
        :tier2 -> 100
        :tier1 -> 0
      end

    reasoning_overhead =
      if tier == :tier3 do
        Enum.count(pattern.steps, &complex_step?/1) * 50
      else
        0
      end

    confirmation_overhead =
      if tier == :tier3 do
        Enum.count(pattern.steps, &destructive_step?/1) * 30
      else
        0
      end

    base_overhead + reasoning_overhead + confirmation_overhead
  end

  defp summarize_recommendations(recommendations) do
    recommendations
    |> Enum.filter(fn {_k, v} -> v == true or (is_number(v) and v > 0) end)
    |> Enum.map(fn {k, v} -> "#{k}: #{v}" end)
    |> Enum.join(", ")
  end
end
