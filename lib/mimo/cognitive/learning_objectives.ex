defmodule Mimo.Cognitive.LearningObjectives do
  @moduledoc """
  Phase 6 S1: Learning Objective Generator

  Uses all the Phase 3-5 infrastructure to proactively identify learning
  opportunities and set explicit objectives for cognitive growth.

  ## Philosophy

  Reactive systems wait for problems. Proactive systems seek growth.
  This module leverages:
  - MetaLearner insights → identify weak learning strategies
  - FeedbackLoop data → find high-error-rate categories
  - EvolutionDashboard → target lowest-scoring components
  - Emergence patterns → discover unexplored capability areas
  - HealthWatcher alerts → prioritize urgent learning needs

  ## Objective Types

  - :skill_gap - Missing capability identified from failed tool uses
  - :calibration - Category with poor confidence calibration
  - :strategy - Learning strategy underperforming
  - :pattern - Emergent pattern needs strengthening
  - :knowledge - Domain knowledge gap from failed retrievals

  ## Usage

      # Generate current learning objectives
      LearningObjectives.generate()

      # Get prioritized objectives
      LearningObjectives.prioritized()

      # Mark objective as addressed
      LearningObjectives.mark_addressed(objective_id)

      # Get objective statistics
      LearningObjectives.stats()
  """

  use GenServer
  require Logger

  alias Mimo.Cognitive.{MetaLearner, FeedbackLoop, EvolutionDashboard}

  @objectives_table :mimo_learning_objectives

  # ─────────────────────────────────────────────────────────────────
  # Public API
  # ─────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Generates learning objectives based on current system state.
  Leverages all Phase 3-5 infrastructure.
  """
  @spec generate() :: [map()]
  def generate do
    GenServer.call(__MODULE__, :generate)
  end

  @doc """
  Returns prioritized learning objectives sorted by impact and urgency.
  """
  @spec prioritized() :: [map()]
  def prioritized do
    GenServer.call(__MODULE__, :prioritized)
  end

  @doc """
  Marks a learning objective as addressed.
  """
  @spec mark_addressed(integer()) :: :ok | {:error, :not_found}
  def mark_addressed(objective_id) do
    GenServer.call(__MODULE__, {:mark_addressed, objective_id})
  end

  @doc """
  Returns statistics about learning objectives.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Gets the current learning focus (highest priority objective).
  """
  @spec current_focus() :: map() | nil
  def current_focus do
    case prioritized() do
      [focus | _] -> focus
      [] -> nil
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # GenServer Implementation
  # ─────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # Create ETS table for objectives (handle restart case)
    case :ets.whereis(@objectives_table) do
      :undefined ->
        :ets.new(@objectives_table, [:named_table, :set, :public])

      _tid ->
        # Table already exists (GenServer restart), clear stale data
        :ets.delete_all_objects(@objectives_table)
    end

    state = %{
      last_generation: nil,
      generation_count: 0,
      objectives_addressed: 0
    }

    Logger.info("[LearningObjectives] Phase 6 S1 initialized - proactive learning active")
    {:ok, state}
  end

  @impl true
  def handle_call(:generate, _from, state) do
    objectives = do_generate()

    # Store in ETS
    Enum.each(objectives, fn obj ->
      :ets.insert(@objectives_table, {obj.id, obj})
    end)

    new_state = %{
      state
      | last_generation: DateTime.utc_now(),
        generation_count: state.generation_count + 1
    }

    {:reply, objectives, new_state}
  end

  @impl true
  def handle_call(:prioritized, _from, state) do
    objectives =
      :ets.tab2list(@objectives_table)
      |> Enum.map(fn {_id, obj} -> obj end)
      |> Enum.filter(&(&1.status == :active))
      |> Enum.sort_by(fn obj ->
        # Higher priority = lower sort key (comes first)
        urgency =
          cond do
            obj.urgency == :critical -> 0
            obj.urgency == :high -> 1
            true -> 2
          end

        impact = 1.0 - obj.impact_score
        {urgency, impact}
      end)

    {:reply, objectives, state}
  end

  @impl true
  def handle_call({:mark_addressed, objective_id}, _from, state) do
    case :ets.lookup(@objectives_table, objective_id) do
      [{^objective_id, obj}] ->
        updated = Map.put(obj, :status, :addressed)
        :ets.insert(@objectives_table, {objective_id, updated})
        {:reply, :ok, %{state | objectives_addressed: state.objectives_addressed + 1}}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    all_objectives = :ets.tab2list(@objectives_table) |> Enum.map(fn {_id, obj} -> obj end)

    stats = %{
      total: length(all_objectives),
      active: Enum.count(all_objectives, &(&1.status == :active)),
      addressed: state.objectives_addressed,
      by_type:
        all_objectives
        |> Enum.group_by(& &1.type)
        |> Enum.map(fn {k, v} -> {k, length(v)} end)
        |> Map.new(),
      by_urgency:
        all_objectives
        |> Enum.group_by(& &1.urgency)
        |> Enum.map(fn {k, v} -> {k, length(v)} end)
        |> Map.new(),
      last_generation: state.last_generation,
      generation_count: state.generation_count
    }

    {:reply, stats, state}
  end

  # ─────────────────────────────────────────────────────────────────
  # Objective Generation
  # ─────────────────────────────────────────────────────────────────

  defp do_generate do
    timestamp = DateTime.utc_now()

    # Gather insights from all Phase 3-5 systems
    calibration_objectives = generate_from_calibration()
    meta_learning_objectives = generate_from_meta_learning()
    evolution_objectives = generate_from_evolution()
    error_objectives = generate_from_errors()

    all_objectives =
      calibration_objectives ++
        meta_learning_objectives ++
        evolution_objectives ++ error_objectives

    # Assign IDs and metadata
    all_objectives
    |> Enum.with_index(1)
    |> Enum.map(fn {obj, idx} ->
      Map.merge(obj, %{
        id: :erlang.phash2({timestamp, idx}),
        created_at: timestamp,
        status: :active
      })
    end)
    # Dedupe by focus area
    |> Enum.uniq_by(& &1.focus_area)
  end

  defp generate_from_calibration do
    warnings = safe_call(fn -> FeedbackLoop.calibration_warnings() end, [])

    Enum.map(warnings, fn warning ->
      # Parse warning to extract category
      category = extract_category_from_warning(warning)

      %{
        type: :calibration,
        focus_area: "calibration:#{category}",
        description: "Improve confidence calibration for #{category} category",
        source: "FeedbackLoop.calibration_warnings",
        urgency: if(String.contains?(warning, "overconfident"), do: :high, else: :medium),
        impact_score: 0.7,
        recommended_actions: [
          "Record more outcomes for #{category} to improve calibration",
          "Review prediction patterns for #{category}",
          "Consider adjusting confidence thresholds"
        ]
      }
    end)
  end

  defp generate_from_meta_learning do
    insights = safe_call(fn -> MetaLearner.meta_insights() end, %{})

    recommendations = Map.get(insights, :high_priority_recommendations, [])

    Enum.map(recommendations, fn rec ->
      %{
        type: :strategy,
        focus_area: "strategy:#{rec.parameter}",
        description: "Adjust #{rec.parameter}: #{rec.current} → #{rec.suggested}",
        source: "MetaLearner.meta_insights",
        urgency: :medium,
        impact_score: 0.6,
        recommended_actions: [
          "Review #{rec.parameter} effectiveness",
          "Consider parameter adjustment: #{rec.reason}"
        ]
      }
    end)
  end

  defp generate_from_evolution do
    score_data = safe_call(fn -> EvolutionDashboard.evolution_score() end, %{})

    components = Map.get(score_data, :components, %{})

    # Find components scoring below 0.5
    weak_components =
      Enum.filter(components, fn {_name, score} ->
        score < 0.5
      end)

    Enum.map(weak_components, fn {name, score} ->
      %{
        type: :knowledge,
        focus_area: "evolution:#{name}",
        description: "Strengthen #{name} component (currently #{round(score * 100)}%)",
        source: "EvolutionDashboard.evolution_score",
        urgency: if(score < 0.3, do: :critical, else: :high),
        # Lower score = higher impact potential
        impact_score: 1.0 - score,
        recommended_actions: recommendations_for_component(name)
      }
    end)
  end

  defp generate_from_errors do
    # Check FeedbackLoop for high-error categories
    accuracy = safe_call(fn -> FeedbackLoop.classification_accuracy() end, %{})

    # Find categories with < 70% success rate
    weak_categories =
      Enum.filter(accuracy, fn {_category, data} ->
        total = Map.get(data, :total, 0)
        success_rate = Map.get(data, :success_rate, 1.0)
        total >= 10 and success_rate < 0.7
      end)

    Enum.map(weak_categories, fn {category, data} ->
      %{
        type: :skill_gap,
        focus_area: "accuracy:#{category}",
        description:
          "Improve accuracy for #{category} (#{round(data.success_rate * 100)}% success rate)",
        source: "FeedbackLoop.classification_accuracy",
        urgency: if(data.success_rate < 0.5, do: :critical, else: :high),
        impact_score: 1.0 - data.success_rate,
        recommended_actions: [
          "Analyze failure patterns for #{category}",
          "Review classification criteria",
          "Consider adding training examples"
        ]
      }
    end)
  end

  # ─────────────────────────────────────────────────────────────────
  # Helpers
  # ─────────────────────────────────────────────────────────────────

  defp extract_category_from_warning(warning) when is_binary(warning) do
    case Regex.run(~r/(\w+) category/, warning) do
      [_, category] -> category
      _ -> "unknown"
    end
  end

  defp extract_category_from_warning(%{category: cat}), do: to_string(cat)
  defp extract_category_from_warning(_), do: "unknown"

  defp recommendations_for_component(component) do
    case component do
      :memory ->
        [
          "Store more high-quality memories",
          "Run memory consolidation",
          "Review memory decay settings"
        ]

      :learning ->
        [
          "Record more outcome data",
          "Review feedback loop effectiveness",
          "Check calibration accuracy"
        ]

      :emergence ->
        [
          "Run pattern detection more frequently",
          "Review pattern promotion criteria",
          "Generate more cross-session patterns"
        ]

      :health ->
        ["Run system health check", "Execute safe healing actions", "Review resource usage"]

      _ ->
        ["Investigate #{component} performance", "Review related metrics"]
    end
  end

  defp safe_call(fun, default) do
    try do
      fun.()
    rescue
      _ -> default
    catch
      :exit, _ -> default
    end
  end
end
