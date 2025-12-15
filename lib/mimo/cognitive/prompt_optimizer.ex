defmodule Mimo.Cognitive.PromptOptimizer do
  @moduledoc """
  Self-improving prompt optimization for Mimo.

  Part of Phase 3: Emergent Capabilities - Self-improving prompt optimization.

  This module learns from tool usage patterns and outcomes to improve
  the prompts, hints, and suggestions that Mimo provides.

  ## How It Works

  1. **Track Prompt Usage**: When a prompt/hint is shown, record it
  2. **Track Outcomes**: When the task completes, record success/failure
  3. **Analyze Patterns**: Find which prompts lead to better outcomes
  4. **Optimize**: Adjust prompt rankings, wording, and contexts

  ## Integration Points

  - Tool definitions: Optimize tool descriptions
  - ask_mimo: Improve response patterns
  - Cognitive suggestions: Refine when to suggest which tools
  - Pre-tool injection: Improve memory hint selection

  ## Example

      # Track prompt usage
      PromptOptimizer.track_prompt("Consider using memory search first", context)

      # Later, record outcome
      PromptOptimizer.record_outcome(context_hash, :success)

      # Get optimized prompts for a context
      prompts = PromptOptimizer.get_optimized_prompts(context_type)
  """

  use GenServer
  require Logger

  alias Mimo.Brain.Memory

  @ets_table :prompt_optimizer_cache
  @optimization_interval :timer.hours(2)
  @min_samples 10

  # ============================================================================
  # Type Definitions
  # ============================================================================

  @type prompt_record :: %{
          prompt_id: String.t(),
          prompt_text: String.t(),
          prompt_type: atom(),
          context_type: atom(),
          context_hash: String.t(),
          shown_at: DateTime.t()
        }

  @type prompt_stats :: %{
          prompt_text: String.t(),
          prompt_type: atom(),
          shown_count: non_neg_integer(),
          success_count: non_neg_integer(),
          success_rate: float(),
          avg_engagement: float()
        }

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Track when a prompt/hint is shown to the user.

  ## Parameters

  - `prompt_text` - The prompt or hint text
  - `context` - Map with context info (:type, :query, :tool_name, etc.)

  ## Returns

  - `{:ok, prompt_id}` for tracking outcome
  """
  @spec track_prompt(String.t(), map()) :: {:ok, String.t()}
  def track_prompt(prompt_text, context \\ %{}) do
    GenServer.call(__MODULE__, {:track_prompt, prompt_text, context})
  catch
    :exit, _ -> {:ok, "fallback_#{:erlang.unique_integer([:positive])}"}
  end

  @doc """
  Record the outcome of a prompt-related interaction.

  ## Parameters

  - `context_hash` - Hash from the original prompt context
  - `outcome` - :success | :partial | :failure | :ignored
  - `opts` - Additional details (engagement time, follow-up action, etc.)
  """
  @spec record_outcome(String.t(), atom(), keyword()) :: :ok
  def record_outcome(context_hash, outcome, opts \\ []) do
    GenServer.cast(__MODULE__, {:record_outcome, context_hash, outcome, opts})
  end

  @doc """
  Get optimized prompts for a given context type.

  Returns prompts sorted by effectiveness.
  """
  @spec get_optimized_prompts(atom(), keyword()) :: [prompt_stats()]
  def get_optimized_prompts(context_type, opts \\ []) do
    GenServer.call(__MODULE__, {:get_prompts, context_type, opts})
  catch
    :exit, _ -> []
  end

  @doc """
  Get the best prompt for a context.

  Uses learned patterns to select the most effective prompt.
  """
  @spec suggest_prompt(atom(), String.t()) :: {:ok, String.t()} | {:error, :no_prompts}
  def suggest_prompt(context_type, context_query \\ "") do
    GenServer.call(__MODULE__, {:suggest_prompt, context_type, context_query})
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  Register a new prompt template.

  Templates can be optimized over time.
  """
  @spec register_template(atom(), String.t(), keyword()) :: :ok
  def register_template(prompt_type, template_text, opts \\ []) do
    GenServer.cast(__MODULE__, {:register_template, prompt_type, template_text, opts})
  end

  @doc """
  Get optimization statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  catch
    :exit, _ -> %{status: :unavailable}
  end

  @doc """
  Run optimization cycle manually.
  """
  @spec optimize(keyword()) :: {:ok, map()}
  def optimize(opts \\ []) do
    GenServer.call(__MODULE__, {:optimize, opts}, 30_000)
  catch
    :exit, _ -> {:ok, %{status: :unavailable}}
  end

  # ============================================================================
  # GenServer Implementation
  # ============================================================================

  @impl true
  def init(_opts) do
    # Create ETS cache
    Mimo.EtsSafe.ensure_table(@ets_table, [:set, :public, :named_table, read_concurrency: true])

    state = %{
      # context_hash => prompt_record
      prompts: %{},
      # context_hash => outcome_record
      outcomes: %{},
      # prompt_type => [template_text]
      templates: default_templates(),
      # prompt_text => stats
      prompt_stats: %{},
      # Optimization metrics
      total_prompts: 0,
      total_outcomes: 0,
      last_optimization: nil
    }

    # Load persisted learnings
    state = load_learned_patterns(state)

    # Schedule periodic optimization
    schedule_optimization()

    Logger.info("[PromptOptimizer] Initialized with #{map_size(state.templates)} template types")
    {:ok, state}
  end

  @impl true
  def handle_call({:track_prompt, prompt_text, context}, _from, state) do
    prompt_id = generate_prompt_id()
    context_hash = generate_context_hash(context)

    record = %{
      prompt_id: prompt_id,
      prompt_text: prompt_text,
      prompt_type: context[:type] || context["type"] || :general,
      context_type: detect_context_type(context),
      context_hash: context_hash,
      query: context[:query] || context["query"] || "",
      tool_name: context[:tool_name] || context["tool_name"],
      shown_at: DateTime.utc_now()
    }

    prompts = Map.put(state.prompts, context_hash, record)
    new_state = %{state | prompts: prompts, total_prompts: state.total_prompts + 1}

    # Update prompt stats
    new_state = update_prompt_shown(new_state, prompt_text, record.context_type)

    {:reply, {:ok, context_hash}, new_state}
  end

  @impl true
  def handle_call({:get_prompts, context_type, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 10)

    prompts =
      state.prompt_stats
      |> Enum.filter(fn {_key, stats} ->
        stats.context_type == context_type || context_type == :all
      end)
      |> Enum.map(fn {_key, stats} -> stats end)
      |> Enum.sort_by(& &1.success_rate, :desc)
      |> Enum.take(limit)

    {:reply, prompts, state}
  end

  @impl true
  def handle_call({:suggest_prompt, context_type, _context_query}, _from, state) do
    # Find best prompt for this context
    candidates =
      state.prompt_stats
      |> Enum.filter(fn {_key, stats} ->
        stats.context_type == context_type && stats.shown_count >= 3
      end)
      |> Enum.map(fn {_key, stats} -> stats end)
      |> Enum.sort_by(&calculate_prompt_score/1, :desc)

    case candidates do
      [best | _] ->
        {:reply, {:ok, best.prompt_text}, state}

      [] ->
        # Fall back to templates
        case Map.get(state.templates, context_type) do
          [template | _] -> {:reply, {:ok, template}, state}
          _ -> {:reply, {:error, :no_prompts}, state}
        end
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      total_prompts_tracked: state.total_prompts,
      total_outcomes_recorded: state.total_outcomes,
      unique_prompts: map_size(state.prompt_stats),
      template_types: map_size(state.templates),
      last_optimization: state.last_optimization,
      top_prompts: get_top_prompts(state.prompt_stats, 5)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:optimize, opts}, _from, state) do
    force = Keyword.get(opts, :force, false)

    if state.total_outcomes < @min_samples && !force do
      {:reply,
       {:ok, %{optimized: false, reason: :insufficient_data, samples: state.total_outcomes}}, state}
    else
      result = run_optimization(state)
      new_state = apply_optimization(state, result)
      {:reply, {:ok, result}, new_state}
    end
  end

  @impl true
  def handle_cast({:record_outcome, context_hash, outcome, opts}, state) do
    case Map.get(state.prompts, context_hash) do
      nil ->
        {:noreply, state}

      prompt_record ->
        outcome_record = %{
          outcome: outcome,
          engagement: Keyword.get(opts, :engagement, 1.0),
          follow_up: Keyword.get(opts, :follow_up),
          recorded_at: DateTime.utc_now()
        }

        outcomes = Map.put(state.outcomes, context_hash, outcome_record)
        new_state = %{state | outcomes: outcomes, total_outcomes: state.total_outcomes + 1}

        # Update prompt stats with outcome
        new_state = update_prompt_outcome(new_state, prompt_record, outcome_record)

        {:noreply, new_state}
    end
  end

  @impl true
  def handle_cast({:register_template, prompt_type, template_text, _opts}, state) do
    templates =
      Map.update(state.templates, prompt_type, [template_text], fn existing ->
        if template_text in existing, do: existing, else: [template_text | existing]
      end)

    {:noreply, %{state | templates: templates}}
  end

  @impl true
  def handle_info(:run_optimization, state) do
    if state.total_outcomes >= @min_samples do
      result = run_optimization(state)
      new_state = apply_optimization(state, result)
      persist_learnings(new_state)
      schedule_optimization()
      {:noreply, new_state}
    else
      schedule_optimization()
      {:noreply, state}
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp default_templates do
    %{
      memory_search: [
        "Search memory first before reading files",
        "Check if this was encountered before",
        "Query past experiences for patterns"
      ],
      code_navigation: [
        "Use find_definition to locate the source",
        "Check references to understand usage",
        "List symbols to understand structure"
      ],
      reasoning: [
        "Consider using structured reasoning for complex problems",
        "Break down the problem into steps",
        "Evaluate multiple approaches before deciding"
      ],
      error_handling: [
        "Check diagnostics for compiler errors",
        "Search memory for similar error patterns",
        "Review the error context carefully"
      ],
      context_preparation: [
        "Gather context before making changes",
        "Use prepare_context for comprehensive background",
        "Check knowledge graph for related entities"
      ]
    }
  end

  defp generate_prompt_id do
    "prompt_#{:erlang.unique_integer([:positive]) |> Integer.to_string(36)}"
  end

  defp generate_context_hash(context) do
    data = [
      context[:type] || context["type"] || :general,
      context[:query] || context["query"] || "",
      context[:tool_name] || context["tool_name"] || ""
    ]

    :crypto.hash(:sha256, inspect(data))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp detect_context_type(context) do
    query = String.downcase(context[:query] || context["query"] || "")
    tool = context[:tool_name] || context["tool_name"]

    cond do
      tool in ["memory", "ask_mimo"] -> :memory_search
      tool in ["file", "code"] -> :code_navigation
      tool in ["reason", "think"] -> :reasoning
      tool in ["diagnose", "check"] -> :error_handling
      String.contains?(query, ["error", "bug", "fix"]) -> :error_handling
      String.contains?(query, ["implement", "create", "build"]) -> :code_navigation
      String.contains?(query, ["understand", "explain", "how"]) -> :context_preparation
      true -> :general
    end
  end

  defp update_prompt_shown(state, prompt_text, context_type) do
    key = normalize_prompt_key(prompt_text)

    stats =
      Map.get(state.prompt_stats, key, %{
        prompt_text: prompt_text,
        prompt_type: :learned,
        context_type: context_type,
        shown_count: 0,
        success_count: 0,
        success_rate: 0.0,
        avg_engagement: 0.0,
        total_engagement: 0.0
      })

    updated_stats = %{stats | shown_count: stats.shown_count + 1}
    %{state | prompt_stats: Map.put(state.prompt_stats, key, updated_stats)}
  end

  defp update_prompt_outcome(state, prompt_record, outcome_record) do
    key = normalize_prompt_key(prompt_record.prompt_text)

    case Map.get(state.prompt_stats, key) do
      nil ->
        state

      stats ->
        is_success = outcome_record.outcome in [:success, :partial]
        new_success = if is_success, do: stats.success_count + 1, else: stats.success_count
        new_engagement = stats.total_engagement + outcome_record.engagement

        updated_stats = %{
          stats
          | success_count: new_success,
            success_rate: new_success / max(stats.shown_count, 1),
            total_engagement: new_engagement,
            avg_engagement: new_engagement / max(stats.shown_count, 1)
        }

        %{state | prompt_stats: Map.put(state.prompt_stats, key, updated_stats)}
    end
  end

  defp normalize_prompt_key(prompt_text) when is_binary(prompt_text) do
    prompt_text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.split()
    |> Enum.take(8)
    |> Enum.join("_")
  end

  defp normalize_prompt_key(_), do: "unknown"

  defp calculate_prompt_score(stats) do
    # Combine success rate with confidence from sample size
    base_score = stats.success_rate
    confidence = min(stats.shown_count / 20.0, 1.0)
    engagement_bonus = min(stats.avg_engagement * 0.1, 0.2)

    base_score * confidence + engagement_bonus
  end

  defp get_top_prompts(prompt_stats, limit) do
    prompt_stats
    |> Enum.map(fn {_key, stats} -> stats end)
    |> Enum.filter(&(&1.shown_count >= 3))
    |> Enum.sort_by(&calculate_prompt_score/1, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn stats ->
      %{
        text: String.slice(stats.prompt_text, 0, 50),
        success_rate: Float.round(stats.success_rate, 2),
        shown: stats.shown_count
      }
    end)
  end

  defp run_optimization(state) do
    # Analyze prompt effectiveness by context type
    by_context =
      state.prompt_stats
      |> Enum.group_by(fn {_key, stats} -> stats.context_type end)
      |> Enum.map(fn {context_type, prompts} ->
        sorted = Enum.sort_by(prompts, fn {_k, s} -> calculate_prompt_score(s) end, :desc)

        best =
          case sorted do
            [{_k, s} | _] -> s.prompt_text
            _ -> nil
          end

        {context_type, %{count: length(prompts), best_prompt: best}}
      end)
      |> Map.new()

    # Find underperforming prompts
    underperforming =
      state.prompt_stats
      |> Enum.filter(fn {_key, stats} ->
        stats.shown_count >= 5 && stats.success_rate < 0.3
      end)
      |> Enum.map(fn {_key, stats} -> stats.prompt_text end)

    # Find high-performing prompts
    high_performing =
      state.prompt_stats
      |> Enum.filter(fn {_key, stats} ->
        stats.shown_count >= 5 && stats.success_rate > 0.7
      end)
      |> Enum.map(fn {_key, stats} ->
        %{text: stats.prompt_text, context: stats.context_type, rate: stats.success_rate}
      end)

    %{
      optimized: true,
      analyzed_prompts: map_size(state.prompt_stats),
      by_context_type: by_context,
      underperforming_count: length(underperforming),
      high_performing: high_performing,
      recommendations: generate_recommendations(state, underperforming, high_performing)
    }
  end

  defp apply_optimization(state, _result) do
    %{state | last_optimization: DateTime.utc_now()}
  end

  defp generate_recommendations(state, underperforming, high_performing) do
    recommendations = []

    # Recommend removing underperforming prompts
    recommendations =
      if length(underperforming) > 0 do
        [
          %{type: :remove, prompts: Enum.take(underperforming, 3), reason: "Low success rate"}
          | recommendations
        ]
      else
        recommendations
      end

    # Recommend promoting high-performing prompts
    recommendations =
      if length(high_performing) > 0 do
        [
          %{type: :promote, prompts: Enum.take(high_performing, 3), reason: "High success rate"}
          | recommendations
        ]
      else
        recommendations
      end

    # Recommend more data collection if needed
    recommendations =
      if state.total_outcomes < 50 do
        [%{type: :collect_data, current: state.total_outcomes, target: 50} | recommendations]
      else
        recommendations
      end

    recommendations
  end

  defp load_learned_patterns(state) do
    case Memory.search("prompt optimization patterns", limit: 1, category: "prompt_learning") do
      {:ok, [%{content: content} | _]} ->
        try do
          case Jason.decode(content) do
            {:ok, %{"prompt_stats" => stats}} when is_map(stats) ->
              loaded_stats =
                stats
                |> Enum.map(fn {key, val} ->
                  {key, atomize_stats(val)}
                end)
                |> Map.new()

              %{state | prompt_stats: Map.merge(state.prompt_stats, loaded_stats)}

            _ ->
              state
          end
        rescue
          _ -> state
        end

      _ ->
        state
    end
  end

  defp atomize_stats(stats) when is_map(stats) do
    %{
      prompt_text: stats["prompt_text"] || "",
      prompt_type: String.to_existing_atom(stats["prompt_type"] || "learned"),
      context_type: String.to_existing_atom(stats["context_type"] || "general"),
      shown_count: stats["shown_count"] || 0,
      success_count: stats["success_count"] || 0,
      success_rate: stats["success_rate"] || 0.0,
      avg_engagement: stats["avg_engagement"] || 0.0,
      total_engagement: stats["total_engagement"] || 0.0
    }
  rescue
    _ ->
      %{
        prompt_text: "",
        prompt_type: :learned,
        context_type: :general,
        shown_count: 0,
        success_count: 0,
        success_rate: 0.0,
        avg_engagement: 0.0,
        total_engagement: 0.0
      }
  end

  defp persist_learnings(state) do
    # Persist top performing prompts to memory
    top_stats =
      state.prompt_stats
      |> Enum.filter(fn {_key, stats} -> stats.shown_count >= 5 end)
      |> Enum.take(50)
      |> Map.new()

    content =
      Jason.encode!(%{
        prompt_stats: top_stats,
        last_updated: DateTime.to_iso8601(DateTime.utc_now())
      })

    Task.start(fn ->
      Memory.store(%{
        content: content,
        category: "prompt_learning",
        importance: 0.8
      })
    end)
  end

  defp schedule_optimization do
    Process.send_after(self(), :run_optimization, @optimization_interval)
  end
end
