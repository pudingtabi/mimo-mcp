defmodule Mimo.AdaptiveWorkflow.ModelProfiler do
  @moduledoc """
  Model Profiler for SPEC-054: Adaptive Workflow Engine.

  Assesses AI model capabilities and maintains performance profiles for
  workflow adaptation. Tracks what each model can and cannot do effectively.

  ## Model Tiers

  Based on observed capabilities and documented limits:

  - **Tier 1 (Large)**: Claude Opus, GPT-4, etc.
    - Full reasoning, complex multi-step, large context
    - Can handle abstract tasks with minimal guidance

  - **Tier 2 (Medium)**: Claude Sonnet, GPT-4-mini, Gemini Pro
    - Good reasoning, moderate complexity
    - Benefits from structured guidance

  - **Tier 3 (Small)**: Claude Haiku, GPT-3.5, Gemini Flash
    - Basic reasoning, simple tasks
    - Requires explicit step-by-step guidance

  ## Architecture

                    Model Request
                         │
                         ▼
      ┌──────────────────────────────────────┐
      │          ModelProfiler               │
      │  ┌────────────────────────────────┐  │
      │  │   Capability Assessment       │  │
      │  │  - Context window size        │  │
      │  │  - Reasoning depth            │  │
      │  │  - Tool use proficiency       │  │
      │  └───────────────┬───────────────┘  │
      │                  │                  │
      │                  ▼                  │
      │  ┌────────────────────────────────┐  │
      │  │   Performance Tracking        │  │
      │  │  - Success rates by task      │  │
      │  │  - Latency distributions      │  │
      │  │  - Error patterns             │  │
      │  └───────────────────────────────┘  │
      └──────────────────────────────────────┘
                         │
                         ▼
              Workflow Template Selection

  """
  use GenServer
  require Logger

  # =============================================================================
  # Types
  # =============================================================================

  @type model_id :: String.t()
  @type tier :: :tier1 | :tier2 | :tier3
  @type capability :: :reasoning | :coding | :analysis | :synthesis | :tool_use | :context_handling

  @type model_profile :: %{
          model_id: model_id(),
          tier: tier(),
          context_window: pos_integer(),
          capabilities: %{capability() => float()},
          constraints: [String.t()],
          performance_history: [performance_record()],
          last_assessment: DateTime.t() | nil
        }

  @type performance_record :: %{
          workflow_type: String.t(),
          success_rate: float(),
          avg_latency_ms: float(),
          sample_count: pos_integer(),
          last_updated: DateTime.t()
        }

  # =============================================================================
  # Known Model Profiles (Seed Data)
  # =============================================================================

  @known_models %{
    # Tier 1 - Large Models
    "claude-3-opus" => %{
      tier: :tier1,
      context_window: 200_000,
      capabilities: %{
        reasoning: 0.95,
        coding: 0.92,
        analysis: 0.94,
        synthesis: 0.93,
        tool_use: 0.90,
        context_handling: 0.95
      },
      constraints: []
    },
    "claude-opus-4" => %{
      tier: :tier1,
      context_window: 200_000,
      capabilities: %{
        reasoning: 0.97,
        coding: 0.94,
        analysis: 0.96,
        synthesis: 0.95,
        tool_use: 0.92,
        context_handling: 0.96
      },
      constraints: []
    },
    "gpt-4" => %{
      tier: :tier1,
      context_window: 128_000,
      capabilities: %{
        reasoning: 0.92,
        coding: 0.90,
        analysis: 0.91,
        synthesis: 0.90,
        tool_use: 0.88,
        context_handling: 0.90
      },
      constraints: []
    },
    "gpt-4o" => %{
      tier: :tier1,
      context_window: 128_000,
      capabilities: %{
        reasoning: 0.93,
        coding: 0.91,
        analysis: 0.92,
        synthesis: 0.91,
        tool_use: 0.90,
        context_handling: 0.91
      },
      constraints: []
    },

    # Tier 2 - Medium Models
    "claude-3-sonnet" => %{
      tier: :tier2,
      context_window: 200_000,
      capabilities: %{
        reasoning: 0.82,
        coding: 0.80,
        analysis: 0.83,
        synthesis: 0.80,
        tool_use: 0.78,
        context_handling: 0.85
      },
      constraints: ["may_need_guidance_for_complex_tasks"]
    },
    "claude-3.5-sonnet" => %{
      tier: :tier2,
      context_window: 200_000,
      capabilities: %{
        reasoning: 0.88,
        coding: 0.87,
        analysis: 0.88,
        synthesis: 0.86,
        tool_use: 0.85,
        context_handling: 0.88
      },
      constraints: []
    },
    "gpt-4-mini" => %{
      tier: :tier2,
      context_window: 128_000,
      capabilities: %{
        reasoning: 0.78,
        coding: 0.75,
        analysis: 0.77,
        synthesis: 0.75,
        tool_use: 0.73,
        context_handling: 0.80
      },
      constraints: ["may_need_guidance_for_complex_tasks"]
    },
    "gemini-pro" => %{
      tier: :tier2,
      context_window: 32_000,
      capabilities: %{
        reasoning: 0.80,
        coding: 0.78,
        analysis: 0.80,
        synthesis: 0.78,
        tool_use: 0.75,
        context_handling: 0.75
      },
      constraints: ["smaller_context_window"]
    },

    # Tier 3 - Small Models
    "claude-3-haiku" => %{
      tier: :tier3,
      context_window: 200_000,
      capabilities: %{
        reasoning: 0.65,
        coding: 0.62,
        analysis: 0.65,
        synthesis: 0.60,
        tool_use: 0.58,
        context_handling: 0.70
      },
      constraints: [
        "requires_explicit_step_guidance",
        "may_miss_subtle_context",
        "benefits_from_prepare_context"
      ]
    },
    "gpt-3.5-turbo" => %{
      tier: :tier3,
      context_window: 16_000,
      capabilities: %{
        reasoning: 0.60,
        coding: 0.58,
        analysis: 0.60,
        synthesis: 0.55,
        tool_use: 0.55,
        context_handling: 0.55
      },
      constraints: [
        "requires_explicit_step_guidance",
        "smaller_context_window",
        "benefits_from_prepare_context"
      ]
    },
    "gemini-flash" => %{
      tier: :tier3,
      context_window: 32_000,
      capabilities: %{
        reasoning: 0.62,
        coding: 0.60,
        analysis: 0.62,
        synthesis: 0.58,
        tool_use: 0.55,
        context_handling: 0.60
      },
      constraints: [
        "requires_explicit_step_guidance",
        "benefits_from_prepare_context"
      ]
    }
  }

  # =============================================================================
  # GenServer
  # =============================================================================

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    state = %{
      profiles: load_profiles(),
      performance_cache: %{},
      last_cleanup: DateTime.utc_now()
    }
    
    # Schedule periodic cleanup
    schedule_cleanup()
    
    {:ok, state}
  end

  # =============================================================================
  # Public API
  # =============================================================================

  @doc """
  Get the profile for a specific model.

  Returns a comprehensive profile including capabilities, constraints,
  and performance history.
  """
  @spec get_profile(model_id()) :: {:ok, model_profile()} | {:error, :unknown_model}
  def get_profile(model_id) do
    GenServer.call(__MODULE__, {:get_profile, model_id})
  end

  @doc """
  Detect the model tier from a model identifier string.

  Uses fuzzy matching to handle various model naming conventions.
  """
  @spec detect_tier(model_id()) :: tier()
  def detect_tier(model_id) do
    GenServer.call(__MODULE__, {:detect_tier, model_id})
  end

  @doc """
  Get capabilities for a model.

  Returns capability scores for different task types.
  """
  @spec get_capabilities(model_id()) :: %{capability() => float()}
  def get_capabilities(model_id) do
    GenServer.call(__MODULE__, {:get_capabilities, model_id})
  end

  @doc """
  Get constraints for a model.

  Returns a list of constraint identifiers that should be considered
  when adapting workflows.
  """
  @spec get_constraints(model_id()) :: [String.t()]
  def get_constraints(model_id) do
    GenServer.call(__MODULE__, {:get_constraints, model_id})
  end

  @doc """
  Check if a model can handle a specific capability requirement.

  ## Options
  - `:threshold` - Minimum capability score (default: 0.7)
  """
  @spec can_handle?(model_id(), capability(), keyword()) :: boolean()
  def can_handle?(model_id, capability, opts \\ []) do
    GenServer.call(__MODULE__, {:can_handle?, model_id, capability, opts})
  end

  @doc """
  Record performance metrics for a model on a specific workflow type.

  Used for learning and profile updates.
  """
  @spec record_performance(model_id(), String.t(), map()) :: :ok
  def record_performance(model_id, workflow_type, metrics) do
    GenServer.cast(__MODULE__, {:record_performance, model_id, workflow_type, metrics})
  end

  @doc """
  Get workflow recommendations for a model.

  Returns a list of workflow adaptations based on model capabilities.
  """
  @spec get_workflow_recommendations(model_id()) :: map()
  def get_workflow_recommendations(model_id) do
    GenServer.call(__MODULE__, {:get_recommendations, model_id})
  end

  @doc """
  Assess a model based on recent performance data.

  Triggers capability reassessment if enough data has been collected.
  """
  @spec assess_model(model_id()) :: {:ok, model_profile()} | {:error, term()}
  def assess_model(model_id) do
    GenServer.call(__MODULE__, {:assess_model, model_id})
  end

  @doc """
  List all known model profiles.
  """
  @spec list_profiles() :: [model_profile()]
  def list_profiles do
    GenServer.call(__MODULE__, :list_profiles)
  end

  # =============================================================================
  # GenServer Callbacks
  # =============================================================================

  @impl true
  def handle_call({:get_profile, model_id}, _from, state) do
    profile = build_profile(model_id, state)
    {:reply, {:ok, profile}, state}
  end

  @impl true
  def handle_call({:detect_tier, model_id}, _from, state) do
    tier = detect_tier_internal(model_id)
    {:reply, tier, state}
  end

  @impl true
  def handle_call({:get_capabilities, model_id}, _from, state) do
    capabilities = get_capabilities_internal(model_id, state)
    {:reply, capabilities, state}
  end

  @impl true
  def handle_call({:get_constraints, model_id}, _from, state) do
    constraints = get_constraints_internal(model_id)
    {:reply, constraints, state}
  end

  @impl true
  def handle_call({:can_handle?, model_id, capability, opts}, _from, state) do
    threshold = Keyword.get(opts, :threshold, 0.7)
    capabilities = get_capabilities_internal(model_id, state)
    score = Map.get(capabilities, capability, 0.5)
    {:reply, score >= threshold, state}
  end

  @impl true
  def handle_call({:get_recommendations, model_id}, _from, state) do
    recommendations = build_recommendations(model_id, state)
    {:reply, recommendations, state}
  end

  @impl true
  def handle_call({:assess_model, model_id}, _from, state) do
    {result, new_state} = perform_assessment(model_id, state)
    {:reply, result, new_state}
  end

  @impl true
  def handle_call(:list_profiles, _from, state) do
    profiles = Enum.map(Map.keys(@known_models), fn model_id ->
      build_profile(model_id, state)
    end)
    {:reply, profiles, state}
  end

  @impl true
  def handle_cast({:record_performance, model_id, workflow_type, metrics}, state) do
    new_cache = update_performance_cache(
      state.performance_cache,
      model_id,
      workflow_type,
      metrics
    )
    {:noreply, %{state | performance_cache: new_cache}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    new_state = perform_cleanup(state)
    schedule_cleanup()
    {:noreply, new_state}
  end

  # =============================================================================
  # Internal Functions
  # =============================================================================

  defp load_profiles do
    # Load any persisted profiles from database
    # For now, use known models as base
    @known_models
  end

  defp build_profile(model_id, state) do
    base = find_base_profile(model_id)
    performance = Map.get(state.performance_cache, model_id, [])
    
    %{
      model_id: model_id,
      tier: base.tier,
      context_window: base.context_window,
      capabilities: base.capabilities,
      constraints: base.constraints,
      performance_history: performance,
      last_assessment: nil
    }
  end

  defp find_base_profile(model_id) do
    normalized = normalize_model_id(model_id)
    
    # Direct match
    case Map.get(@known_models, normalized) do
      nil ->
        # Fuzzy match
        find_fuzzy_match(normalized)
      
      profile ->
        profile
    end
  end

  defp normalize_model_id(nil), do: ""
  defp normalize_model_id(model_id) when is_binary(model_id) do
    model_id
    |> String.downcase()
    |> String.replace(~r/[_\s]+/, "-")
    |> String.trim()
  end
  defp normalize_model_id(_), do: ""

  defp find_fuzzy_match(model_id) do
    # Try to match known model families
    cond do
      String.contains?(model_id, "opus") and String.contains?(model_id, "4") ->
        @known_models["claude-opus-4"]
      
      String.contains?(model_id, "opus") ->
        @known_models["claude-3-opus"]
      
      String.contains?(model_id, "sonnet") and String.contains?(model_id, "3.5") ->
        @known_models["claude-3.5-sonnet"]
      
      String.contains?(model_id, "sonnet") ->
        @known_models["claude-3-sonnet"]
      
      String.contains?(model_id, "haiku") ->
        @known_models["claude-3-haiku"]
      
      String.contains?(model_id, "gpt-4o") ->
        @known_models["gpt-4o"]
      
      String.contains?(model_id, "gpt-4") and String.contains?(model_id, "mini") ->
        @known_models["gpt-4-mini"]
      
      String.contains?(model_id, "gpt-4") ->
        @known_models["gpt-4"]
      
      String.contains?(model_id, "gpt-3.5") ->
        @known_models["gpt-3.5-turbo"]
      
      String.contains?(model_id, "gemini") and String.contains?(model_id, "flash") ->
        @known_models["gemini-flash"]
      
      String.contains?(model_id, "gemini") and String.contains?(model_id, "pro") ->
        @known_models["gemini-pro"]
      
      # Default: assume tier 2 medium capabilities
      true ->
        %{
          tier: :tier2,
          context_window: 32_000,
          capabilities: %{
            reasoning: 0.70,
            coding: 0.68,
            analysis: 0.70,
            synthesis: 0.68,
            tool_use: 0.65,
            context_handling: 0.70
          },
          constraints: ["unknown_model"]
        }
    end
  end

  defp detect_tier_internal(model_id) do
    profile = find_base_profile(normalize_model_id(model_id))
    profile.tier
  end

  defp get_capabilities_internal(model_id, _state) do
    profile = find_base_profile(normalize_model_id(model_id))
    profile.capabilities
  end

  defp get_constraints_internal(model_id) do
    profile = find_base_profile(normalize_model_id(model_id))
    profile.constraints
  end

  defp build_recommendations(model_id, _state) do
    profile = find_base_profile(normalize_model_id(model_id))
    
    base_recommendations = %{
      use_prepare_context: profile.tier == :tier3,
      prefer_structured_workflows: profile.tier != :tier1,
      max_parallel_tools: tier_to_parallel_limit(profile.tier),
      require_confirmation: profile.tier == :tier3,
      add_reasoning_steps: profile.tier == :tier3,
      context_budget_tokens: context_budget(profile.context_window, profile.tier)
    }
    
    # Add capability-specific recommendations
    capability_recommendations = %{
      needs_coding_guidance: Map.get(profile.capabilities, :coding, 0.5) < 0.7,
      needs_reasoning_support: Map.get(profile.capabilities, :reasoning, 0.5) < 0.75,
      can_handle_complex_synthesis: Map.get(profile.capabilities, :synthesis, 0.5) >= 0.8
    }
    
    Map.merge(base_recommendations, capability_recommendations)
  end

  defp tier_to_parallel_limit(:tier1), do: 5
  defp tier_to_parallel_limit(:tier2), do: 3
  defp tier_to_parallel_limit(:tier3), do: 1

  defp context_budget(window_size, tier) do
    # Recommend using a fraction of the context window
    # Smaller models should use less to leave room for reasoning
    multiplier = case tier do
      :tier1 -> 0.7
      :tier2 -> 0.5
      :tier3 -> 0.3
    end
    
    round(window_size * multiplier)
  end

  defp update_performance_cache(cache, model_id, workflow_type, metrics) do
    model_cache = Map.get(cache, model_id, %{})
    
    record = %{
      workflow_type: workflow_type,
      success: metrics[:success] || false,
      latency_ms: metrics[:latency_ms] || 0,
      timestamp: DateTime.utc_now()
    }
    
    workflow_records = Map.get(model_cache, workflow_type, [])
    updated_records = [record | Enum.take(workflow_records, 99)]  # Keep last 100
    
    updated_model_cache = Map.put(model_cache, workflow_type, updated_records)
    Map.put(cache, model_id, updated_model_cache)
  end

  defp perform_assessment(model_id, state) do
    model_cache = Map.get(state.performance_cache, model_id, %{})
    
    if map_size(model_cache) < 3 do
      # Not enough data yet
      {{:error, :insufficient_data}, state}
    else
      # Calculate aggregate stats
      stats = Enum.map(model_cache, fn {workflow_type, records} ->
        successes = Enum.count(records, & &1.success)
        total = length(records)
        avg_latency = if total > 0 do
          Enum.sum(Enum.map(records, & &1.latency_ms)) / total
        else
          0
        end
        
        %{
          workflow_type: workflow_type,
          success_rate: if(total > 0, do: successes / total, else: 0),
          avg_latency_ms: avg_latency,
          sample_count: total,
          last_updated: DateTime.utc_now()
        }
      end)
      
      profile = build_profile(model_id, state)
      updated_profile = %{profile | 
        performance_history: stats,
        last_assessment: DateTime.utc_now()
      }
      
      {{:ok, updated_profile}, state}
    end
  end

  defp perform_cleanup(state) do
    # Remove old performance records (older than 7 days)
    cutoff = DateTime.add(DateTime.utc_now(), -7, :day)
    
    cleaned_cache = Enum.map(state.performance_cache, fn {model_id, workflows} ->
      cleaned_workflows = Enum.map(workflows, fn {wf_type, records} ->
        filtered = Enum.filter(records, fn r ->
          DateTime.compare(r.timestamp, cutoff) == :gt
        end)
        {wf_type, filtered}
      end)
      |> Map.new()
      
      {model_id, cleaned_workflows}
    end)
    |> Map.new()
    
    %{state | 
      performance_cache: cleaned_cache,
      last_cleanup: DateTime.utc_now()
    }
  end

  defp schedule_cleanup do
    # Cleanup every hour
    Process.send_after(self(), :cleanup, :timer.hours(1))
  end
end
